#!/usr/bin/env bash
set -euo pipefail

# Case-insensitive matching ('~' text, FINAL_URL) folds non-ASCII letters only
# in a UTF-8 locale; cron often runs with LC_ALL=C. Use C.UTF-8 if installed
# so cron and interactive runs agree.
if locale -a 2>/dev/null | grep -qiE '^c\.utf-?8$'; then
        export LC_ALL=C.UTF-8
fi

# Usage:
#   web-ping.sh [CONFIG] [DEFAULT_COOKIE_FILE] [ALERT_EMAIL] [LOG_FILE]
#
# Config lines: URL | MAX_HOPS | COOKIE_PATH | EXPECTED_TEXT | FINAL_URL
#   EXPECTED_TEXT starting with '~' is matched case-insensitively; start it
#   with '\~' to match a literal leading '~' with case.
#   FINAL_URL (optional): space-separated terms checked, ignoring case,
#   against the URL the redirects end at. Each term must appear in it; a term
#   starting with '!' must not. See targets.conf.example.
#
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

# text_matches BODY EXPECTED: empty EXPECTED always matches. A leading '~'
# makes the match case-insensitive; a leading '\~' stands for a literal '~'
# (matched with case). A lone '~' is matched literally, not as "anything".
text_matches() {
        local body="$1" want="$2"
        [[ -z "$want" ]] && return 0
        if [[ "$want" == '\~'* ]]; then
                want="${want#'\'}"
        elif [[ "$want" == '~'?* ]]; then
                want="${want#'~'}"
                [[ "${body,,}" == *"${want,,}"* ]]
                return
        fi
        [[ "$body" == *"$want"* ]]
}

# final_matches FINAL_URL WANT: WANT is space-separated terms, each of which
# must appear in FINAL_URL (ignoring case); a term starting with '!' must not.
# Empty or '-' WANT always matches. Sets FINAL_BAD to the first failing term.
final_matches() {
        local final="${1,,}" term t negate present
        local -a terms
        FINAL_BAD=""
        [[ -z "$2" || "$2" == "-" ]] && return 0
        read -r -a terms <<< "$2"
        for term in "${terms[@]}"; do
                t="${term,,}" negate=0 present=0
                if [[ "$t" == '!'* ]]; then
                        negate=1
                        t="${t#'!'}"
                fi
                [[ -z "$t" ]] && continue
                [[ "$final" == *"$t"* ]] && present=1
                if (( present == negate )); then   # missing a required term, or has a banned one
                        FINAL_BAD="$term"
                        return 1
                fi
        done
        return 0
}

# describe a failing final-URL term for messages
final_reason() {
        if [[ "$FINAL_BAD" == '!'* ]]; then
                printf 'contains "%s"' "${FINAL_BAD#'!'}"
        else
                printf 'does not contain "%s"' "$FINAL_BAD"
        fi
}

