#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   web-ping.sh [CONFIG] [DEFAULT_COOKIE_FILE] [ALERT_EMAIL] [LOG_FILE]
#   web-ping.sh --trace [CONFIG] [URL_FILTER]
#     Trace mode prints each target's redirect chain, with and without its
#     cookie, to help choose MAX_HOPS. It does not log or send alerts.
#     URL_FILTER limits it to targets whose URL contains that text.

TRACE=0
TRACE_FILTER=""
if [[ "${1:-}" == "--trace" ]]; then
  TRACE=1
  shift
  TRACE_FILTER="${2:-}"
  set -- "${1:-}"
fi

CONFIG_FILE="${1:-./targets.conf}"
DEFAULT_COOKIE_FILE="${2:-}"
ALERT_EMAIL="${3:-${ALERT_EMAIL:-}}"
LOG_FILE="${4:-${LOG_FILE:-./health_check.log}}"

if [[ ! -f "$CONFIG_FILE" ]]; then
  printf 'Error: Config file %q not found.\n' "$CONFIG_FILE" >&2
  exit 2
fi

FAILURES=0
TOTAL=0
FAILURE_DETAILS=""

CURL_ERR_FILE=$(mktemp)
TRACE_HDR_FILE=$(mktemp)
TRACE_BODY_FILE=$(mktemp)
trap 'rm -f "$CURL_ERR_FILE" "$TRACE_HDR_FILE" "$TRACE_BODY_FILE"' EXIT

