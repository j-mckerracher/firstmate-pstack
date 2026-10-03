#!/usr/bin/env bash
# Single owner of the pstack worker workflow's availability resolution and its
# deterministic proof-record format. Sourced by no script: every consumer calls
# it as a command, so its stdout contract below is the interface.
#
# The pstack workflow dimension (`standard` default | `pstack`) is orthogonal
# to delivery mode: a pstack-equipped ship worker owns investigation,
# implementation, direct proof, and the outer no-mistakes lifecycle, while the
# pipeline's gate agents stay isolated validators and the pipeline remains the
# only publisher. bin/fm-dod-lib.sh owns what the workflow changes for the
# WORKER (fm_pstack_workflow_block, the proof obligations); this script owns
# what the workflow RESOLVES from and the exact proof format that records it.
#
# Availability matrix (v1): harness `claude` only, from config/pstack-plugin.
# Firstmate never installs pstack, never runs `setup-pstack`, and never writes
# user-global harness configuration; the plugin must already exist on this
# machine and config/pstack-plugin must name it.
#
# config/pstack-plugin holds ONE absolute path to a pstack Claude plugin root
# that itself contains `.claude-plugin/plugin.json` (not a folder of plugins),
# resolved to a real path. The file is inheritable through FM_INHERITABLE_CONFIG
# like the rest of config/ (bin/fm-config-inherit-lib.sh owns that list; an
# inherited path may not exist on a remote secondmate host, and resolution
# refuses there instead of guessing).
#
# Commands and exit codes (refusals print an `error:` line and a `next:` line):
#   resolve --harness <h>     resolve pstack availability for harness <h>.
#                             On success prints one `key=value` report line per
#                             line: workflow=pstack, harness=, plugin_dir=,
#                             plugin=, entry=<plugin>:poteto-mode,
#                             load=plugin-dir, hooks=<present|none>,
#                             mcp=<present|none>.
#                             Exit 2 for wrong usage. Exit 3 for the plugin
#                             name missing or the config or plugin.json being
#                             malformed (an unusable config path, unparseable
#                             JSON, no plugin name). Exit 4 for a missing
#                             config file, plugin dir, .claude-plugin/plugin.json,
#                             or entry skill, an entry skill that is not
#                             model-invocable
#                             (`disable-model-invocation: true`; point at a
#                             harness-neutral pstack port instead, whose copy
#                             of the upstream Cursor entry is model-invocable),
#                             or jq being missing (the plugin.json name is
#                             read with jq and never guessed otherwise).
#                             Exit 5 for an unsupported harness (matrix above).
#   supported-harnesses       print the harness matrix, one name per line.
#   template <id>             print the proof-record skeleton for task <id> to
#                             data/<id>/pstack-proof.md's format. Resolves the
#                             config first (same exit codes and refusals as
#                             resolve) so the entry line carries the real
#                             entry. This is the single owner of the format:
#                             nothing else in the repo restates it.
#   proof-check <id>          deterministic self-check that task <id>'s
#                             data/<id>/pstack-proof.md record is well-formed
#                             and anchored: requires state/<id>.meta with
#                             kind=ship and workflow=pstack; the task's ship
#                             branch (meta `branch=`, default `fm/<id>`);
#                             valid fields (the proof-record header line, task
#                             match, a `<plugin>:<skill>` entry, a
#                             whitespace-free playbook, and 40-or-64-hex
#                             base/candidate/supersedes values, a trailing
#                             `# comment` stripped before validation because
#                             the template line carries one); candidate == the
#                             worktree HEAD; the worktree ON the ship branch;
#                             no tracked uncommitted changes; base a strict
#                             ancestor of candidate; supersedes, when the
#                             field carries a sha, a commit this copy has that
#                             is NOT an ancestor of candidate (a complete
#                             invalidation rebuilt from base discarded it); the
#                             `## Reproduction or baseline`, `## Direct proof`,
#                             and `## Not run and remaining uncertainty`
#                             sections non-empty; and NO active no-mistakes
#                             run on the branch (fm_nm_run_checked `axi` +
#                             fm_nm_select_run: pending/running -> refuse;
#                             absent/terminal -> pass; an unreadable, capped,
#                             or empty overview, or a missing binary, fails
#                             closed with a `next:`). Exit 0 prints
#                             `ok candidate=<sha>`; exit 1 prints ONE `error:`
#                             line per failure, listing every failure, and a
#                             `next:` when the run-state read failed closed.
# The `## Pipeline outcome` section is deliberately NOT checked by proof-check:
# it is filled only after validation, per the worker contract.
#
# hooks=/mcp= report what the plugin would load beyond the entry skill, so the
# caller can see what side effects a plugin carries: hooks are present when
# plugin.json carries a non-empty `hooks` value or the plugin root has a
# `hooks/` directory; MCP is present when the plugin root has a `.mcp.json` or
# plugin.json carries a non-empty `mcpServers` value. Neither gates v1
# availability; they are surfaced because a plugin that hooks the harness or
# adds MCP servers is a bigger surface than the entry skill alone.
#
# Usage: fm-pstack.sh resolve --harness <harness>
#        fm-pstack.sh supported-harnesses
#        fm-pstack.sh template <task-id>
#        fm-pstack.sh proof-check <task-id>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
FM_PSTACK_CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$SCRIPT_DIR/fm-nm-run-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

