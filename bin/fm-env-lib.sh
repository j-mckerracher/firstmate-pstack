# shellcheck shell=bash
# Shared .env-style file accessor.
# Usage: . bin/fm-env-lib.sh
#
# This file is the single owner of the one-key .env read: the Relay pairing
# token (bin/fm-x-lib.sh and its callers) and the optional typesafe.ai
# dispatch key (bin/fm-dispatch-resolve.sh) both resolve their value through
# fmx_env_get, so those opt-in secrets in $FM_HOME/.env are parsed by one rule.
# (bin/fm-mail.sh loads its whole .env block itself under the same env-wins
# contract.) The value is printed to the caller's command substitution only;
# nothing is logged.

# fmx_env_get <key> <file>
# Read the value of KEY from a .env-style file: last assignment wins; tolerates a
# leading "export ", surrounding whitespace, and one layer of matching single or
# double quotes. Prints nothing (and succeeds) when the file or key is absent, so
# callers can treat empty output as "unset".
fmx_env_get() {
  local key=$1 file=$2 line val
  [ -f "$file" ] || return 0
  line=$(grep -E "^[[:space:]]*(export[[:space:]]+)?${key}=" "$file" 2>/dev/null | tail -n1) || return 0
  [ -n "$line" ] || return 0
  val=${line#*=}
  val=${val#"${val%%[![:space:]]*}"}   # strip leading whitespace
  val=${val%"${val##*[![:space:]]}"}   # strip trailing whitespace (incl. CR)
  case "$val" in
    \"*\") val=${val#\"}; val=${val%\"} ;;
    \'*\') val=${val#\'}; val=${val%\'} ;;
  esac
  printf '%s' "$val"
}

# fm_typesafe_local_base <url>
# True when <url> is an http(s) endpoint on this machine: localhost, 127.0.0.1,
# or [::1], with any port or path. The typed dispatch resolver and bootstrap
# treat such a TYPESAFE_BASE_URL as opt-in without an API key, so a local
# System One-compatible server such as tev1 under Ollama serves dispatch
# resolution without brief text leaving the machine. Any other host, a
# userinfo part, or an empty value is not local.
fm_typesafe_local_base() {
  local url=$1 host
  case "$url" in http://*|https://*) ;; *) return 1 ;; esac
  host=${url#*://}
  host=${host%%/*}
  case "$host" in
    \[*\]*) host=${host%%]*}] ;;
    *) host=${host%%:*} ;;
  esac
  case "$host" in
    localhost|127.0.0.1|'[::1]') return 0 ;;
  esac
  return 1
}
