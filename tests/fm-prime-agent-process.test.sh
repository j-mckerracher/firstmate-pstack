#!/usr/bin/env bash
# Prime process attribution through the shared classifier and backend interfaces.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/prime-process-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/prime-process-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-prime-agent-process)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
HOME_DIR="$TMP_ROOT/home"
fm_test_prime_ps "$FAKEBIN"

test_prime_full_process_evidence_classifies_roles() {
  local comm argv0 args expected got
  while IFS='|' read -r comm argv0 args expected; do
    got=$(fm_test_prime_eval "$HOME_DIR" "$FAKEBIN" '
      . "$0/bin/fm-agent-process-lib.sh"
      fm_agent_process_classify "$FM_TEST_PRIME_COMM" "$FM_TEST_ARGV0" "$FM_TEST_PRIME_ARGS"
    ' "FM_TEST_PRIME_COMM=$comm" "FM_TEST_ARGV0=$argv0" "FM_TEST_PRIME_ARGS=$args")
    [ "$got" = "$expected" ] \
      || fail "Prime process '$comm' / '$args' classified '$got', expected '$expected'"
  done <<'CASES'
prime-agent|/fixture/bin/prime-agent|/fixture/bin/prime-agent worker|agent
/fixture/share/prime-agent/prime-agent|/fixture/share/prime-agent/prime-agent|/fixture/share/prime-agent/prime-agent worker|agent
prime-agent|/fixture/bin/prime-agent|/fixture/bin/prime-agent --print hello|agent
prime-agent|/fixture/bin/prime-agent|/fixture/bin/prime-agent --mode json|agent
prime-agent|/fixture/bin/prime-agent|/fixture/bin/prime-agent --mode rpc|agent
pa-daemon|/fixture/bin/pa-daemon|/fixture/bin/pa-daemon worker|agent
prime-agent|/fixture/bin/prime-agent|/fixture/bin/prime-agent --mode daemon|other
pa-daemon|/fixture/bin/pa-daemon|/fixture/bin/pa-daemon supervisor|other
prime-agent-rust|/fixture/bin/prime-agent-rust|/fixture/bin/prime-agent-rust worker|other
pa-cli|/fixture/bin/pa-cli|/fixture/bin/pa-cli worker|other
pa-tui-replay|/fixture/bin/pa-tui-replay|/fixture/bin/pa-tui-replay worker|other
prime-agent-helper|/fixture/bin/prime-agent-helper|/fixture/bin/prime-agent-helper worker|other
python3|/fixture/bin/python3|/fixture/bin/python3 -m rlm.repl prime-agent worker|other
node|/fixture/bin/node|/fixture/bin/node /fixture/prime-agent/tool.js|other
sh|/bin/sh|/bin/sh -c prime-agent worker|shell
/fixture/prime-agent/runner|/fixture/prime-agent/runner|/fixture/prime-agent/runner worker|other
prime-agent|/fixture/bin/prime-agent||other
CASES
  for comm in prime-agent /fixture/bin/prime-agent pa-daemon /fixture/bin/pa-daemon; do
    got=$(fm_test_prime_eval "$HOME_DIR" "$FAKEBIN" '
      . "$0/bin/fm-agent-process-lib.sh"
      fm_agent_process_classify_name "$FM_TEST_PRIME_COMM"
    ' "FM_TEST_PRIME_COMM=$comm")
    [ "$got" = other ] || fail "role-less Prime name '$comm' classified '$got', expected conservative other"
  done
  pass "Prime process classification requires full role evidence; name-only supervisors stay ambiguous"
}

test_prime_nul_argv_controls_process_and_lock_evidence() {
  local comm args expected got
  mkdir -p "$HOME_DIR/proc/700"
  while IFS='|' read -r comm args expected; do
    case "$expected" in
      agent) expected=$'agent\nlive' ;;
      other) expected=$'other\nrejected' ;;
    esac
    case "$args" in
      worker) printf '%s\0' "/fixture/bin/$comm" worker > "$HOME_DIR/proc/700/cmdline" ;;
      supervisor) printf '%s\0' "/fixture/bin/$comm" --mode daemon > "$HOME_DIR/proc/700/cmdline" ;;
      print) printf '%s\0' "/fixture/bin/$comm" --print 'explain --mode daemon' > "$HOME_DIR/proc/700/cmdline" ;;
      empty) : > "$HOME_DIR/proc/700/cmdline" ;;
      unterminated) printf '%s' "/fixture/bin/$comm worker" > "$HOME_DIR/proc/700/cmdline" ;;
    esac
    got=$(fm_test_prime_eval "$HOME_DIR" "$FAKEBIN" '
      . "$0/bin/fm-agent-process-lib.sh"
      fm_agent_process_classify "$FM_TEST_PRIME_COMM" "/fixture/bin/$FM_TEST_PRIME_COMM" "$FM_TEST_PRIME_ARGS" 700
      printf "\n"
      if fm_harness_pid_alive 700; then printf live; else printf rejected; fi
    ' "FM_TEST_PRIME_COMM=$comm" "FM_TEST_PRIME_ARGS=/fixture/bin/$comm worker")
    [ "$got" = "$expected" ] || fail "Prime NUL argv '$comm' / '$args' yielded '$got', expected '$expected'"
  done <<'CASES'
prime-agent|worker|agent
pa-daemon|worker|agent
prime-agent|supervisor|other
prime-agent|print|agent
prime-agent|empty|other
prime-agent|unterminated|other
CASES
  rm -f "$HOME_DIR/proc/700/cmdline"
  pass "Prime process and lock evidence agree on bounded NUL argv and reject unreadable role evidence"
}