fm_pstack_supported_harnesses() {
  printf '%s\n' claude
}

fm_pstack_refuse() {  # <exit-code> <error-line> <next-line>
  printf 'error: %s\n' "$2"
  printf 'next: %s\n' "$3"
  exit "$1"
}

fm_pstack_trim() {
  local s=${1:-}
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# First scalar field `<key>: <value>` in <proof-file>; empty when the field is
# missing or empty. A trailing ` # comment` is stripped before the value is
# returned, because the proof template carries one on its optional field.
fm_pstack_proof_field() {  # <proof-file> <key>
  local v
  v=$(sed -n "s/^$2:[[:space:]]*\(.*\)$/\1/p" "$1" 2>/dev/null | head -1)
  v=$(printf '%s\n' "$v" | sed 's/#.*$//')
  fm_pstack_trim "$v"
}

# Content of the proof section whose heading line is exactly <heading>, from
# that line to the next `## ` heading or end of file, joined with newlines.
fm_pstack_proof_section() {  # <proof-file> <heading-line>
  awk -v sec="$2" '
    $0 == sec { inh = 1; next }
    /^## /    { inh = 0; next }
    inh { buf = buf $0 "\n" }
    END { sub(/\n$/, "", buf); printf "%s", buf }
  ' "$1"
}

# 0 when <SKILL.md> carries a model-invocable entry: its YAML frontmatter exists
# and does not carry `disable-model-invocation: true`. 1 when the frontmatter is
# absent or disables invocation; the caller writes the refusal either way, so a
# malformed skill fails to the same actionable place.
fm_pstack_entry_model_invocable() {  # <SKILL.md>
  awk '
    NR == 1 && $0 == "---" { infront = 1; saw = 1; next }
    infront && $0 == "---" { infront = 0; next }
    infront {
      s = $0
      sub(/^[[:space:]]+/, "", s)
      sub(/[[:space:]]+$/, "", s)
      if (s ~ /^disable-model-invocation:/) {
        v = substr(s, index(s, ":") + 1)
        gsub(/[[:space:]]/, "", v)
        gsub(/^"|"$/, "", v)
        if (v == "true" || v == "True" || v == "TRUE") disabled = 1
      }
    }
    END { if (saw && !disabled) exit 0; exit 1 }
  ' "$1"
}

# Core resolver: validates config/pstack-plugin and the plugin it names, and
# sets FM_PSTACK_PLUGIN_DIR, FM_PSTACK_PLUGIN, FM_PSTACK_ENTRY,
# FM_PSTACK_HOOKS and FM_PSTACK_MCP. Prints nothing; a failure refuses by exit
# code, never silently. The harness argument is the already-validated, already
# supported harness. Every jq side read is guarded, because the JSON parse
# check above is what already proved the file readable.
fm_pstack_resolve_core() {  # <harness>
  FM_PSTACK_PLUGIN=
  FM_PSTACK_PLUGIN_DIR=
  FM_PSTACK_ENTRY=
  FM_PSTACK_HOOKS=none
  FM_PSTACK_MCP=none

  local cfg="$FM_PSTACK_CONFIG/pstack-plugin" raw plugin_file plugin
  if [ ! -f "$cfg" ]; then
    fm_pstack_refuse 4 \
      "no pstack plugin is configured: $cfg does not exist" \
      "write the absolute path of a pstack Claude plugin root (one containing .claude-plugin/plugin.json) into $cfg; firstmate never installs pstack itself"
  fi
  raw=$(fm_pstack_trim "$(cat "$cfg")")
  if [ -z "$raw" ]; then
    fm_pstack_refuse 3 \
      "the pstack plugin configuration at $cfg is empty" \
      "write exactly one absolute path to a pstack Claude plugin root into $cfg"
  fi
  # The command substitution above strips trailing newlines only, so any
  # interior newline means the configuration holds more than one path.
  case "$raw" in
    *$'\n'*)
      fm_pstack_refuse 3 \
        "the pstack plugin configuration at $cfg must hold exactly one path" \
        "keep exactly one absolute path to a pstack Claude plugin root in $cfg and remove any extra lines"
      ;;
  esac
  case "$raw" in
    /*) ;;
    *)
      fm_pstack_refuse 3 \
        "the pstack plugin configuration at $cfg holds \"$raw\", which is not an absolute path" \
        "write exactly one absolute path to a pstack Claude plugin root into $cfg"
      ;;
  esac
  if [ ! -d "$raw" ]; then
    fm_pstack_refuse 4 \
      "the pstack plugin directory at $raw does not exist" \
      "correct the path in $cfg or check out the harness-neutral pstack Claude plugin at that path"
  fi
  FM_PSTACK_PLUGIN_DIR="$(cd "$raw" && pwd -P)"
  plugin_file="$FM_PSTACK_PLUGIN_DIR/.claude-plugin/plugin.json"
  if [ ! -f "$plugin_file" ]; then
    fm_pstack_refuse 4 \
      "$FM_PSTACK_PLUGIN_DIR is not a Claude plugin root: .claude-plugin/plugin.json is missing there" \
      "point $cfg at the plugin root itself (the directory containing .claude-plugin/plugin.json), not a folder of plugins"
  fi
  if ! command -v jq >/dev/null 2>&1; then
    fm_pstack_refuse 4 \
      "jq is required to read the pstack plugin's .claude-plugin/plugin.json and none is installed" \
      "install jq so the plugin name can be read the same way everywhere"
  fi
  if ! plugin=$(jq -r 'if (.name|type)=="string" then .name else "" end' "$plugin_file" 2>/dev/null); then
    fm_pstack_refuse 3 \
      "$plugin_file is not parseable JSON" \
      "fix the plugin.json in the pstack plugin check-out this configuration names"
  fi
  if [ -z "$plugin" ]; then
    fm_pstack_refuse 3 \
      "$plugin_file carries no usable \"name\" string" \
      "give the pstack plugin a name in its plugin.json so the entry can be formed as <plugin>:poteto-mode"
  fi
  FM_PSTACK_PLUGIN=$plugin
  FM_PSTACK_ENTRY="$plugin:poteto-mode"

  local skill="$FM_PSTACK_PLUGIN_DIR/skills/poteto-mode/SKILL.md"
  if [ ! -f "$skill" ]; then
    fm_pstack_refuse 4 \
      "the pstack entry skill is missing: $skill does not exist" \
      "point $cfg at a pstack plugin that ships the poteto-mode entry skill"
  fi
  if ! fm_pstack_entry_model_invocable "$skill"; then
    fm_pstack_refuse 4 \
      "the pstack entry at $skill is not model-invocable (its SKILL.md frontmatter is absent or sets disable-model-invocation: true)" \
      "use a harness-neutral pstack port such as michael-denyer/pstack-claude or ericlitman/open-pstack, whose copy of the upstream Cursor entry is model-invocable; the upstream cursor/plugins/pstack copy is Cursor-only"
  fi

  local hooks_mcp
  hooks_mcp=$(jq -r '.hooks // empty' "$plugin_file" 2>/dev/null || true)
  if [ -n "$hooks_mcp" ] || [ -d "$FM_PSTACK_PLUGIN_DIR/hooks" ]; then
    FM_PSTACK_HOOKS=present
  fi
  if [ -f "$FM_PSTACK_PLUGIN_DIR/.mcp.json" ] \
    || [ -n "$(jq -r '.mcpServers // empty' "$plugin_file" 2>/dev/null || true)" ]; then
    FM_PSTACK_MCP=present
  fi
}

do_resolve() {  # --harness <h>
  [ "${1:-}" = "--harness" ] || fm_pstack_refuse 2 \
    "usage: fm-pstack.sh resolve --harness <harness>" \
    "call resolve with exactly one --harness argument naming the worker runtime"
  [ "$#" -eq 2 ] || fm_pstack_refuse 2 \
    "usage: fm-pstack.sh resolve --harness <harness>" \
    "resolve takes exactly one --harness and one harness name"
  [ -n "$2" ] || fm_pstack_refuse 2 \
    "usage: fm-pstack.sh resolve --harness <harness>" \
    "--harness needs a value naming the worker runtime"
  # The harness matrix is checked before any local configuration reads, so an
  # unsupported harness is reported even on a machine with no plugin configured.
  case "$2" in
    claude)
      fm_pstack_resolve_core "$2"
      ;;
    *)
      fm_pstack_refuse 5 \
        "workflow=pstack is not supported on harness \"$2\"" \
        "pstack ships on claude only in v1 (fm-pstack.sh supported-harnesses prints the matrix); dispatch this task on a standard workflow instead"
      ;;
  esac
  printf 'workflow=pstack\n'
  printf 'harness=%s\n' "$2"
  printf 'plugin_dir=%s\n' "$FM_PSTACK_PLUGIN_DIR"
  printf 'plugin=%s\n' "$FM_PSTACK_PLUGIN"
  printf 'entry=%s\n' "$FM_PSTACK_ENTRY"
  printf 'load=plugin-dir\n'
  printf 'hooks=%s\n' "$FM_PSTACK_HOOKS"
  printf 'mcp=%s\n' "$FM_PSTACK_MCP"
}

do_supported_harnesses() {
  fm_pstack_supported_harnesses
}

do_template() {  # <id>
  [ "$#" -eq 1 ] || fm_pstack_refuse 2 \
    "usage: fm-pstack.sh template <task-id>" \
    "call template with exactly the task id the proof record is written for"
  local id=$1
  case "$id" in
    ""|.*|*/*) fm_pstack_refuse 2 \
      "usage: fm-pstack.sh template <task-id>" \
      "the proof record is written for a firstmate task id" ;;
  esac
  # The entry line is filled from the same resolution a spawn performs, so the
  # template cannot be rendered for a plugin that is not actually present; a
  # failure refuses with the resolve script's own exit codes and refusals.
  fm_pstack_resolve_core claude
  cat <<EOF