# Pure Bash whitespace trimmer using nameref (in-place, zero subshells)
trim() {
  local -n _ref="$1"
  _ref="${_ref#"${_ref%%[![:space:]]*}"}"
  _ref="${_ref%"${_ref##*[![:space:]]}"}"
}

# Log to both stdout and LOG_FILE using native Bash strftime formatting
# Color the OK/FAIL labels only on a terminal (and not when NO_COLOR is set),
# so the log file, alert emails and piped output stay plain text.
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  # Bold white text on fixed 256-color backgrounds (#008700 green, #d70000 red),
  # which terminal themes don't remap; both give WCAG AA contrast with white.
  if (( $(tput colors 2>/dev/null || echo 8) >= 256 )); then
    C_OK=$'\e[1;38;5;231;48;5;28m' C_FAIL=$'\e[1;38;5;231;48;5;160m'
  else
    C_OK=$'\e[1;97;42m' C_FAIL=$'\e[1;97;41m'
  fi
  C_RESET=$'\e[0m'
else
  C_OK="" C_FAIL="" C_RESET=""
fi

log_msg() {
  local msg="$1"
  local ts
  printf -v ts '%(%Y-%m-%d %H:%M:%S)T' -1
  printf '[%s] %s\n' "$ts" "$msg" >> "$LOG_FILE"
  msg="${msg/#'[ OK ]'/[${C_OK} OK ${C_RESET}]}"
  msg="${msg/#'[FAIL]'/[${C_FAIL}FAIL${C_RESET}]}"
  printf '[%s] %s\n' "$ts" "$msg"
}

send_alert() {
  local recipient="$1"
  local subject="$2"
  local body="$3"

  if command -v mail >/dev/null 2>&1; then
    printf '%s\n' "$body" | mail -s "$subject" "$recipient"
  elif command -v sendmail >/dev/null 2>&1; then
    {
      printf 'To: %s\n' "$recipient"
      printf 'Subject: %s\n' "$subject"
      printf 'Content-Type: text/plain; charset=UTF-8\n\n'
      printf '%s\n' "$body"
    } | sendmail -t
  else
    log_msg "WARN: ALERT_EMAIL set to '$recipient', but neither 'mail' nor 'sendmail' is installed."
    return 1
  fi
}

check_target() {
  local url="$1"
  local max_hops="$2"
  local cookie_file="$3"
  local expected_text="$4"

  local -a curl_opts=(
    --silent
    --show-error
    --location
    --max-redirs 15
    --connect-timeout 10
    --max-time 30
    --write-out $'\n%{http_code} %{num_redirects}'
  )

  if [[ -n "$cookie_file" && "$cookie_file" != "-" ]]; then
    if [[ ! -f "$cookie_file" ]]; then
      printf -v LAST_ERROR '[FAIL] %s -> Cookie file not found: %s' "$url" "$cookie_file"
      log_msg "$LAST_ERROR"
      return 1
    fi
    curl_opts+=(--cookie "$cookie_file")
  fi

  local response meta body status hops curl_rc=0 curl_err

  response=$(curl "${curl_opts[@]}" "$url" 2>"$CURL_ERR_FILE") || curl_rc=$?
  if (( curl_rc != 0 )); then
    curl_err=$(<"$CURL_ERR_FILE")
    curl_err="${curl_err//$'\n'/ }"
    meta="${response##*$'\n'}"
    read -r status hops <<< "$meta"
    printf -v LAST_ERROR '[FAIL] %s -> curl exit %s after %s hop(s), last HTTP %s: %s' \
      "$url" "$curl_rc" "${hops:-?}" "${status:-?}" "${curl_err:-unknown error}"
    log_msg "$LAST_ERROR"
    return 1
  fi

  meta="${response##*$'\n'}"
  body="${response%$'\n'*}"

  read -r status hops <<< "$meta"

  if (( status != 200 )); then
    printf -v LAST_ERROR '[FAIL] %s -> Expected HTTP 200, got %s (%s hops)' "$url" "$status" "$hops"
    log_msg "$LAST_ERROR"
    return 1
  fi

  if [[ "$body" != *"$expected_text"* ]]; then
    printf -v LAST_ERROR '[FAIL] %s -> HTTP 200 (%s hops), but missing text: %q' "$url" "$hops" "$expected_text"
    log_msg "$LAST_ERROR"
    return 1
  fi

  if (( hops > max_hops )); then
    printf -v LAST_ERROR '[FAIL] %s -> Exceeded max hops: got %s, expected <= %s' "$url" "$hops" "$max_hops"
    log_msg "$LAST_ERROR"
    return 1
  fi

  local ok_msg
  printf -v ok_msg '[ OK ] %s (%s/%s hops)%s' "$url" "$hops" "$max_hops" "${cookie_file:+ [auth: $cookie_file]}"
  log_msg "$ok_msg"
  return 0
}

# trace_pass LABEL URL MAX_HOPS COOKIE EXPECTED_TEXT
# Follow URL once (with COOKIE, or none when COOKIE is empty) and print every
# response in the chain, then what the health check would conclude.
trace_pass() {
  local label="$1" url="$2" max_hops="$3" cookie="$4" expected_text="$5"
  local -a opts=(
    --silent --show-error --location --max-redirs 15
    --connect-timeout 10 --max-time 30
    --dump-header "$TRACE_HDR_FILE" --output "$TRACE_BODY_FILE"
    --write-out '%{http_code} %{num_redirects} %{url_effective}'
  )
  [[ -n "$cookie" ]] && opts+=(--cookie "$cookie")

  local meta rc=0 status hops final line step=0
  local -a reasons=()
  : > "$TRACE_HDR_FILE"
  : > "$TRACE_BODY_FILE"
  meta=$(curl "${opts[@]}" "$url" 2>"$CURL_ERR_FILE") || rc=$?
  read -r status hops final <<< "$meta"

  printf '  %s:\n' "$label"
  while IFS= read -r line; do
    line="${line%$'\r'}"
    if [[ "$line" =~ ^HTTP/[^[:space:]]+[[:space:]]+([0-9]{3}) ]]; then
      # 1xx interim responses are not hops
      [[ "${BASH_REMATCH[1]}" == 1* ]] && continue
      (( ++step ))
      printf '    %d. %s' "$step" "${BASH_REMATCH[1]}"
      [[ "${BASH_REMATCH[1]}" != 3* ]] && printf '\n'
    elif [[ "${line,,}" == location:* ]]; then
      printf ' -> %s\n' "${line#*:[[:space:]]}"
    fi
  done < "$TRACE_HDR_FILE"

  if (( rc != 0 )); then
    printf '    curl exit %s: %s\n' "$rc" "$(tr '\n' ' ' < "$CURL_ERR_FILE")"
    printf '    => check would %s FAIL %s (connection or curl error)\n' "$C_FAIL" "$C_RESET"
    return 0
  fi

  printf '    final: HTTP %s after %s hop(s) at %s\n' "$status" "$hops" "$final"
  [[ "$status" != 200 ]] && reasons+=("HTTP $status, not 200")
  if [[ -n "$expected_text" ]]; then
    if grep -qF -- "$expected_text" "$TRACE_BODY_FILE"; then
      printf '    text "%s": found\n' "$expected_text"
    else
      printf '    text "%s": NOT found\n' "$expected_text"
      reasons+=("expected text missing")
    fi
  fi
  if [[ "$max_hops" =~ ^[0-9]+$ ]] && (( hops > 10#$max_hops )); then
    reasons+=("$hops hops > max $max_hops")
  fi
  if (( ${#reasons[@]} == 0 )); then
    printf '    => check would %s PASS %s\n' "$C_OK" "$C_RESET"
  else
    local joined
    printf -v joined '%s; ' "${reasons[@]}"
    printf '    => check would %s FAIL %s: %s\n' "$C_FAIL" "$C_RESET" "${joined%; }"
  fi
}

trace_target() {
  local url="$1" max_hops="$2" cookie_file="$3" expected_text="$4"
  printf '\n== %s  (max hops: %s, cookie: %s, text: "%s")\n' \
    "$url" "${max_hops:-?}" "${cookie_file:--}" "$expected_text"

  if [[ -n "$cookie_file" && "$cookie_file" != "-" ]]; then
    if [[ -f "$cookie_file" ]]; then
      trace_pass "with cookie" "$url" "$max_hops" "$cookie_file" "$expected_text"
    else
      printf '  with cookie: cookie file not found: %s\n' "$cookie_file"
    fi
    trace_pass "without cookie (what an expired cookie looks like)" \
      "$url" "$max_hops" "" "$expected_text"
  else
    trace_pass "no cookie" "$url" "$max_hops" "" "$expected_text"
  fi
}

if (( TRACE )); then
  printf 'Tracing targets in %s%s\n' "$CONFIG_FILE" "${TRACE_FILTER:+ matching '$TRACE_FILTER'}"
else
  log_msg "=== Starting health check run (config: $CONFIG_FILE) ==="
fi

while IFS='|' read -r url max_hops cookie_file expected_text <&3 || [[ -n "${url:-}" ]]; do
  url="${url:-}"
  max_hops="${max_hops:-}"
  cookie_file="${cookie_file:-}"
  expected_text="${expected_text:-}"

  trim url
  trim max_hops
  trim cookie_file
  trim expected_text

  [[ -z "$url" || "$url" == \#* ]] && continue

  if [[ -z "$cookie_file" && -n "$DEFAULT_COOKIE_FILE" ]]; then
    cookie_file="$DEFAULT_COOKIE_FILE"
  fi

  if (( TRACE )); then
    [[ -n "$TRACE_FILTER" && "$url" != *"$TRACE_FILTER"* ]] && continue
    (( ++TOTAL ))
    trace_target "$url" "$max_hops" "$cookie_file" "$expected_text"
    continue
  fi

  (( ++TOTAL ))
  LAST_ERROR=""
  if ! check_target "$url" "$max_hops" "$cookie_file" "$expected_text"; then
    (( ++FAILURES ))
    FAILURE_DETAILS+="${LAST_ERROR}"$'\n'
  fi
done 3< "$CONFIG_FILE"

if (( TRACE )); then
  (( TOTAL > 0 )) || printf 'No matching targets.\n'
  exit 0
fi

SUMMARY="Checked $TOTAL target(s): $((TOTAL - FAILURES)) passed, $FAILURES failed."
log_msg "$SUMMARY"

if (( FAILURES > 0 )) && [[ -n "$ALERT_EMAIL" ]]; then
  printf -v RUN_TS '%(%Y-%m-%d %H:%M:%S)T' -1
  EMAIL_BODY="Health check failures detected at $RUN_TS on ${HOSTNAME:-localhost}:

${FAILURE_DETAILS}
Summary: $SUMMARY
Full log: $LOG_FILE"

  if send_alert "$ALERT_EMAIL" "[ALERT] Website Health Check Failed ($FAILURES/$TOTAL)" "$EMAIL_BODY"; then
    log_msg "Alert email sent to $ALERT_EMAIL."
  fi
fi

(( FAILURES == 0 ))