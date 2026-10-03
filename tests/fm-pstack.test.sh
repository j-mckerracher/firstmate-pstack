#!/usr/bin/env bash
# Behavior tests for bin/fm-pstack.sh, the single owner of the pstack worker
# workflow's availability resolution and its deterministic proof record.
# Covers the resolve report and every refusal exit code, the template command,
# and the proof-check self-check's happy path plus every failure line.
set -u

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/pstack-plugin-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/pstack-plugin-fixture.sh"

TMP_ROOT=$(fm_test_tmproot fm-pstack)
fm_git_identity fmtest fmtest@example.invalid

HOME_DIR="$TMP_ROOT/home"
CONF="$HOME_DIR/config"
STATE="$HOME_DIR/state"
DATA="$HOME_DIR/data"
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$CONF" "$STATE" "$DATA" "$FAKEBIN"

# Resolves to a valid fixture plugin under $TMP_ROOT; each resolve case points
# $CONF/pstack-plugin where it needs.
plugin_resolve() {  # [<harness>]: run resolve against the fixture home
  out=$(env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
    "$ROOT/bin/fm-pstack.sh" resolve --harness "${1:-claude}" 2>&1)
}

plugin_supported() {
  out=$(env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
    "$ROOT/bin/fm-pstack.sh" supported-harnesses 2>&1)
}

set_cfg() {  # <value>
  printf '%s\n' "$1" > "$CONF/pstack-plugin"
}

rm_cfg() {
  rm -f "$CONF/pstack-plugin"
}

VALID_PLUGIN="$TMP_ROOT/plugin-valid"

test_supported_harnesses_is_claude_only() {
  plugin_supported
  assert_equals "claude" "$out" "supported-harnesses printed more than claude"
  pass "supported-harnesses prints exactly claude"
}

test_resolve_success_report() {
  pstack_write_plugin "$VALID_PLUGIN" pstack
  set_cfg "$VALID_PLUGIN"
  plugin_resolve
  expect_code 0 "$?" "valid resolve"
  assert_contains "$out" "workflow=pstack" "resolve report lost workflow"
  assert_contains "$out" "harness=claude" "resolve report lost harness"
  assert_contains "$out" "plugin_dir=" "resolve report lost plugin_dir"
  assert_contains "$out" "plugin=pstack" "resolve report lost plugin name"
  assert_contains "$out" "entry=pstack:poteto-mode" "resolve did not form the entry"
  assert_contains "$out" "load=plugin-dir" "resolve report lost load"
  assert_contains "$out" "hooks=none" "clean plugin resolved hooks=present"
  assert_contains "$out" "mcp=none" "clean plugin resolved mcp=present"
  pass "valid resolve prints the full report"
}

test_resolve_absent_config_is_exit_4() {
  rm_cfg
  plugin_resolve
  expect_code 4 "$?" "missing config exit code"
  assert_contains "$out" "error: no pstack plugin is configured" "missing config error message"
  assert_contains "$out" "next:" "missing config refusal carries no next line"
  pass "absent config refuses with exit 4"
}

test_resolve_empty_config_is_exit_3() {
  set_cfg ""
  plugin_resolve
  expect_code 3 "$?" "empty config exit code"
  assert_contains "$out" "error:" "empty config error message"
  pass "empty config refuses with exit 3"
}

test_resolve_multiline_config_is_exit_3() {
  set_cfg "$VALID_PLUGIN
$VALID_PLUGIN"
  plugin_resolve
  expect_code 3 "$?" "multiline config exit code"
  assert_contains "$out" "must hold exactly one path" "multiline config error message"
  pass "multiline config refuses with exit 3"
}

test_resolve_relative_path_is_exit_3() {
  set_cfg "relative/plugin"
  plugin_resolve
  expect_code 3 "$?" "relative config exit code"
  assert_contains "$out" "not an absolute path" "relative path error message"
  pass "relative path refuses with exit 3"
}

test_resolve_missing_dir_is_exit_4() {
  set_cfg "$TMP_ROOT/plugin-absent"
  plugin_resolve
  expect_code 4 "$?" "missing plugin dir exit code"
  assert_contains "$out" "does not exist" "missing dir error message"
  pass "missing plugin directory refuses with exit 4"
}

test_resolve_folder_of_plugins_is_exit_4() {
  pstack_plugins_folder "$TMP_ROOT/plugins-folder"
  set_cfg "$TMP_ROOT/plugins-folder"
  plugin_resolve
  expect_code 4 "$?" "folder of plugins exit code"
  assert_contains "$out" "not a Claude plugin root" "folder-of-plugins error message"
  pass "a folder of plugins refuses with exit 4"
}

