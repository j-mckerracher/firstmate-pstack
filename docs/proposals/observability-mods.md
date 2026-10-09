# Fleet observability mods for Claude Code

Recommendations for Claude Code mods that show the status of all firstmate work in progress without asking firstmate for an update.

Status: proposal only.
Nothing in this document is built yet.

## 1. The problem

Today the only way to learn what the fleet is doing is to ask firstmate.
Each request has three costs:

- **A model turn.** Firstmate reads records, reconciles them and writes a summary, which spends tokens and takes time.
- **An interruption.** A status request competes with whatever firstmate is doing, including supervision.
- **No push.** You learn about a finished worker, a red check or a stalled task only when you ask or when firstmate decides to tell you.

The goal is that you can see the state of all work at a glance, are told when something changes, and ask firstmate only when you want judgment rather than facts.

## 2. The key idea: read the records directly

Firstmate already maintains a deterministic, structured, read-only view of the whole fleet: `bin/fm-fleet-snapshot.sh --json`.
It is the same source firstmate itself and the `/bearings` report use, so a mod built on it can never disagree with firstmate about the facts.

Properties that make it safe to poll from a mod (all stated in the script's header):

- It does not acquire the session lock.
- It does not drain or acknowledge wake records.
- It does not arm watchers, mutate the backlog or write reports.
- Its only write is an observational cache of remote second-mate summaries under `state/secondmate-summary-cache`.
- On a home with no work in progress it runs in a fraction of a second (measured at about 0.2 seconds).

Every mod below is a reader of this snapshot, plus, for two optional features, the GitHub PR check helper and the fleet activity ledger.
No mod ever sends text to a worker, peeks at a worker's terminal, steers, merges, drains wakes or changes any record.

## 3. Data sources

### 3.1 `bin/fm-fleet-snapshot.sh --json` (primary)

Schema id `fm-fleet-snapshot.v1`.
Top-level keys: `schema`, `generated`, `fm_home`, `roots`, `backlog`, `tasks`, `scout_reports`, `main_inventory`, `secondmate_current`, `secondmate_landed`, `contributions`, `secondmate_guidance`.

Fields the mods use:

| Field | Meaning | Used for |
| --- | --- | --- |
| `generated` | UTC time this snapshot was observed | "as of" stamp; staleness of the mod's own view |
| `tasks[].id` | Task id | Row identity, change detection |
| `tasks[].kind` | `ship`, `scout` or `secondmate` | Labels, filtering |
| `tasks[].project` | Project directory name | Row label |
| `tasks[].harness`, `mode`, `yolo`, `workflow`, `branch` | Worker tool, delivery mode, merge posture, workflow, branch | Detail view |
| `tasks[].current_state.state` | `working`, `parked`, `done`, `blocked`, `paused`, `failed` or `unknown`, reconciled by `bin/fm-crew-state.sh` | The task's real current state |
| `tasks[].current_state.source` | `run-step`, `pane`, `status-log`, `remote-endpoint` or `none` | How trustworthy the state is |
| `tasks[].current_state.detail` | One-line detail, such as the validation step | Detail line |
| `tasks[].paths.status_log.last_event` | `{state, note, raw, age_seconds}` of the last line the worker wrote | "Last update" text and age; history only, never current state |
| `tasks[].endpoint.status` | `absent`, `alive`, `dead` or `unknown` | Stall and crash detection |
| `tasks[].pr.url` | PR URL recorded for the task, or `null` | PR link |
| `tasks[].hints.pending_decision` | An open decision is keyed on this task | "Needs attention" |
| `tasks[].hints.blocked_event` | An open blocker is keyed on this task | "Needs attention" |
| `tasks[].hints.open_decisions` | The keyed open decisions themselves | Detail view |
| `tasks[].hints.scout_report_present` | A scout has written its report | "Findings ready" |
| `backlog.records[]` | Every In flight, Queued and Done backlog row | Queue depth, titles |
| `backlog.records[].captain_actionable` | `true` exactly when the hold is waiting on you now (`hold_bucket == "live"`) | "Needs you" |
| `backlog.records[].hold_bucket` | `live`, `blocked`, `dated` or `aged` for captain holds | Explaining why a hold is not shown as urgent |
| `backlog.records[].hold_reason`, `hold_until`, `hold_age_days` | Why it is held, until when, how long | "Needs you" text |
| `scout_reports[]` | Pointers to existing `data/<id>/report.md` files | "Findings ready" |
| `secondmate_current.records[]` | Per second mate: `active_children`, `decisions_open`, `holds`, `queued`, `landed`, `endpoints`, `counts`, `provenance`, `freshness` | Second-mate rows |
| `main_inventory.valid` | `false` when the backlog and the live task records disagree | A warning that the view may be incomplete |

Meaning of `current_state.state` (owned by `bin/fm-crew-state.sh`):

| State | Meaning | How the mods treat it |
| --- | --- | --- |
| `working` | The worker or its validation run is active | Under way |
| `parked` | The worker's validation is stopped at a gate (awaiting approval, a review finding, or an open decision) | Waiting on firstmate, sometimes on you |
| `paused` | The worker declared an external wait | Waiting on something outside the fleet |
| `blocked` | The worker needs firstmate to act, or a `done` that is not actually landed | Needs attention |
| `failed` | The work failed | Needs attention |
| `done` | Finished; for ship work, the result is reachable outside the worker's copy | Ready for review or landed |
| `unknown` | No trustworthy evidence | Shown as unknown, never guessed |

Bounds the snapshot already applies, adjustable by environment variable: per-task state read timeout `FM_SNAPSHOT_CREW_STATE_TIMEOUT` (default 10 s), local read concurrency `FM_SNAPSHOT_LOCAL_READ_CONCURRENCY` (default 8), remote collection budget `FM_SNAPSHOT_BUDGET` (default 5 s), at most `FM_SNAPSHOT_SECONDMATES` (default 20) second mates.

What the snapshot does **not** contain:

- **Live PR check or review status.** It carries only the recorded PR URL. Check status needs GitHub (section 3.3).
- **Remote second-mate liveness.** Remote rows report `unknown` for endpoint liveness by design.

### 3.2 `bin/fm-bearings-snapshot.sh` (ready-made summary)

A compact projection over the canonical snapshot, organized into the `/bearings` sections (Captain's Call, Underway, Charted Next, Recently Landed).
Output is TOON by default and JSON with `--json`.
It performs no live GitHub discovery unless `--include-prs` is passed, and it states what it did not request in its `prs:` line and `omitted[]` list, so an absence is never ambiguous.
Disclosure flags: `--all-decisions`, `--all-secondmates`, `--all-landed`, `--all-reports`, `--all-queued`, `--all-recorded-prs`, `--all-unhealthy`, `--all-pr-repos`.

### 3.3 `bin/fm-pr-state.sh <pr-url>` (optional, live GitHub)

A one-shot, read-only read of one PR's blockers: failing or pending required checks, `CHANGES_REQUESTED` reviews, or a closed or merged state.
It prints one line per blocker it sees and nothing when it sees none.
Empty output means no reported required check is failing or pending; it does **not** mean the PR is ready to merge, because a required check that has never reported cannot be seen.
It needs working GitHub access on the machine, so a mod should call it rarely (section 5.2).

### 3.4 `state/fleet-ledger.jsonl` (optional, event history)

An opt-in, append-only JSON Lines log, turned on per home by creating the flag file `config/fleet-ledger` (it is not inherited by second-mate homes).
Contract: `docs/fleet-ledger.md`.
Each record has `v` (currently `1`), `ts` (Unix seconds), `event` and `task`.
Events:

| Event | Extra members | Written when |
| --- | --- | --- |
| `task.dispatched` | `kind`, `project`, `harness`, `model` | A new worker or second mate launches (not a relaunch) |
| `task.status` | `state`, `key`, `text` | The worker writes a status line |
| `task.pr_ready` | `pr` | Firstmate records the PR as ready for review |
| `task.merged` | `via` (`pr` or `local`), plus `pr` | The merge or local landing is recorded |
| `task.cleaned_up` | none | The worker and its copy are removed |

Readers must ignore unknown members and events.

## 4. Shared foundation: one fleet reader

All mods should share one reader, so the snapshot is fetched once per interval regardless of how many views are open.
The simplest packaging is one mod (proposed name `fleet-watch`) containing every feature, each switchable by option.

### 4.1 Polling

- Start in `session.start`: `$.clock.every(intervalMs, poll)`.
- `poll` runs `$.process.run([fmRoot + "/bin/fm-fleet-snapshot.sh", "--json"], { cwd: fmRoot, env: { FM_HOME: fmHome }, timeoutMs: 20000 })`.
- Default interval 30 s; option range 10 s to 10 min.
- Never run two polls at once: skip a tick while the previous poll is still running.
- On a non-zero exit, a timeout or JSON that does not parse, keep the last good snapshot, mark the view stale and show the error age instead of clearing the display.
- A `/fleet refresh` command (section 6.3) forces an immediate poll.

### 4.2 Locating the firstmate home

- Option `fmRoot`: the firstmate checkout. Default: the session's working directory when it contains `bin/fm-fleet-snapshot.sh`, otherwise the mod shows "firstmate home not found" and stays idle.
- Option `fmHome`: the operational home. Default: `FM_HOME` from the session environment, else `fmRoot`.

### 4.3 The derived fleet model

After each poll the reader computes one model and stores it in `$.state`, so every view reads the same values and redraws when they change.

```ts
type Bucket = 'needs_you' | 'attention' | 'working' | 'waiting' | 'ready' | 'done' | 'unknown'

interface FleetItem {
  id: string                // task id, or "hold:<backlog id>" for a captain hold with no live task
  kind: 'ship' | 'scout' | 'secondmate' | 'hold'
  project: string
  title: string             // backlog title when present, else the id
  bucket: Bucket
  state: string             // current_state.state, or "held"
  detail: string            // current_state.detail, hold reason, or decision text
  lastEventText: string     // last_event.note
  lastEventAgeS: number | null
  prUrl: string | null
  endpoint: string          // endpoint.status
  stalled: boolean          // section 4.4
}

interface FleetModel {
  observedAt: string        // snapshot "generated"
  fetchedAt: number         // when the mod last succeeded
  error: string | null      // last poll error, if the latest poll failed
  items: FleetItem[]
  counts: Record<Bucket, number>
  queued: number            // backlog rows in Queued
  inventoryValid: boolean   // main_inventory.valid
}
```

### 4.4 Classification rules

Applied in this order; the first rule that matches decides the bucket.

1. **`needs_you`** (waiting on you now):
   - a backlog record with `captain_actionable == true`, or
   - a task with `current_state.state == "done"` and a non-null `pr.url` (a PR ready for your review or merge), or
   - a scout task with `current_state.state == "done"` and `hints.scout_report_present == true` (findings ready), or
   - a second-mate record whose `decisions_open` is non-empty.
2. **`attention`** (firstmate should be acting; shown so you can see it is not being ignored):
   - `current_state.state` is `blocked` or `failed`, or
   - `hints.pending_decision` or `hints.blocked_event` is true and rule 1 did not match, or
   - `endpoint.status` is `dead` or `absent` while the state is not `done`.
3. **`working`**: `current_state.state == "working"`.
4. **`waiting`**: `current_state.state` is `parked` or `paused`.
5. **`ready`**: `current_state.state == "done"` with no PR and not a scout (for example a local-only branch ready to land).
6. **`unknown`**: everything else, including remote second mates whose state is `unknown`.

Captain holds in the `blocked`, `dated` or `aged` buckets are **not** `needs_you`; they are listed in the detail view with the reason they are not urgent, mirroring `/bearings`.

**Stalled** is a flag, not a bucket.
A task is stalled when its state is `working`, `parked` or `unknown`, its `last_event.age_seconds` exceeds the stall threshold (option, default 45 min), and its state source is not `run-step` (an active validation run is evidence of progress even when the worker writes nothing).
`last_event.age_seconds` of `null` never counts as stalled.

### 4.5 Change detection

The reader keeps the previous model and computes transitions per item id:

| Transition | Rule |
| --- | --- |
| New work | an id present now and absent before |
| Bucket change | `bucket` differs from the previous snapshot |
| PR opened | `prUrl` went from `null` to a URL |
| Became stalled | `stalled` went from false to true |
| Finished | an id that was present is gone (cleaned up), or its state became `done` |
| Captain hold added or cleared | `captain_actionable` changed for a backlog record |

The first successful poll after the mod loads sets the baseline and produces no transitions, so loading or reloading the mod never floods you with notifications.

## 5. Recommended mods

Priority 1 is the recommended first build: features 5.1, 5.2 and 5.3 together.

### 5.1 Fleet status line (priority 1)

**What you see.** One line in Claude Code's status line, always present:

```text
⚓ 1 needs you · 3 working · 1 waiting · 2 queued · 1 stalled · 12s ago
```

**Behavior.**

- Built from `FleetModel.counts`; zero buckets are omitted, except that an empty fleet reads `⚓ fleet idle · 2 queued` or `⚓ fleet idle`.
- `needs you` comes first and, where the surface supports styling, is highlighted.
- `stalled` appears only when at least one item is stalled.
- The age is time since the last successful poll; when the latest poll failed it reads `⚠ stale 3m`.
- When `inventoryValid` is false it appends `· records disagree`, the same gap `/bearings` discloses.

**API.** `$.ui.status(text)` on each poll; `$.ui.status(undefined)` clears it when the mod is turned off.

**Cost.** Zero tokens; one snapshot per interval.

### 5.2 "Needs you" band above the prompt (priority 1)

**What you see.** A band directly above the prompt, shown only while at least one item is in `needs_you`:

```text
┌ Needs you ─────────────────────────────────────────────────────────┐
│ ● webapp  Login fix PR ready for review                            │
│   https://github.com/acme/webapp/pull/7          [Open] [Ask]       │
│ ● api     Decision: keep v1 endpoint during migration?   held 2d   │
│                                                   [Ask] [Hide]      │
└────────────────────────────────────────────────────────────────────┘
```

**Behavior.**

- One row per `needs_you` item: project, title, a one-line reason (PR ready, findings ready, the hold reason, or the second mate's open decision), and its age.
- The full PR URL is always shown and is pressable as a link.
- **Open** opens the PR (or the scout report path).
- **Ask** puts a prepared prompt into your prompt box, for example `Tell me about the webapp login fix PR and whether it is ready to merge.`, without submitting it; you choose whether to send it.
- **Hide** hides that item until its bucket or text changes.
- At most 3 rows, then `+2 more - /fleet`.
- The band disappears entirely when nothing needs you; it never shows "all clear".
- Optional (off by default): one `fm-pr-state.sh` call per PR row, at most every 5 minutes per PR, adding `checks red`, `checks pending` or `changes requested`. Its empty output is shown as nothing, never as "ready to merge" (section 3.3).

**API.** A `ui.render` hook on `{ component: 'AbovePrompt' }` returning the tree, or `next(e)` when there is nothing to show; elements from `$.ui.resolve(e)` (`Box`, `Text`, `Button`, link elements with `href`); prepared prompt text via `$.prompt.fill` (puts text in the prompt box as a draft), never `$.prompt.submit` (which would send it for you).

**Cost.** Zero tokens unless you press **Ask** and send.

### 5.3 `/fleet` command answered locally (priority 1)

**What you see.** Typing `/fleet` prints a short report in the transcript immediately, with no model turn:

```text
Fleet as of 14:02:11 (12s ago)

Needs you (1)
  webapp   Login fix PR ready - https://github.com/acme/webapp/pull/7

Under way (3)
  api      Rate limiter        working  validation: tests      updated 4m ago
  webapp   Dark mode           working                         updated 11m ago
  docs     Install guide scout working                         updated 2m ago

Waiting (1)
  infra    Terraform bump      paused   waiting on provider release

Queued: 2 · Recently landed: 1
```

**Behavior.**

- Sections in the order Needs you, Needs attention, Under way, Waiting, Ready, Unknown, then the queue and recently-landed counts.
- Each row: project, title, state, detail, last-update age, PR URL when present, `stalled` marker when flagged.
- Variants:
  - `/fleet` - the report from the cached model, refreshed first if older than the interval.
  - `/fleet refresh` - force a poll, then report.
  - `/fleet all` - also list non-urgent captain holds with their reason (blocked by other work, deferred until a date, aged).
  - `/fleet <id or project>` - one item in full: original ask from the backlog title, state and source, detail, last three status lines, open decisions, PR, delivery mode, worker tool and model.
- Alternative renderer: `fm-bearings-snapshot.sh` output, for exact parity with `/bearings` section names.
- Optional (off by default): a `prompt.submit` hook that answers a prompt consisting only of `status`, `fleet` or `status?` from this report instead of sending it to firstmate. Off by default because silently intercepting what you type can surprise.

**API.** `$.command.register({ name: 'fleet', description })` in `session.start`; a `command.run` hook on `{ command: 'fleet' }` returning `{ text }`.

**Cost.** Zero tokens.

### 5.4 Fleet pane (priority 2)

**What you see.** A side panel with one row per item, grouped by bucket, live-updating:

```text
┌ Fleet ── 14:02:11 ───────────────────────────────────────────────┐
│ NEEDS YOU                                                        │
│  ● webapp  login-fix     done     PR #7               2m         │
│ UNDER WAY                                                        │
│  ● api     rate-limit    working  validation: tests   4m         │
│  ● webapp  dark-mode     working                      11m        │
│  ◐ docs    install-guide working  (scout)             2m         │
│ WAITING                                                          │
│  ○ infra   tf-bump       paused   provider release    3h         │
│ SECOND MATES                                                     │
│  ◆ data    2 active · 0 decisions · cached 40s                   │
└──────────────────────────────────────────────────────────────────┘
```

**Behavior.**

- Columns: project, title or id, state, detail, last-update age; a `⏸ stalled` marker when flagged; PR shown as a link.
- Selecting a row expands it in place: original ask, state source, open decisions, last three status lines, PR blockers (only if the optional PR check is on), delivery mode, merge posture, worker tool, model and effort.
- Second-mate rows show `active_children`, open decisions and the freshness of their summary (`local-ledger`, `remote-ledger` or `remote-ledger-cache` with its age).
- A footer shows the last poll time and any poll error.
- Opened by `/fleet pane`, which places it at any terminal width.
- Optional auto-open at session start; per the engine's rule, a pane opened without your action is placed only from 144 terminal columns (110 once you have opened it before) and otherwise waits undrawn until the terminal widens or you open it.

**API.** `$.ui.open({ id: 'fleet', title: 'Fleet' })`; a `ui.render` hook on `{ component: 'Pane', requestId: 'fleet' }`; state via `atom` and `read`/`update`.

**Cost.** Zero tokens.

### 5.5 Change notifications (priority 2)

**What you see.** A short toast when, and only when, something changes:

```text
⚓ webapp login-fix: PR ready - https://github.com/acme/webapp/pull/7
⚓ api rate-limit: blocked
⚓ docs install-guide: findings ready
⚓ infra tf-bump: no update for 45m
```

**Behavior.**

- Driven by the transitions in section 4.5.
- Default toasts on: entering `needs_you`, entering `attention`, PR opened, becoming stalled, finished.
- Default toasts off: entering `working` or `waiting` (routine), new work dispatched.
- Each kind is switchable by option.
- Coalescing: transitions from one poll are combined into one toast when there are more than two (`⚓ 3 changes - /fleet`).
- Rate limit: at most one toast per item per 5 minutes, so a task flapping between states cannot spam you.
- Optional sound for `needs_you` only. The engine plays sounds with `afplay`, so this works on macOS and is silent on Linux and Windows terminals.

**API.** `$.ui.toast(text)`; optional `$.audio.play({ asset: 'sounds/needs-you.wav' })`.

**Cost.** Zero tokens.

### 5.6 Stall warning (priority 2)

**What you see.** A stalled item is marked in the status line (`1 stalled`), the pane and `/fleet`, and raises one toast when it first becomes stalled.

**Behavior.**

- Uses the stalled rule in section 4.4: state `working`, `parked` or `unknown`, no worker update for longer than the threshold, and no active validation run as the state source.
- Threshold option, default 45 minutes; a per-kind override is useful because scouts often write nothing for longer than ship work.
- Also flags a dead or absent worker endpoint on unfinished work immediately, regardless of the threshold.
- The mod only reports; recovering a stuck worker stays with firstmate.

**Cost.** Zero tokens.

### 5.7 "While you were away" timeline (priority 3)

**What you see.** `/fleet since 3h` (also `since yesterday`, or a time) prints, per task, what happened in that window:

```text
Since 11:00 (3h)

webapp login-fix   dispatched 11:04 → working → PR ready 12:31 → merged 13:10   (2h 6m)
api    rate-limit  dispatched 12:15 → working → blocked 13:40                    (open)
docs   install     dispatched 13:20 → findings ready 13:55                        (35m)
```

**Behavior.**

- Reads `state/fleet-ledger.jsonl` from the home and folds events per task within the window.
- Each step's time comes from `ts`; durations run from `task.dispatched` to `task.merged`, `task.cleaned_up`, or now.
- Shows `task.status` states compactly; full text is available in `/fleet <id>`.
- Requires the ledger to be on (`config/fleet-ledger` present in each home you want covered). With it off, the command says so and how to turn it on, instead of showing an empty timeline.
- Pairs naturally with `/afk`: the same view tells you what changed while you were away.

**API.** `$.fs` to read the ledger, or `$.process.run` with `tail`; `command.run` hook.

**Cost.** Zero tokens.

### 5.8 Fresh fleet facts in firstmate's context (priority 4, only if needed)

**What it does.** A `prompt.compose` hook adds one short section to firstmate's system prompt on each turn, containing the current `counts` and the `needs_you` and `attention` items (about 10-20 lines at most).

**Benefit.** When you do ask firstmate a question, it answers from current facts without re-running its own checks.

**Cost and caution.**

- It adds those tokens to every turn, including turns unrelated to status.
- It overlaps with firstmate's own session-start digest and wake handling; the section must be labelled as an observational view, never as a wake or a decision, so firstmate does not act on it as an instruction.
- Recommended only if 5.1-5.3 still leave you asking for status regularly.

**API.** `on('prompt.compose', ...)` adding a section with `scope: 'session'`.

## 6. Options

Proposed `userConfig` options for the single `fleet-watch` mod:

| Option | Default | Meaning |
| --- | --- | --- |
| `fmRoot` | session directory if it holds `bin/fm-fleet-snapshot.sh` | Firstmate checkout |
| `fmHome` | `FM_HOME`, else `fmRoot` | Operational home |
| `pollSeconds` | 30 | Snapshot interval (10-600) |
| `stallMinutes` | 45 | Stall threshold |
| `statusLine` | on | Feature 5.1 |
| `band` | on | Feature 5.2 |
| `bandMaxRows` | 3 | Rows before `+N more` |
| `prChecks` | off | Live PR blocker reads via `fm-pr-state.sh` |
| `prCheckMinutes` | 5 | Minimum interval per PR |
| `interceptStatusPrompt` | off | Answer a bare `status` prompt locally |
| `paneAutoOpen` | off | Open the pane at session start |
| `toasts` | `needs_you,attention,pr,stalled,finished` | Which transitions toast |
| `sound` | off | Sound for `needs_you` (macOS only) |
| `contextFacts` | off | Feature 5.8 |

## 7. Safety and cost guarantees

- **Read-only.** The mod only runs `fm-fleet-snapshot.sh`, optionally `fm-bearings-snapshot.sh`, optionally `fm-pr-state.sh`, and reads the ledger. It never runs `fm-send.sh`, `fm-peek.sh`, `fm-control.sh`, `fm-spawn.sh`, merge scripts, wake drains or backlog writes.
- **No competition with supervision.** The snapshot takes no lock and touches no wake record, so the mod cannot delay or hide anything from firstmate.
- **Bounded load.** One snapshot per interval, never concurrent, with a timeout; the snapshot itself bounds per-task and remote reads (section 3.1).
- **Honest unknowns.** Unknown states, stale polls and a disagreeing inventory are shown as such, never filled in.
- **No surprise actions.** Buttons open links or prepare prompt text; nothing is sent to firstmate unless you send it.
- **Zero tokens** for every feature except 5.8.

## 8. Limits and environment

- **Where it runs.** Running host commands (`$.process`) is available in the Claude Code CLI only, and the commands run on the machine where Claude Code runs. The mod must therefore run in a Claude Code session on the same machine as the firstmate home. Viewing that session from the Claude app shows what the session draws, but the app alone cannot run the mod.
- **Pane width.** An auto-opened pane needs at least 144 terminal columns (110 after you have opened it once); `/fleet pane` places it at any width.
- **Sound.** macOS only (`afplay`).
- **PR checks** need working GitHub access on the machine; without it, the PR check option reports that it cannot read GitHub rather than showing nothing.
- **Remote second mates** show summary freshness but not live liveness, by design of the snapshot.
- **Personal, not shared.** Mods live in your Claude Code plugin folders, not in the firstmate repo. Sharing them with other firstmate users would mean publishing them as a plugin, which is a separate decision.
- **Testing without a live fleet.** The first build should be tested against sample snapshot JSON (section 9) rather than depending on work being in progress.

## 9. Build and test plan

1. **Reader and model** (section 4): polling, home location, classification, stall rule, change detection, `$.state` contract.
2. **Priority 1 views**: status line, band, `/fleet` command.
3. **Tests** with `claude plugin test`, driven by fixture snapshot JSON files rather than a live fleet:
   - empty fleet;
   - one of each `current_state.state`;
   - a PR-ready task and a scout with findings ready;
   - a live captain hold, plus `blocked`, `dated` and `aged` holds (only the live one counts as needs-you);
   - a stalled task, and a quiet task with an active validation run (not stalled);
   - a dead endpoint on unfinished work;
   - `main_inventory.valid == false`;
   - a failed poll after a good one (last good view kept, marked stale);
   - two consecutive snapshots producing each transition in section 4.5, and a first snapshot producing none.
4. **Validation**: `claude plugin validate` on the mod folder and a type check against the engine's types.
5. **Live trial**: with hot reload enabled, run it against a home while real work is dispatched, and tune the interval, stall threshold and toast set.
6. **Priority 2 and 3** (pane, notifications, stall warning, timeline) on the same reader.
7. **Priority 4** only if still needed.

## 10. Open decisions

1. Build priority 1 (status line, band, `/fleet`) as one mod first?
2. Default poll interval: 30 seconds acceptable?
3. Default stall threshold: 45 minutes acceptable, and should scouts get a longer one?
4. Turn on the fleet activity ledger (`config/fleet-ledger`) now, so the timeline (5.7) has history when it is built?
5. Live PR check status in the band and pane: worth the GitHub calls, or keep it off?