check_target() {
        local url="$1"
        local max_hops="$2"
        local cookie_file="$3"
        local expected_text="$4"
        local final_want="$5"

        local -a curl_opts=(
                --silent
                --show-error
                --location
                --max-redirs 15
                --connect-timeout 10
                --max-time 30
                --write-out $'\n%{http_code} %{num_redirects} %{url_effective}'
        )

        if [[ -n "$cookie_file" && "$cookie_file" != "-" ]]; then
                if [[ ! -f "$cookie_file" ]]; then
                        printf -v LAST_ERROR '[FAIL] %s -> Cookie file not found: %s' "$url" "$cookie_file"
                        log_msg "$LAST_ERROR"
                        return 1
                fi
                curl_opts+=(--cookie "$cookie_file")
        fi

        local response meta body status hops final curl_rc=0 curl_err

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

        read -r status hops final <<< "$meta"

        if ! final_matches "$final" "$final_want"; then
                printf -v LAST_ERROR '[FAIL] %s -> Ended at %s (%s hops), which %s' \
                        "$url" "$final" "$hops" "$(final_reason)"
                log_msg "$LAST_ERROR"
                return 1
        fi

        if (( status != 200 )); then
                printf -v LAST_ERROR '[FAIL] %s -> Expected HTTP 200, got %s (%s hops)' "$url" "$status" "$hops"
                log_msg "$LAST_ERROR"
                return 1
        fi

        if ! text_matches "$body" "$expected_text"; then
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

# trace_pass LABEL URL MAX_HOPS COOKIE EXPECTED_TEXT FINAL_URL
# Follow URL once (with COOKIE, or none when COOKIE is empty) and print every
# response in the chain, then what the health check would conclude.
trace_pass() {
        local label="$1" url="$2" max_hops="$3" cookie="$4" expected_text="$5" final_want="$6"
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
        if [[ -n "$final_want" && "$final_want" != "-" ]]; then
                if final_matches "$final" "$final_want"; then
                        printf '    final URL matches "%s": yes\n' "$final_want"
                else
                        printf '    final URL matches "%s": NO, it %s\n' "$final_want" "$(final_reason)"
                        reasons+=("ended at the wrong URL")
                fi
        fi
        [[ "$status" != 200 ]] && reasons+=("HTTP $status, not 200")
        if [[ -n "$expected_text" ]]; then
                if text_matches "$(<"$TRACE_BODY_FILE")" "$expected_text"; then
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
        local url="$1" max_hops="$2" cookie_file="$3" expected_text="$4" final_want="$5"
        printf '\n== %s  (max hops: %s, cookie: %s, text: "%s", final URL: "%s")\n' \
                "$url" "${max_hops:-?}" "${cookie_file:--}" "$expected_text" "${final_want:--}"

        if [[ -n "$cookie_file" && "$cookie_file" != "-" ]]; then
                if [[ -f "$cookie_file" ]]; then
                        trace_pass "with cookie" "$url" "$max_hops" "$cookie_file" "$expected_text" "$final_want"
                else
                        printf '  with cookie: cookie file not found: %s\n' "$cookie_file"
                fi
                trace_pass "without cookie (what an expired cookie looks like)" \
                        "$url" "$max_hops" "" "$expected_text" "$final_want"
        else
                trace_pass "no cookie" "$url" "$max_hops" "" "$expected_text" "$final_want"
        fi
}

if (( TRACE )); then
        printf 'Tracing targets in %s%s\n' "$CONFIG_FILE" "${TRACE_FILTER:+ matching '$TRACE_FILTER'}"
else
        log_msg "=== Starting health check run (config: $CONFIG_FILE) ==="
fi

while IFS='|' read -r url max_hops cookie_file expected_text final_want extra <&3 || [[ -n "${url:-}" ]]; do
        url="${url:-}"
        max_hops="${max_hops:-}"
        cookie_file="${cookie_file:-}"
        expected_text="${expected_text:-}"
        final_want="${final_want:-}"

        trim url
        trim max_hops
        trim cookie_file
        trim expected_text
        trim final_want

        [[ -z "$url" || "$url" == \#* ]] && continue

        # More than 5 fields means a '|' inside a value; refuse rather than guess
        # which field it belongs to.
        if [[ -n "${extra:-}" ]]; then
                (( ++TOTAL ))
                if (( TRACE )); then
                        printf '\n== %s\n  config error: too many "|" fields (values cannot contain "|")\n' "$url"
                        continue
                fi
                (( ++FAILURES ))
                printf -v LAST_ERROR '[FAIL] %s -> Config error: too many "|" fields (values cannot contain "|")' "$url"
                log_msg "$LAST_ERROR"
                FAILURE_DETAILS+="${LAST_ERROR}"$'\n'
                continue
        fi

        if [[ -z "$cookie_file" && -n "$DEFAULT_COOKIE_FILE" ]]; then
                cookie_file="$DEFAULT_COOKIE_FILE"
        fi

        if (( TRACE )); then
                [[ -n "$TRACE_FILTER" && "$url" != *"$TRACE_FILTER"* ]] && continue
                (( ++TOTAL ))
                trace_target "$url" "$max_hops" "$cookie_file" "$expected_text" "$final_want"
                continue
        fi

        (( ++TOTAL ))
        LAST_ERROR=""
        if ! check_target "$url" "$max_hops" "$cookie_file" "$expected_text" "$final_want"; then
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