test_resolve_malformed_json_is_exit_3() {
  pstack_write_plugin_malformed "$TMP_ROOT/plugin-malformed"
  set_cfg "$TMP_ROOT/plugin-malformed"
  plugin_resolve
  expect_code 3 "$?" "malformed plugin.json exit code"
  assert_contains "$out" "not parseable JSON" "malformed json error message"
  pass "malformed plugin.json refuses with exit 3"
}

test_resolve_no_name_is_exit_3() {
  pstack_write_plugin_no_name "$TMP_ROOT/plugin-noname"
  set_cfg "$TMP_ROOT/plugin-noname"
  plugin_resolve
  expect_code 3 "$?" "no-name plugin.json exit code"
  assert_contains "$out" "no usable \"name\"" "no-name error message"
  pass "plugin.json without a name refuses with exit 3"
}

test_resolve_missing_entry_skill_is_exit_4() {
  pstack_write_plugin "$TMP_ROOT/plugin-noskill" pstack
  rm -rf "$TMP_ROOT/plugin-noskill/skills"
  set_cfg "$TMP_ROOT/plugin-noskill"
  plugin_resolve
  expect_code 4 "$?" "missing entry skill exit code"
  assert_contains "$out" "the pstack entry skill is missing" "missing skill error message"
  pass "missing poteto-mode skill refuses with exit 4"
}

test_resolve_disabled_entry_is_exit_4() {
  pstack_write_plugin_disabled "$TMP_ROOT/plugin-disabled"
  set_cfg "$TMP_ROOT/plugin-disabled"
  plugin_resolve
  expect_code 4 "$?" "disabled entry exit code"
  assert_contains "$out" "not model-invocable" "disabled entry error message"
  assert_contains "$out" "harness-neutral pstack port" "disabled entry next line"
  pass "disable-model-invocation entry refuses with exit 4"
}

test_resolve_entry_without_frontmatter_is_exit_4() {
  pstack_write_plugin "$TMP_ROOT/plugin-nofm" pstack
  printf 'plain body\n' > "$TMP_ROOT/plugin-nofm/skills/poteto-mode/SKILL.md"
  set_cfg "$TMP_ROOT/plugin-nofm"
  plugin_resolve
  expect_code 4 "$?" "no-frontmatter entry exit code"
  assert_contains "$out" "not model-invocable" "no-frontmatter error message"
  pass "an entry skill without frontmatter refuses with exit 4"
}

test_resolve_hooks_and_mcp_detection() {
  pstack_write_plugin_hooks "$TMP_ROOT/plugin-hooks" pstack
  pstack_write_plugin_mcp_file "$TMP_ROOT/plugin-mcpfile" pstack
  pstack_write_plugin_mcp_json "$TMP_ROOT/plugin-mcpjson" pstack
  set_cfg "$TMP_ROOT/plugin-hooks"
  plugin_resolve
  assert_contains "$out" "hooks=present" "hooks/ directory not detected"
  assert_contains "$out" "mcp=none" "hooks-only plugin resolved mcp=present"
  set_cfg "$TMP_ROOT/plugin-mcpfile"
  plugin_resolve
  assert_contains "$out" "mcp=present" "plugin-root .mcp.json not detected"
  assert_contains "$out" "hooks=none" "mcp-file plugin resolved hooks=present"
  set_cfg "$TMP_ROOT/plugin-mcpjson"
  plugin_resolve
  assert_contains "$out" "mcp=present" "plugin.json mcpServers not detected"
  pass "hooks and mcp are reported from both sources"
}

test_resolve_unsupported_harness_is_exit_5() {
  set_cfg "$VALID_PLUGIN"
  plugin_resolve codex
  expect_code 5 "$?" "unsupported harness exit code"
  assert_contains "$out" "not supported on harness" "unsupported harness error message"
  # The harness matrix is checked before any configuration read: no config file.
  rm_cfg
  plugin_resolve codex
  expect_code 5 "$?" "unsupported harness exit code without config"
  pass "unsupported harness refuses with exit 5 before reading config"
}

