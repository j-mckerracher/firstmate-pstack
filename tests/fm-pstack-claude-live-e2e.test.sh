#!/usr/bin/env bash
# Opt-in credentialed Claude live regression for the pstack worker workflow's
# plugin availability contract (bin/fm-pstack.sh resolves config/pstack-plugin
# and fm-spawn launches pstack ships with `claude --plugin-dir <path>`).
# Proves, against the real installed Claude Code and a harness-neutral pstack
# plugin checkout named by FM_PSTACK_PLUGIN_DIR:
#   1. A session launched with `claude --plugin-dir <P>` reports the plugin's
#      model-invocable `pstack:poteto-mode` entry in its stream-json init event,
#      so the entry the workflow's availability and proof contracts name is
#      genuinely reachable from the model's side of a real session.
#   2. A session launched without `--plugin-dir` reports no `pstack:poteto-mode`
#      in its init event, so standard workers never see pstack and the
#      worker's argv is genuinely the only load path (contract item 12's gate
#      isolation, exercised on the real harness).
# Neither turn requires the pstack machinery itself beyond the plugin root;
# both spend one small model turn on the installed Claude Code, so this stays
# opt-in. The plugin checkout is read, never installed or written.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_PSTACK_CLAUDE_LIVE claude

PLUGIN_DIR="${FM_PSTACK_PLUGIN_DIR:-}"
[ -n "$PLUGIN_DIR" ] \
  || fail "FM_PSTACK_PLUGIN_DIR must name a pstack Claude plugin root (a checkout of a harness-neutral pstack port) to run this live guard"
[ -d "$PLUGIN_DIR" ] \
  || fail "FM_PSTACK_PLUGIN_DIR='$PLUGIN_DIR' is not a directory"
[ -f "$PLUGIN_DIR/.claude-plugin/plugin.json" ] \
  || fail "FM_PSTACK_PLUGIN_DIR='$PLUGIN_DIR' has no .claude-plugin/plugin.json, so it is not a pstack Claude plugin root"
[ -f "$PLUGIN_DIR/skills/poteto-mode/SKILL.md" ] \
  || fail "FM_PSTACK_PLUGIN_DIR='$PLUGIN_DIR' has no skills/poteto-mode/SKILL.md, so the expected pstack:poteto-mode entry cannot load"

CLAUDE_VERSION=$(claude --version 2>/dev/null || true)
[ -n "$CLAUDE_VERSION" ] || fail "claude is installed but reports no version"
LAB=$(fm_test_tmproot fm-pstack-claude-live)
PROJECT="$LAB/project"
ENTRY='pstack:poteto-mode'

cleanup() {
  rm -rf "$LAB" 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup EXIT

mkdir -p "$PROJECT"

# Claude Code refuses to nest inside another Claude session, so the inherited
# session markers are dropped from the env of the lab launch.
unset_inherited() {
  local name
  while IFS= read -r name; do
    printf -- '-u %s ' "$name"
  done < <(env | grep -E '^(CLAUDECODE|CLAUDE_CODE_[A-Z_]+|CLAUDE_CONFIG_DIR)=' | cut -d= -f1 | sort -u)
}

# run_claude <transcript> -> the extra arguments select the plugin load path
run_claude() {
  local transcript=$1
  shift
  (
    cd "$PROJECT" || exit 1
    env $(unset_inherited) CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 \
      DISABLE_AUTOUPDATER=1 claude -p "Reply with exactly READY." \
      --model haiku --dangerously-skip-permissions \
      --output-format stream-json --verbose "$@"
  ) > "$transcript" 2>&1
}

init_event() {  # <transcript>
  # The -p stream may open with non-JSON harness warnings (an API-key auth note),
  # so only lines that open with a JSON object count as transcript events.
  grep '^{' "$1" 2>/dev/null | jq -c 'select(.type == "system" and .subtype == "init")' | head -n 1
}

# --- 1. Without --plugin-dir: the standard worker's init lists no pstack entry --
run_claude "$LAB/standard.jsonl"
INIT=$(init_event "$LAB/standard.jsonl")
[ -n "$INIT" ] || fail "Claude Code $CLAUDE_VERSION produced no stream-json init event in the standard launch: $(head -5 "$LAB/standard.jsonl" 2>/dev/null)"
case "$INIT" in
  *"$ENTRY"*)
    printf '%s\n' "$INIT" >&2
    fail "Claude Code $CLAUDE_VERSION listed $ENTRY in the init event although no --plugin-dir was passed"
    ;;
esac
pass "Claude Code $CLAUDE_VERSION without --plugin-dir: the init event lists no $ENTRY entry"

# --- 2. With --plugin-dir: the pstack worker's init lists the entry ------------
run_claude "$LAB/pstack.jsonl" --plugin-dir "$PLUGIN_DIR"
INIT=$(init_event "$LAB/pstack.jsonl")
[ -n "$INIT" ] || fail "Claude Code $CLAUDE_VERSION produced no stream-json init event in the --plugin-dir launch: $(head -5 "$LAB/pstack.jsonl" 2>/dev/null)"
case "$INIT" in
  *"$ENTRY"*) : ;;
  *)
    printf '%s\n' "$INIT" >&2
    fail "Claude Code $CLAUDE_VERSION did not list $ENTRY in the init event with --plugin-dir '$PLUGIN_DIR'"
    ;;
esac
pass "Claude Code $CLAUDE_VERSION with --plugin-dir: the init event lists the $ENTRY entry"