test_prime_tmux_uses_process_roles_not_name_only() {
  local comm args expected pid got
  rm -f "$HOME_DIR/proc/700/cmdline"
  while IFS='|' read -r comm args expected pid; do
    got=$(fm_test_prime_eval "$HOME_DIR" "$FAKEBIN" '
      . "$0/bin/fm-backend.sh"
      fm_backend_source tmux || exit 1
      fm_backend_tmux_window_inventory() { printf "%s\n" pane; }
      fm_backend_tmux_foreground_comms() { printf "%s\n" "$FM_TEST_PRIME_COMM"; }
      fm_backend_tmux_foreground_argv0s() { printf "%s\n" "${FM_TEST_PRIME_ARGS%% *}"; }
      fm_backend_tmux_foreground_pids() { printf "%s\n" "$FM_TEST_PRIME_FOREGROUND_PID"; }
      fm_backend_tmux_foreground_args() { printf "%s\n" "$FM_TEST_PRIME_ARGS"; }
      fm_backend_tmux_current_command() { printf "%s\n" "$FM_TEST_PRIME_COMM"; }
      fm_backend_agent_state tmux fixture:pane
    ' "FM_TEST_PRIME_COMM=$comm" "FM_TEST_PRIME_ARGS=$args" "FM_TEST_PRIME_FOREGROUND_PID=$pid")
    [ "$got" = "$expected" ] \
      || fail "Prime tmux fixture '$comm' / '$args' yielded '$got', expected '$expected'"
  done <<'CASES'
prime-agent|/fixture/bin/prime-agent worker|alive|700
/fixture/share/prime-agent/prime-agent|/fixture/share/prime-agent/prime-agent worker|alive|700
pa-daemon|/fixture/bin/pa-daemon worker|alive|700
prime-agent|/fixture/bin/prime-agent --print hello|alive|700
prime-agent|/fixture/bin/prime-agent --mode daemon|ambiguous|700
pa-daemon|/fixture/bin/pa-daemon supervisor|ambiguous|700
prime-agent-helper|/fixture/bin/prime-agent-helper worker|ambiguous|700
python3|/fixture/bin/python3 -m rlm.repl prime-agent worker|ambiguous|700
prime-agent|/fixture/bin/prime-agent worker|ambiguous|777
CASES
  pass "tmux process-backed Prime evidence proves agents alive without declaring supervisors dead"
}

test_prime_herdr_process_info_uses_the_same_roles() {
  local comm args expected got jq_bin
  jq_bin=$(command -v jq) || fail "Prime Herdr process-info fixture requires jq"
  ln -s "$jq_bin" "$FAKEBIN/jq"
  while IFS='|' read -r comm args expected; do
    jq -n --arg name "$comm" --arg args "$args" '{
      result: {
        type: "pane_process_info",
        process_info: {
          pane_id: "fixture-pane",
          shell_pid: 740,
          foreground_processes: [{
            pid: 700, name: $name, argv0: ($args | split(" ")[0]), cmdline: $args
          }]
        }
      }
    }' > "$HOME_DIR/process-info.json"
    got=$(fm_test_prime_eval "$HOME_DIR" "$FAKEBIN" '
      . "$0/bin/fm-backend.sh"
      fm_backend_source herdr || exit 1
      fm_backend_herdr_cli() {
        [ "$*" = "fixture pane process-info --pane fixture-pane" ] || return 2
        cat "$FM_HOME/process-info.json"
      }
      fm_backend_herdr_pane_process_state_sample fixture fixture-pane
    ')
    [ "$got" = "$expected" ] \
      || fail "Prime Herdr fixture '$comm' / '$args' yielded '$got', expected '$expected'"
  done <<'CASES'
prime-agent|/fixture/bin/prime-agent worker|agent
/fixture/share/prime-agent/prime-agent|/fixture/share/prime-agent/prime-agent worker|agent
pa-daemon|/fixture/bin/pa-daemon worker|agent
prime-agent|/fixture/bin/prime-agent --mode rpc|agent
prime-agent|/fixture/bin/prime-agent --mode daemon|other
pa-daemon|/fixture/bin/pa-daemon supervisor|other
prime-agent-helper|/fixture/bin/prime-agent-helper worker|other
python3|/fixture/bin/python3 -m rlm.repl prime-agent worker|other
CASES
  printf 'malformed process-info\n' > "$HOME_DIR/process-info.json"
  got=$(fm_test_prime_eval "$HOME_DIR" "$FAKEBIN" '
    . "$0/bin/fm-backend.sh"
    fm_backend_source herdr || exit 1
    fm_backend_herdr_cli() { cat "$FM_HOME/process-info.json"; }
    fm_backend_herdr_pane_process_state_sample fixture fixture-pane
  ')
  [ "$got" = unreadable ] || fail "malformed Prime Herdr process-info yielded '$got', expected unreadable"
  pass "Herdr process-info shares Prime role classification and preserves unreadable evidence"
}

test_prime_full_process_evidence_classifies_roles
test_prime_nul_argv_controls_process_and_lock_evidence
test_prime_tmux_uses_process_roles_not_name_only
test_prime_herdr_process_info_uses_the_same_roles