test_resolve_usage_is_exit_2() {
  out=$(env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
    "$ROOT/bin/fm-pstack.sh" resolve --harness claude extra 2>&1)
  expect_code 2 "$?" "resolve with extra args exit code"
  rm_cfg
  out=$(env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
    "$ROOT/bin/fm-pstack.sh" resolve 2>&1)
  expect_code 2 "$?" "resolve without --harness exit code"
  out=$(env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
    "$ROOT/bin/fm-pstack.sh" resolve --harness 2>&1)
  expect_code 2 "$?" "resolve without a harness value exit code"
  out=$(env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" "$ROOT/bin/fm-pstack.sh" bogus 2>&1)
  expect_code 2 "$?" "unknown command exit code"
  pass "wrong usage refuses with exit 2"
}

test_template_prints_the_proof_format() {
  set_cfg "$VALID_PLUGIN"
  out=$(env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
    "$ROOT/bin/fm-pstack.sh" template pp-task 2>&1)
  expect_code 0 "$?" "template exit code"
  assert_contains "$out" "pstack-proof: v1" "template header line"
  assert_contains "$out" "task: pp-task" "template task line"
  assert_contains "$out" "entry: pstack:poteto-mode" "template entry line not resolved from config"
  assert_contains "$out" "## Reproduction or baseline" "template reproduction section"
  assert_contains "$out" "## Direct proof" "template direct-proof section"
  assert_contains "$out" "## Not run and remaining uncertainty" "template uncertainty section"
  assert_contains "$out" "## Pipeline outcome" "template pipeline-outcome section"
  pass "template prints the proof skeleton with the resolved entry"
}

test_template_refuses_like_resolve() {
  rm_cfg
  out=$(env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
    "$ROOT/bin/fm-pstack.sh" template pp-task 2>&1)
  expect_code 4 "$?" "template with absent config exit code"
  out=$(env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
    "$ROOT/bin/fm-pstack.sh" template pp/task 2>&1)
  expect_code 2 "$?" "template with a slash id exit code"
  pass "template reuses resolve's refusals and rejects a slash id"
}

# --- proof-check -------------------------------------------------------------

# pc_setup <task-id> <branch>: write the fixture repo, worktree, meta, fake
# no-mistakes (zero-run), and return nothing. Sets PC_REPO/PC_WT/PC_ID/PC_BRANCH/
# PC_BASE/PC_PROOF, and makes a first commit (base) plus a second (candidate) on
# the branch with HEAD there.
pc_setup() {
  PC_ID=$1
  PC_BRANCH=$2
  PC_REPO="$TMP_ROOT/pc-repo"
  PC_WT="$TMP_ROOT/pc-wt"
  rm -rf "$PC_REPO" "$TMP_ROOT/pc-repo.origin.git"
  fm_git_worktree "$PC_REPO" "$PC_WT" "$PC_BRANCH"
  printf '%s\n' change > "$PC_WT/fixed.txt"
  git -C "$PC_WT" add fixed.txt
  git -C "$PC_WT" commit -qm 'the proof candidate'
  PC_BASE=$(git -C "$PC_WT" rev-parse HEAD~1)
  PC_CAND=$(git -C "$PC_WT" rev-parse HEAD)
  PC_META="$STATE/$PC_ID.meta"
  PC_PROOF="$DATA/$PC_ID/pstack-proof.md"
  mkdir -p "$DATA/$PC_ID"
  fm_write_meta "$PC_META" "kind=ship" "workflow=pstack" "branch=$PC_BRANCH" "worktree=$PC_WT"
}

# pc_write_proof: write a well-formed proof for the current PC_* variables.
pc_write_proof() {  # [task] [candidate] [base] [supersedes]
  {
    printf 'pstack-proof: v1\ntask: %s\nentry: pstack:poteto-mode\nplaybook: one-run-diagnosis\nbase: %s\ncandidate: %s\nsupersedes: %s   # optional, only after complete invalidation\n' \
      "${1:-$PC_ID}" "${3:-$PC_BASE}" "${2:-$PC_CAND}" "${4:-<40-hex>}"
    printf '## Reproduction or baseline\n'
    printf 'Reproduction run before the change failed with the observed trace.\n'
    printf '\n'
    printf '## Direct proof\n'
    printf 'Re-run of the same command after the change exits 0.\n'
    printf '\n'
    printf '## Not run and remaining uncertainty\n'
    printf 'The flaky timer path is not exercised.\n'
    printf '\n'
    printf '## Pipeline outcome\n'
  } > "$PC_PROOF"
}

pc_run() {  # <task-id>: proof-check under the fixture home with the fake axi
  out=$(env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
    PATH="$FAKEBIN:$PATH" \
    "$ROOT/bin/fm-pstack.sh" proof-check "$1" 2>&1)
}

pc_orphan_commit() {  # make a non-ancestor orphan commit; echo its sha
  git -C "$PC_WT" checkout -q --orphan pc-orphan
  git -C "$PC_WT" rm -qrf --ignore-unmatch . >/dev/null 2>&1 || true
  printf 'orphan\n' > "$PC_WT/orphan.txt"
  git -C "$PC_WT" add orphan.txt
  git -C "$PC_WT" commit -qm 'orphan'
  git -C "$PC_WT" rev-parse HEAD
}

test_proof_check_happy_path() {
  set_cfg "$VALID_PLUGIN"
  pc_setup pc1 fm/pc1
  pstack_fake_axi "$FAKEBIN" "$PC_WT" "0 of 0 total"
  pc_write_proof
  pc_run pc1
  expect_code 0 "$?" "happy-path proof-check"
  assert_contains "$out" "ok candidate=$PC_CAND" "happy path ok line"
  pass "well-formed proof anchored at HEAD passes"
}

test_proof_check_missing_meta_is_refusal() {
  mv "$PC_META" "$PC_META.keep"
  pc_run pc1
  expect_code 1 "$?" "missing meta exit code"
  assert_contains "$out" "next:" "missing meta carries no next line"
  mv "$PC_META.keep" "$PC_META"
  pass "proof-check without a task record refuses"
}

test_proof_check_missing_proof_is_refusal() {
  mv "$PC_PROOF" "$PC_PROOF.keep"
  pc_run pc1
  expect_code 1 "$?" "missing proof exit code"
  assert_contains "$out" "write it first with the exact template command" "missing proof next line"
  mv "$PC_PROOF.keep" "$PC_PROOF"
  pass "proof-check without a proof record refuses with the template pointer"
}

test_proof_check_meta_not_ship_or_not_pstack() {
  fm_write_meta "$PC_META" "kind=scan" "workflow=standard" "branch=$PC_BRANCH" "worktree=$PC_WT"
  pc_run pc1
  expect_code 1 "$?" "non-ship meta exit code"
  assert_contains "$out" "error: the task record for $PC_ID is not kind=ship" "non-ship meta error"
  assert_contains "$out" "error: the task record for $PC_ID does not carry workflow=pstack" "non-pstack meta error"
  fm_write_meta "$PC_META" "kind=ship" "workflow=pstack" "branch=$PC_BRANCH" "worktree=$PC_WT"
  pass "meta gates kind=ship and workflow=pstack"
}

test_proof_check_field_failures() {
  printf 'pstack-proof: v2\ntask: other\nentry: notentry\nplaybook: \nbase: %s\ncandidate: nope\n' "$PC_BASE" > "$PC_PROOF"
  printf '## Reproduction or baseline\n## Direct proof\n## Not run and remaining uncertainty\n## Pipeline outcome\n' >> "$PC_PROOF"
  pc_run pc1
  expect_code 1 "$?" "field failure exit code"
  # Every failure is listed in one round, one error: line each.
  for needle in \
    "error: the proof record's task field does not name $PC_ID" \
    'does not open with the format header pstack-proof: v1' \
    'is not a <plugin>:<skill> entry' \
    'playbook field is missing' \
    'candidate is missing or not a full commit sha' \
    '"## Reproduction or baseline" section is empty' \
    '"## Direct proof" section is empty' \
    '"## Not run and remaining uncertainty" section is empty'; do
    assert_contains "$out" "$needle" "field failure batch missed: $needle"
  done
  pass "field failures are all listed in one round"
}

test_proof_check_git_anchoring_failures() {
  pc_write_proof
  # Candidate not HEAD: the proof names the base commit while HEAD is the fix.
  pc_write_proof "$PC_ID" "$PC_BASE" "$PC_BASE" "<40-hex>"
  pc_run pc1
  expect_code 1 "$?" "wrong candidate exit code"
  assert_contains "$out" "is not the worktree HEAD $PC_CAND" "candidate-not-head error"
  # Dirty tracked tree.
  pc_write_proof
  printf 'dirty\n' >> "$PC_WT/fixed.txt"
  pc_run pc1
  assert_contains "$out" "tracked uncommitted changes" "dirty worktree error"
  git -C "$PC_WT" checkout -q -- fixed.txt
  # Off the ship branch entirely.
  git -C "$PC_WT" checkout -q --detach HEAD~0
  pc_run pc1
  assert_contains "$out" "not on the ship branch $PC_BRANCH" "off-branch error"
  git -C "$PC_WT" checkout -q "$PC_BRANCH"
  pass "git anchoring failures are reported"
}

test_proof_check_base_and_supersedes_rules() {
  # base == candidate is never a baseline.
  pc_write_proof "$PC_ID" "$PC_CAND" "$PC_CAND" "<40-hex>"
  pc_run pc1
  assert_contains "$out" "a baseline is a strict ancestor" "base==candidate error"
  # base not a commit this copy has.
  pc_write_proof "$PC_ID" "$PC_CAND" "0000000000000000000000000000000000000000" "<40-hex>"
  pc_run pc1
  assert_contains "$out" "not a commit this copy has" "unreachable base error"
  # supersedes pointing at an ancestor commit is a contradiction.
  pc_write_proof "$PC_ID" "$PC_CAND" "$PC_BASE" "$PC_BASE"
  pc_run pc1
  assert_contains "$out" "supersedes sha $PC_BASE is an ancestor of the candidate" "supersedes-ancestor error"
  # supersedes pointing at a discarded (non-ancestor) commit is accepted.
  PC_SUP=$(pc_orphan_commit)
  git -C "$PC_WT" checkout -q "$PC_BRANCH"
  pc_write_proof "$PC_ID" "$PC_CAND" "$PC_BASE" "$PC_SUP"
  pc_run pc1
  assert_contains "$out" "ok candidate=$PC_CAND" "non-ancestor supersedes was refused"
  # supersedes not a commit at all.
  pc_write_proof "$PC_ID" "$PC_CAND" "$PC_BASE" "1234567890123456789012345678901234567890"
  pc_run pc1
  assert_contains "$out" "supersedes sha 1234567890123456789012345678901234567890 is not a commit this copy has" "unreachable supersedes error"
  pass "base and supersedes rules hold end to end"
}

test_proof_check_run_state_gate() {
  pc_write_proof
  # An active run must fail.
  pstack_fake_axi "$FAKEBIN" "$PC_WT" "1 of 1 total" \
    "r-1,$PC_BRANCH,pending,$PC_CAND,\"\""
  pc_run pc1
  expect_code 1 "$?" "active run exit code"
  assert_contains "$out" "already active on branch $PC_BRANCH" "active-run error"
  # A terminal run is fine.
  pstack_fake_axi "$FAKEBIN" "$PC_WT" "1 of 1 total" \
    "r-1,$PC_BRANCH,completed,$PC_CAND,\"\""
  pc_run pc1
  assert_contains "$out" "ok candidate=$PC_CAND" "terminal run was not accepted"
  # A garbage overview fails closed with a next line.
  cat > "$FAKEBIN/no-mistakes" <<'SH'
#!/bin/bash
case "$1" in
  axi) printf 'garbage output\n' ;;
esac
SH
  chmod +x "$FAKEBIN/no-mistakes"
  pc_run pc1
  expect_code 1 "$?" "garbage overview exit code"
  assert_contains "$out" "no-mistakes run state for branch $PC_BRANCH could not be read" "garbage overview error"
  assert_contains "$out" "next:" "garbage overview next line"
  # A missing binary fails closed too.
  rm -f "$FAKEBIN/no-mistakes"
  pc_run pc1
  expect_code 1 "$?" "missing binary exit code"
  assert_contains "$out" "the axi overview failed or was empty" "missing binary error"
  assert_contains "$out" "next:" "missing binary next line"
  pass "run-state gate passes terminal, refuses active, fails closed on unreadable"
}