pstack-proof: v1
task: $id
entry: $FM_PSTACK_ENTRY
playbook: <playbook>
base: <40-hex>
candidate: <40-hex>
supersedes: <40-hex>   # optional, only after complete invalidation
## Reproduction or baseline
## Direct proof
## Not run and remaining uncertainty
## Pipeline outcome
EOF
}

# Proof-check failure collector: each failure is one newline-terminated line,
# and every failure is printed before exit 1 so the worker fixes all of them in
# one round.
FM_PSTACK_FAILURES=''
FM_PSTACK_NEXT=
fm_pstack_fail() {  # <reason>
  FM_PSTACK_FAILURES="$FM_PSTACK_FAILURES$1
"
}

do_proof_check() {  # <id>
  [ "$#" -eq 1 ] || fm_pstack_refuse 2 \
    "usage: fm-pstack.sh proof-check <task-id>" \
    "call proof-check with exactly the task id whose proof record is being checked"
  local id=$1 wt branch branch_head wt_branch nm_out sel run_id run_status
  local head_sha candidate base supersedes sec proof meta
  case "$id" in
    ""|.*|*/*) fm_pstack_refuse 2 \
      "usage: fm-pstack.sh proof-check <task-id>" \
      "the proof record is checked for a firstmate task id" ;;
  esac
  meta="$STATE/$id.meta"
  proof="$DATA/$id/pstack-proof.md"
  if [ ! -f "$meta" ]; then
    fm_pstack_refuse 1 \
      "no task record at $meta, so no pstack proof can be checked for $id" \
      "proof-check applies to a dispatched ship task's record"
  fi
  [ "$(fm_meta_get "$meta" kind)" = ship ] \
    || fm_pstack_fail "the task record for $id is not kind=ship, so there is no proof candidate to check"
  [ "$(fm_meta_get "$meta" workflow)" = pstack ] \
    || fm_pstack_fail "the task record for $id does not carry workflow=pstack, so the proof gate does not apply"
  branch=$(fm_meta_get "$meta" branch)
  [ -n "$branch" ] || branch="fm/$id"
  wt=$(fm_meta_get "$meta" worktree)
  if [ -z "$wt" ] || [ ! -d "$wt" ]; then
    fm_pstack_fail "the task record for $id names no existing worktree (worktree=$wt), so the candidate cannot be anchored"
    wt=
  elif ! git -C "$wt" rev-parse --git-dir >/dev/null 2>&1; then
    fm_pstack_fail "the task record for $id names $wt, which is not a git copy"
    wt=
  fi

  if [ ! -f "$proof" ]; then
    fm_pstack_refuse 1 \
      "no proof record at $proof" \
      "write it first with the exact template command from your Definition of done, then run proof-check again"
  fi

  entry=$(fm_pstack_proof_field "$proof" entry)
  case "$entry" in
    ""|*[[:space:]]*|'<'*) fm_pstack_fail "the proof record's entry field is missing, contains whitespace, or is an unfilled placeholder: \"$entry\"" ;;
  esac
  case "$entry" in
    *:*) ;;
    *) fm_pstack_fail "the proof record's entry field \"$entry\" is not a <plugin>:<skill> entry" ;;
  esac
  case "$(fm_pstack_proof_field "$proof" playbook)" in
    ""|*[[:space:]]*|'<'*) fm_pstack_fail "the proof record's playbook field is missing, contains whitespace, or is an unfilled placeholder" ;;
  esac
  case "$(fm_pstack_proof_field "$proof" task)" in
    "$id") ;;
    *) fm_pstack_fail "the proof record's task field does not name $id" ;;
  esac
  case "$(fm_pstack_proof_field "$proof" pstack-proof)" in
    v1) ;;
    *) fm_pstack_fail "the proof record does not open with the format header pstack-proof: v1" ;;
  esac

  head_sha=
  candidate=$(fm_pstack_proof_field "$proof" candidate)
  base=$(fm_pstack_proof_field "$proof" base)
  supersedes=$(fm_pstack_proof_field "$proof" supersedes)
  case "$supersedes" in
    '<'*) supersedes= ;;  # the template's unfilled placeholder line counts as no field
  esac
  if [ -n "$wt" ]; then
    head_sha=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || head_sha=
  fi

  if ! fm_pr_head_valid "$candidate"; then
    fm_pstack_fail "the proof record's candidate is missing or not a full commit sha: \"$candidate\""
  elif [ -n "$head_sha" ] && [ "$candidate" != "$head_sha" ]; then
    fm_pstack_fail "the proof record's candidate $candidate is not the worktree HEAD $head_sha; commit the exact proof candidate first"
  fi

  if [ -n "$wt" ] && [ -n "$head_sha" ]; then
    wt_branch=$(git -C "$wt" rev-parse --symbolic-full-name HEAD 2>/dev/null) || wt_branch=
    branch_head=$(git -C "$wt" rev-parse --verify --quiet "refs/heads/$branch" 2>/dev/null) || branch_head=
    if [ "$wt_branch" = "refs/heads/$branch" ] && [ -n "$branch_head" ] && [ "$branch_head" = "$head_sha" ]; then
      :
    else
      fm_pstack_fail "the worktree is not on the ship branch $branch with its tip at HEAD; commit the exact proof candidate on $branch"
    fi
    if [ -n "$(git -C "$wt" status --porcelain -uno 2>/dev/null || true)" ]; then
      fm_pstack_fail "the worktree has tracked uncommitted changes; commit them so the proof candidate is exact"
    fi
    if ! fm_pr_head_valid "$base"; then
      fm_pstack_fail "the proof record's base is missing or not a full commit sha: \"$base\""
    elif [ -z "$(git -C "$wt" rev-parse --verify --quiet "$base^{commit}" 2>/dev/null)" ]; then
      fm_pstack_fail "the proof record's base $base is not a commit this copy has"
    elif [ "$base" = "$candidate" ]; then
      fm_pstack_fail "the proof record's base $base is the candidate itself; a baseline is a strict ancestor of the change"
    elif ! git -C "$wt" merge-base --is-ancestor "$base" "$candidate" 2>/dev/null; then
      fm_pstack_fail "the proof record's base $base is not an ancestor of the candidate"
    fi
    if [ -n "$supersedes" ]; then
      if [ -z "$(git -C "$wt" rev-parse --verify --quiet "$supersedes^{commit}" 2>/dev/null)" ]; then
        fm_pstack_fail "the proof record's supersedes sha $supersedes is not a commit this copy has"
      elif git -C "$wt" merge-base --is-ancestor "$supersedes" "$candidate" 2>/dev/null; then
        fm_pstack_fail "the proof record's supersedes sha $supersedes is an ancestor of the candidate, so the invalidated work was never discarded"
      fi
    fi
  fi

  for sec in "## Reproduction or baseline" "## Direct proof" "## Not run and remaining uncertainty"; do
    if [ -z "$(fm_pstack_trim "$(fm_pstack_proof_section "$proof" "$sec")")" ]; then
      fm_pstack_fail "the proof record's \"$sec\" section is empty"
    fi
  done

  # No active no-mistakes run may hold the branch when the proof is checked:
  # the proof record describes the candidate's own work, and a pending or
  # running run means validation is already under way.
  sel=
  if [ -n "$wt" ] && nm_out=$(fm_nm_run_checked "$wt" 10 axi) && [ -n "$nm_out" ]; then
    sel=$(fm_nm_select_run "$branch" "$nm_out" "$wt" 10)
  fi
  if [ -z "$sel" ]; then
    fm_pstack_fail "the no-mistakes run state could not be read from the worktree (the axi overview failed or was empty)"
    FM_PSTACK_NEXT="rule 7 owns the daemon checks that decide when a pipeline block is real; confirm \`no-mistakes daemon status\` and \`no-mistakes axi status\`, then re-run proof-check"
  else
    case "$sel" in
      absent)
        ;;
      selected\|*)
        run_id=$(printf '%s' "$sel" | cut -d'|' -f2)
        run_status=$(printf '%s' "$sel" | cut -d'|' -f3)
        case "$run_status" in
          pending|running)
            fm_pstack_fail "a no-mistakes run ($run_id, $run_status) is already active on branch $branch; proof-check runs before validation, not alongside it"
            ;;
        esac
        ;;
      *)
        fm_pstack_fail "the no-mistakes run state for branch $branch could not be read ($sel)"
        FM_PSTACK_NEXT="confirm the run state with \`no-mistakes axi status\` and re-run proof-check, or stop and report why the state cannot be read"
        ;;
    esac
  fi

  if [ -n "$FM_PSTACK_FAILURES" ]; then
    printf '%s\n' "$FM_PSTACK_FAILURES" | while IFS= read -r line; do
      [ -n "$line" ] || continue
      printf 'error: %s\n' "$line"
    done
    if [ -n "$FM_PSTACK_NEXT" ]; then
      printf 'next: %s\n' "$FM_PSTACK_NEXT"
    fi
    exit 1
  fi
  printf 'ok candidate=%s\n' "$candidate"
}

case "${1:-}" in
  resolve)
    shift
    do_resolve "$@"
    ;;
  supported-harnesses)
    do_supported_harnesses
    ;;
  template)
    shift
    do_template "$@"
    ;;
  proof-check)
    shift
    do_proof_check "$@"
    ;;
  "")
    fm_pstack_refuse 2 \
      "usage: fm-pstack.sh resolve --harness <harness> | supported-harnesses | template <task-id> | proof-check <task-id>" \
      "pick one of the four commands; the script's header owns each contract"
    ;;
  *)
    fm_pstack_refuse 2 \
      "unknown command \"$1\" (expected resolve, supported-harnesses, template, or proof-check)" \
      "see the usage comment in this script's header for each command's contract"
    ;;
esac