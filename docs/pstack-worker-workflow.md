# The pstack worker workflow

The pstack worker workflow is a per-task dimension alongside a ship task's delivery mode: `standard` (the default) or `pstack`.
Delivery mode stays exactly what it was; the workflow changes only how one ship worker investigates, implements, and proves its work, and [docs/architecture.md](architecture.md#delivery-modes-are-explicit-per-task) owns the delivery dimension.
With `pstack`, one ship worker owns investigation, implementation, direct proof, and the outer no-mistakes lifecycle that the [`validation-supervision`](../.agents/skills/validation-supervision/SKILL.md) skill supervises, while the no-mistakes pipeline's gate agents stay isolated validators and the pipeline stays the sole publisher of changes.
`bin/fm-pstack.sh`'s header is the one owner of availability resolution and of the proof-record format; this page is the operator-level reference for the behavior built on it.

## Default implementation phase

Every standard `no-mistakes` ship, including a promoted scout, receives a poteto-mode implementation contract from `bin/fm-dod-lib.sh` before its delivery instructions.
It reads the pinned entry and applicable sibling skills under `vendor/pstack/` by exact file path, without installing or registering global skills.
The source revision, license, and file hashes live with those resources.
The worker implements and directly proves the change, commits it, and hands off through the existing delivery contract; no-mistakes owns the subsequent validation and publication phases.
Task-required regression tests and documentation remain implementation work.
The ordinary handoff retains the selected playbook, actual skill reads, verification evidence, and uncertainty; it does not acquire the optional plugin workflow's proof-record gate.
Claude and Rovo worker launches grant resource access to scouts as well as ships so promotion can reuse the session; an older restricted scout that cannot read the resources needs relaunch.
The optional `workflow=pstack` path below instead uses its configured plugin's skill tree, never both versions in one task.

## When the optional plugin workflow is available

A ship task resolves its workflow as `standard` unless the project's registry entry carries the bracket token `workflow=pstack`, and `bin/fm-project-mode.sh`'s header owns that token format.
Firstmate additionally requires a configured pstack plugin: the local, gitignored `config/pstack-plugin` names one pstack Claude plugin root, and the `configuration.md` section [`Worker workflow (config/pstack-plugin)`](configuration.md#worker-workflow-configpstack-plugin) owns that file's format.
Both must agree before a pstack worker launches, so a missing plugin is always an actionable error naming what to configure, never a silent standard launch.

In this release, the workflow dimension composes with every publishing delivery mode.

- `no-mistakes`, `direct-PR`, and `local-only` all accept `workflow=pstack`.
- A `forge=gerrit` project refuses the pstack workflow in this release.
- Scouts, secondmates, and raw launch commands never carry the workflow dimension; they already own their own investigation or charter contracts.

Only the Claude harness resolves a pstack plugin, so every other verified harness refuses at launch with a message naming the matrix below.

## Responsibility chain

| Actor | Responsibility |
| --- | --- |
| Captain and firstmate | Choose a pstack-capable project posture and a plugin checkout; Firstmate resolves availability, renders the worker workflow block into the brief, and launches Claude with `--plugin-dir`. |
| The pstack ship worker | Investigate, design, implement, reproduce or baseline, prove on the real surface, commit one exact candidate, write `data/<id>/pstack-proof.md`, and drive every outer no-mistakes validation step. |
| No-mistakes gate agents | Stay isolated validators: they see none of the pstack setup, never adopt Firstmate's identity, and never publish. |
| The pipeline | Validate, fix, and publish the PR; no worker push exists on the pstack path. |

The worker uses pstack's main mode for the implementation phase, selecting a proportionate playbook and applicable leaf skills before committed handoff.
Firstmate's contract overrides pstack always-on helpers: no PR-opening, babysitting, shipping, autopilot, orchestration, worktree-cleanup, or pause steps that push, open or update PRs, merge, land, or create worktrees, and never pstack's `setup-pstack`, which writes user-global harness state.
A brief's `## Firstmate spec` and its `# Worker workflow` block carry those boundaries verbatim, and `bin/fm-dod-lib.sh` owns the worker-facing text.

## Proof before validation

The worker writes the proof record with `bin/fm-pstack.sh template <id>`, which prints the skeleton that `bin/fm-pstack.sh`'s header owns: machine fields (`task`, `entry`, `playbook`, `base`, `candidate`, and `supersedes` when a complete invalidation replaced earlier work) plus four sections the worker fills in - reproduction or baseline, direct proof, not run and remaining uncertainty, and after validation the pipeline outcome.
Before sending Firstmate's validation trigger, the worker commits the exact candidate on the ship branch with the worktree clean.
Firstmate then refuses `/no-mistakes` on a task whose workflow is pstack until `bin/fm-pstack.sh proof-check <id>` passes, and that check verifies the record mechanically: valid fields matching the task, the candidate equal to the worktree's current head, a ship branch with no tracked uncommitted changes, `base` a strict ancestor of `candidate`, `supersedes` not an ancestor, non-empty evidence sections, and no active validation run.
A refusal lists every failure it found with its `next:` guidance, and a standard task is never asked for a proof record at all.

## Gate isolation

The pstack plugin loads through one launch flag on the worker's own command line (`claude --plugin-dir <path>`), and Firstmate writes nothing into the project checkout, its `.claude` settings, or any project file to express the workflow.
No-mistakes gate agents, which run in their own copies under Firstmate's trusted gate settings, therefore see neither the plugin nor the workflow choice and keep validating exactly as standard gate agents do.
The launch also grants the plugin root as an extra readable directory, so the worker can inspect the playbook sources it loaded.
[`docs/verification/runtime-backends.md`](verification/runtime-backends.md) records the dated live evidence that a `--plugin-dir` session lists the `pstack:poteto-mode` entry and a standard session lists none.

## Ask-user routing and scope freeze

A pstack worker never uses the harness's interactive ask-user tool; open questions return through Firstmate's ordinary `needs-decision [key=...]` status line, and the same worker that asked receives firstmate's decision with its key resolved.
The active-validation scope freeze works identically on the pstack path: only a current, explicit captain instruction that completely invalidates the work being validated switches it to follow-up work or a replacement, and [validation-supervision](../.agents/skills/validation-supervision/SKILL.md) owns that contract.
A pstack worker replaces invalidated work by aborting the active run through no-mistakes' supported abort command, confirming the stop, and rebuilding from the proof record's `base`, writing a new proof whose `supersedes` names the abandoned candidate.

## Publication and landing

Publication is unchanged by the workflow: a no-mistakes pstack ship still hands off to the pipeline, whose PR steps remain the only publisher, and the worker never pushes from its copy.
The worker's final handoff reports the outcome honestly and fills the proof record's pipeline-outcome section with the exact outcome label, the risk level when the pipeline printed one, the fixes applied, any overrides or skips with their reasons, and the remaining uncertainty; [ship-landing](../.agents/skills/ship-landing/SKILL.md) owns how landing reads that report.
`direct-PR` and `local-only` pstack tasks keep their own definitions of done, with the proof record still required when its validation trigger would run a pipeline.

## Optional plugin harness matrix

| Harness | pstack availability |
| --- | --- |
| `claude` | Supported: the plugin loads through `--plugin-dir`, and the live evidence records the reachable `pstack:poteto-mode` entry. |
| All other verified harnesses | Refused with an actionable message; `bin/fm-pstack.sh supported-harnesses` prints the current support list. |

The upstream Cursor pstack plugin is not model-invocable and is refused for that reason; use a harness-neutral port's plugin root instead.

## Backward compatibility

A standard task passes no plugin flag and carries no workflow metadata.
Standard no-mistakes briefs now include the pinned implementation instructions; restrictive worker launches also grant the resource directory.
Task-record and delivery-mode compatibility are unchanged.
Brief flags are additive on every entrypoint that gained one, and an unflagged invocation always resolves `standard`.
Legacy task records without workflow metadata re-launch on the standard workflow.

## End-to-end example

1. The captain registers `workflow=pstack` on a project and sets `config/pstack-plugin` to a checkout of a harness-neutral pstack port; Firstmate records the choice when dispatching the task.
2. Firstmate's brief renders the `# Worker workflow` block and the launch resolves the plugin, refuses any unsupported harness, and starts Claude with `--plugin-dir <path>` plus a launch overlay that invokes the plugin's `pstack:poteto-mode` entry by name.
3. The worker investigates, reproduces the failing behavior first, implements against the task's own spec, proves the change on the real surface and commits the candidate on its ship branch.
4. The worker writes `data/<id>/pstack-proof.md` from the template filled with the base and candidate heads and appends the handoff `done:` line Firstmate's normal flow expects.
5. Firstmate's validation trigger runs `bin/fm-pstack.sh proof-check <id>`; a refusal steers the worker back with the listed reasons, and a pass sends the ordinary `/no-mistakes` trigger so the pipeline validates and publishes exactly as it does for a standard ship.
6. If a finding invalidates the work, the worker aborts the run, rebuilds from the recorded or rebased base, writes a new proof with `supersedes`, and validates exactly once against that final head instead of running a second concurrent pipeline.
7. The pipeline reports `done: PR <url> checks green` as usual, and Firstmate handles landing and merge through the normal delivery authority.