test_proof_check_usage_id_shape() {
  pc_run pp/1
  expect_code 2 "$?" "slash id exit code"
  pc_run ''
  expect_code 2 "$?" "empty id exit code"
  pass "proof-check rejects ids that cannot name a record"
}

test_supported_harnesses_is_claude_only
test_resolve_success_report
test_resolve_absent_config_is_exit_4
test_resolve_empty_config_is_exit_3
test_resolve_multiline_config_is_exit_3
test_resolve_relative_path_is_exit_3
test_resolve_missing_dir_is_exit_4
test_resolve_folder_of_plugins_is_exit_4
test_resolve_malformed_json_is_exit_3
test_resolve_no_name_is_exit_3
test_resolve_missing_entry_skill_is_exit_4
test_resolve_disabled_entry_is_exit_4
test_resolve_entry_without_frontmatter_is_exit_4
test_resolve_hooks_and_mcp_detection
test_resolve_unsupported_harness_is_exit_5
test_resolve_usage_is_exit_2
test_template_prints_the_proof_format
test_template_refuses_like_resolve
test_proof_check_happy_path
test_proof_check_missing_meta_is_refusal
test_proof_check_missing_proof_is_refusal
test_proof_check_meta_not_ship_or_not_pstack
test_proof_check_field_failures
test_proof_check_git_anchoring_failures
test_proof_check_base_and_supersedes_rules
test_proof_check_run_state_gate
test_proof_check_usage_id_shape

echo "all fm-pstack tests passed"