#!/usr/bin/env bash
# Deterministic Prime process evidence shared by identity and ownership tests.

fm_test_prime_ps() {  # <fakebin>
  cat > "$1/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
[ -z "${FM_TEST_PRIME_TRACE:-}" ] || printf '%s\t%s\n' "$pid" "$field" >> "$FM_TEST_PRIME_TRACE"
case "$pid:$field" in
  700:comm=) printf '%s\n' "${FM_TEST_PRIME_COMM:-prime-agent}" ;;
  700:args=) printf '%s\n' "${FM_TEST_PRIME_ARGS-/fixture/bin/prime-agent worker}" ;;
  700:ppid=) printf '%s\n' 800 ;;
  800:comm=) printf '%s\n' prime-agent ;;
  800:args=) printf '%s\n' '/fixture/bin/prime-agent --mode daemon --daemon-socket /fixture/supervisor.sock' ;;
  800:ppid=) printf '%s\n' 1 ;;
  750:comm=) printf '%s\n' python3 ;;
  750:args=) printf '%s\n' '/fixture/bin/python3 -m rlm.repl' ;;
  750:ppid=)
    case "${FM_TEST_PRIME_CHAIN:-normal}" in
      missing) printf '%s\n' 777 ;;
      malformed) printf '%s\n' bad-pid ;;
      ambiguous) printf '%s\n' '700 800' ;;
      cycle) printf '%s\n' 740 ;;
      *) printf '%s\n' 700 ;;
    esac ;;
  740:comm=) printf '%s\n' bash ;;
  740:args=) printf '%s\n' '/bin/bash -c fixture-tool' ;;
  740:ppid=)
    case "${FM_TEST_PRIME_CHAIN:-normal}" in
      detached) printf '%s\n' 1 ;;
      *) printf '%s\n' 750 ;;
    esac ;;
  777:*) exit 1 ;;
  900:comm=) printf '%s\n' "${FM_TEST_PRIME_OWNER_COMM:-prime-agent}" ;;
  900:args=) printf '%s\n' "${FM_TEST_PRIME_OWNER_ARGS:-/fixture/bin/prime-agent worker}" ;;
  900:ppid=) printf '%s\n' 1 ;;
  1:comm=) printf '%s\n' launchd ;;
  1:args=) printf '%s\n' /sbin/launchd ;;
  1:ppid=) printf '%s\n' 0 ;;
  *:lstart=) printf '%s\n' 'Mon Oct  5 04:00:00 2026' ;;
  *:command=) printf '%s\n' 'Mon Oct  5 04:00:00 2026 /bin/bash /fixture/firstmate-tool.sh' ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' '/bin/bash /fixture/firstmate-tool.sh' ;;
  *:ppid=) printf '%s\n' 740 ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$1/ps"
}

fm_test_prime_eval() {  # <home> <fakebin> <expression> [VAR=VAL ...]
  local home=$1 fakebin=$2 expression=$3
  shift 3
  mkdir -p "$home/state" "$home/config" "$home/proc" "$home/tmp"
  env -i PATH="$fakebin:${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}" \
    HOME="$home" TMPDIR="$home/tmp" LC_ALL=C \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_CONFIG_OVERRIDE="$home/config" FM_PROC_ROOT_OVERRIDE="$home/proc" \
    FM_GATE_REFUSE_BYPASS=1 FM_TEST_SEAM=1 "$@" \
    bash -c '
      kill() {
        [ "${1:-}" = -0 ] || return 2
        case "${2:-}" in ""|*[!0-9]*) return 1 ;; esac
        [ "${2:-}" != "${FM_TEST_PRIME_DEAD_PID:-900000}" ]
      }
      export -f kill
    '"$expression" "$ROOT"
}
