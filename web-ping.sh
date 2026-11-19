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
# Config lines: URL | MAX_HOPS | AUTH | EXPECTED_TEXT | FINAL_URL
#   EXPECTED_TEXT starting with '~' is matched case-insensitively; start it
#   with '\~' to match a literal leading '~' with case.
#   FINAL_URL (optional): space-separated terms checked, ignoring case,
#   against the URL the redirects end at. Each term must appear in it; a term
#   starting with '!' must not.
#   AUTH: '-' for none, a cookie file (PATH or cookie:PATH), or a bearer token
#   from an environment variable (token:NAME), sent as "Authorization: Bearer"
#   over https to the target's own host only; token:NAME@example.com also
#   allows example.com and its subdomains. See targets.conf.example.
#
#   web-ping.sh --trace [CONFIG] [URL_FILTER]
#     Trace mode prints each target's redirect chain, with and without its
#     credentials, to help choose the checks. It does not log or send alerts.
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

# Temp files (mktemp makes them readable only by you): curl's error output,
# the response body, the cookie jar carried between redirects, and the
# Authorization header for bearer tokens.
CURL_ERR_FILE=$(mktemp)
FETCH_BODY=$(mktemp)
FETCH_JAR=$(mktemp)
FETCH_AUTH=$(mktemp)
trap 'rm -f "$CURL_ERR_FILE" "$FETCH_BODY" "$FETCH_JAR" "$FETCH_AUTH"' EXIT

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

# ------------------------------------------------------------------ fetch ---

MAX_REDIRECTS=15
MAX_TIME=30     # seconds for a whole target, across all of its redirects

# url_host URL: print the URL's host, lowercased, without port or user info.
url_host() {
        local h="${1#*://}"
        h="${h%%[/?#]*}"
        h="${h##*@}"
        if [[ "$h" == \[* ]]; then
                h="${h%%]*}]"           # IPv6 literal: keep the brackets
        else
                h="${h%%:*}"
        fi
        printf '%s' "${h,,}"
}

# token_allowed URL SCOPE: true if a bearer token may be sent to URL, which
# must be https and on SCOPE or one of its subdomains. SCOPE is the target's
# own host unless the config names a domain (token:NAME@domain).
token_allowed() {
        local host
        [[ "${1,,}" == https://* ]] || return 1
        host=$(url_host "$1")
        [[ "$host" == "$2" || "$host" == *".$2" ]]
}

# fetch URL COOKIE_FILE TOKEN_VAR TOKEN_DOMAIN
# Fetch URL, following redirects one hop at a time (up to MAX_REDIRECTS) so a
# bearer token goes only to the target's host, or to TOKEN_DOMAIN and its
# subdomains when one is given, and never anywhere else. Only http and https
# are followed. Cookies from COOKIE_FILE, and any the site sets along
# the way, are carried from hop to hop as a browser would.
# Sets F_STATUS, F_HOPS, F_FINAL (URL of the last response), F_RC (curl exit
# code, 0 = success), F_ERR and F_CHAIN (one "STATUS[ -> NEXT_URL]" entry per
# response). The last response's body is left in FETCH_BODY.
fetch() {
        local url="$1" cookie="$2" token_var="$3" token_domain="${4:-}" scope="" out next left
        local -a opts
        local started=$SECONDS
        F_STATUS="" F_HOPS=0 F_FINAL="$url" F_RC=0 F_ERR="" F_CHAIN=()

        : > "$FETCH_BODY"
        : > "$FETCH_JAR"
        if [[ -n "$cookie" ]]; then
                cat -- "$cookie" > "$FETCH_JAR"
        fi
        if [[ -n "$token_var" ]]; then
                # Passed to curl from a file so the token never appears in ps.
                printf 'Authorization: Bearer %s\n' "${!token_var}" > "$FETCH_AUTH"
                scope="${token_domain:-$(url_host "$url")}"
        fi

        while :; do
                left=$(( MAX_TIME - (SECONDS - started) ))
                if (( left <= 0 )); then
                        F_RC=28
                        F_ERR="timed out after ${MAX_TIME}s across ${F_HOPS} redirect(s)"
                        return 0
                fi
                opts=(
                        --silent --show-error --proto '=http,https'
                        --connect-timeout 10 --max-time "$left"
                        --cookie "$FETCH_JAR" --cookie-jar "$FETCH_JAR"
                        --output "$FETCH_BODY"
                        --write-out '%{http_code}\n%{redirect_url}\n.'
                )
                if [[ -n "$scope" ]] && token_allowed "$url" "$scope"; then
                        opts+=(--header "@$FETCH_AUTH")
                fi

                out=$(curl "${opts[@]}" "$url" 2>"$CURL_ERR_FILE") || F_RC=$?
                if (( F_RC != 0 )); then
                        F_ERR=$(<"$CURL_ERR_FILE")
                        F_ERR="${F_ERR//$'\n'/ }"
                        F_ERR="${F_ERR:-unknown error}"
                        return 0
                fi

                # out is "STATUS\nREDIRECT_URL\n." (the '.' keeps $(...) from
                # trimming an empty redirect URL away)
                out="${out%$'\n.'}"
                F_STATUS="${out%%$'\n'*}"
                next="${out#*$'\n'}"
                F_FINAL="$url"

                if [[ "$F_STATUS" == 3* && -n "$next" ]]; then
                        F_CHAIN+=("$F_STATUS -> $next")
                        if [[ "${next,,}" != http://* && "${next,,}" != https://* ]]; then
                                F_RC=1
                                F_ERR="redirect to unsupported scheme: ${next%%:*}"
                                return 0
                        fi
                        if (( F_HOPS >= MAX_REDIRECTS )); then
                                F_RC=47
                                F_ERR="more than ${MAX_REDIRECTS} redirects"
                                return 0
                        fi
                        (( ++F_HOPS ))
                        url="$next"
                        continue
                fi

                F_CHAIN+=("$F_STATUS")
                return 0
        done
}

# ----------------------------------------------------------------- checks ---

# auth_problem URL COOKIE_FILE TOKEN_VAR TOKEN_DOMAIN: print why the
# credentials can't be used (missing cookie file, bad or unset token variable,
# a token domain that doesn't contain the target); print nothing if fine.
auth_problem() {
        local url="$1" cookie="$2" token_var="$3" token_domain="${4:-}" host
        host=$(url_host "$url")
        if [[ -n "$cookie" && ! -f "$cookie" ]]; then
                printf 'Cookie file not found: %s' "$cookie"
        elif [[ -n "$token_var" && ! "$token_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
                printf 'Config error: invalid token variable name %s' "$token_var"
        elif [[ -n "$token_domain" && "$host" != "$token_domain" && "$host" != *".$token_domain" ]]; then
                printf 'Config error: token domain %s does not contain %s' "$token_domain" "$host"
        elif [[ -n "$token_var" && -z "${!token_var:-}" ]]; then
                printf 'Token variable %s is not set' "$token_var"
        fi
}

# auth_label COOKIE_FILE TOKEN_VAR TOKEN_DOMAIN: describe the credentials.
auth_label() {
        local label="${1:-}"
        if [[ -n "$2" ]]; then
                label="${label:+$label, }token \$$2${3:+ for *.$3}"
        fi
        printf '%s' "${label:--}"
}

# parse_auth FIELD: interpret a target's AUTH field. Sets A_COOKIE (cookie
# file), A_TOKEN (name of the variable holding a bearer token) and A_DOMAIN
# (domain the token may also go to), at most one kind being set; on a bad
# value sets A_ERR and returns 1.
#   blank                   DEFAULT_COOKIE_FILE if one was given, else none
#   -                       none
#   cookie:PATH  or  PATH   cookie file
#   token:NAME[@DOMAIN]     bearer token from $NAME
parse_auth() {
        local field="$1" kind
        A_COOKIE="" A_TOKEN="" A_DOMAIN="" A_ERR=""

        if [[ -z "$field" ]]; then
                A_COOKIE="$DEFAULT_COOKIE_FILE"
                [[ "$A_COOKIE" == "-" ]] && A_COOKIE=""
                return 0
        fi
        [[ "$field" == "-" ]] && return 0
        if [[ "$field" == *[[:space:]]* ]]; then
                A_ERR="AUTH takes one value (cookie:PATH or token:NAME), got: $field"
                return 1
        fi

        kind=""
        if [[ "$field" =~ ^([A-Za-z]+):(.*)$ ]]; then
                kind="${BASH_REMATCH[1],,}"
                field="${BASH_REMATCH[2]}"
        fi
        case "$kind" in
                ""|cookie)
                        A_COOKIE="$field"
                        [[ -n "$A_COOKIE" ]] && return 0
                        A_ERR="cookie: needs a file path"
                        ;;
                token)
                        field="${field#\$}"            # accept $NAME as well as NAME
                        A_TOKEN="${field%%@*}"
                        if [[ "$field" == *@* ]]; then
                                A_DOMAIN="${field#*@}"
                                A_DOMAIN="${A_DOMAIN,,}"
                                A_DOMAIN="${A_DOMAIN#.}"
                                if [[ -z "$A_DOMAIN" ]]; then
                                        A_ERR="token: domain after '@' is empty"
                                        return 1
                                fi
                        fi
                        if [[ ! "$A_TOKEN" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
                                A_ERR="invalid token variable name '$A_TOKEN'"
                                return 1
                        fi
                        return 0
                        ;;
                *)
                        # Before AUTH types existed this field was always a
                        # cookie path, so an existing file of that exact name wins.
                        if [[ -f "$1" ]]; then
                                A_COOKIE="$1"
                                return 0
                        fi
                        A_ERR="unknown AUTH type '$kind:' (use cookie: or token:)"
                        ;;
        esac
        return 1
}

check_target() {
        local url="$1"
        local max_hops="$2"
        local cookie_file="$3"
        local expected_text="$4"
        local final_want="$5"
        local token_var="$6"
        local token_domain="$7"
        local problem

        problem=$(auth_problem "$url" "$cookie_file" "$token_var" "$token_domain")
        if [[ -n "$problem" ]]; then
                printf -v LAST_ERROR '[FAIL] %s -> %s' "$url" "$problem"
                log_msg "$LAST_ERROR"
                return 1
        fi

        fetch "$url" "$cookie_file" "$token_var" "$token_domain"

        if (( F_RC != 0 )); then
                printf -v LAST_ERROR '[FAIL] %s -> curl exit %s after %s hop(s), last HTTP %s: %s' \
                        "$url" "$F_RC" "$F_HOPS" "${F_STATUS:-?}" "$F_ERR"
                log_msg "$LAST_ERROR"
                return 1
        fi

        if ! final_matches "$F_FINAL" "$final_want"; then
                printf -v LAST_ERROR '[FAIL] %s -> Ended at %s (%s hops), which %s' \
                        "$url" "$F_FINAL" "$F_HOPS" "$(final_reason)"
                log_msg "$LAST_ERROR"
                return 1
        fi

        if [[ "$F_STATUS" != 200 ]]; then
                printf -v LAST_ERROR '[FAIL] %s -> Expected HTTP 200, got %s (%s hops)' "$url" "$F_STATUS" "$F_HOPS"
                log_msg "$LAST_ERROR"
                return 1
        fi

        if ! text_matches "$(<"$FETCH_BODY")" "$expected_text"; then
                printf -v LAST_ERROR '[FAIL] %s -> HTTP 200 (%s hops), but missing text: %q' "$url" "$F_HOPS" "$expected_text"
                log_msg "$LAST_ERROR"
                return 1
        fi

        if (( F_HOPS > max_hops )); then
                printf -v LAST_ERROR '[FAIL] %s -> Exceeded max hops: got %s, expected <= %s' "$url" "$F_HOPS" "$max_hops"
                log_msg "$LAST_ERROR"
                return 1
        fi

        local ok_msg
        printf -v ok_msg '[ OK ] %s (%s/%s hops) [auth: %s]' "$url" "$F_HOPS" "$max_hops" \
                "$(auth_label "$cookie_file" "$token_var" "$token_domain")"
        log_msg "$ok_msg"
        return 0
}

# trace_pass LABEL URL MAX_HOPS COOKIE TOKEN_VAR TOKEN_DOMAIN EXPECTED_TEXT FINAL_URL
# Fetch URL once with the given credentials (either may be empty), print every
# response in the chain, then what the health check would conclude.
trace_pass() {
        local label="$1" url="$2" max_hops="$3" cookie="$4" token_var="$5"
        local token_domain="$6" expected_text="$7" final_want="$8"
        local i
        local -a reasons=()

        fetch "$url" "$cookie" "$token_var" "$token_domain"

        printf '  %s:\n' "$label"
        for i in "${!F_CHAIN[@]}"; do
                printf '    %d. %s\n' "$(( i + 1 ))" "${F_CHAIN[i]}"
        done

        if (( F_RC != 0 )); then
                printf '    curl exit %s: %s\n' "$F_RC" "$F_ERR"
                printf '    => check would %s FAIL %s (connection or curl error)\n' "$C_FAIL" "$C_RESET"
                return 0
        fi

        printf '    final: HTTP %s after %s hop(s) at %s\n' "$F_STATUS" "$F_HOPS" "$F_FINAL"
        if [[ -n "$final_want" && "$final_want" != "-" ]]; then
                if final_matches "$F_FINAL" "$final_want"; then
                        printf '    final URL matches "%s": yes\n' "$final_want"
                else
                        printf '    final URL matches "%s": NO, it %s\n' "$final_want" "$(final_reason)"
                        reasons+=("ended at the wrong URL")
                fi
        fi
        [[ "$F_STATUS" != 200 ]] && reasons+=("HTTP $F_STATUS, not 200")
        if [[ -n "$expected_text" ]]; then
                if text_matches "$(<"$FETCH_BODY")" "$expected_text"; then
                        printf '    text "%s": found\n' "$expected_text"
                else
                        printf '    text "%s": NOT found\n' "$expected_text"
                        reasons+=("expected text missing")
                fi
        fi
        if [[ "$max_hops" =~ ^[0-9]+$ ]] && (( F_HOPS > 10#$max_hops )); then
                reasons+=("$F_HOPS hops > max $max_hops")
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
        local token_var="$6" token_domain="$7" problem
        printf '\n== %s  (max hops: %s, auth: %s, text: "%s", final URL: "%s")\n' \
                "$url" "${max_hops:-?}" "$(auth_label "$cookie_file" "$token_var" "$token_domain")" \
                "$expected_text" "${final_want:--}"

        if [[ -z "$cookie_file" && -z "$token_var" ]]; then
                trace_pass "no credentials" "$url" "$max_hops" "" "" "" "$expected_text" "$final_want"
                return 0
        fi

        problem=$(auth_problem "$url" "$cookie_file" "$token_var" "$token_domain")
        if [[ -n "$problem" ]]; then
                printf '  with credentials: %s\n' "$problem"
        else
                trace_pass "with credentials" "$url" "$max_hops" "$cookie_file" "$token_var" \
                        "$token_domain" "$expected_text" "$final_want"
        fi
        trace_pass "without credentials (what an expired session looks like)" \
                "$url" "$max_hops" "" "" "" "$expected_text" "$final_want"
}

if (( TRACE )); then
        printf 'Tracing targets in %s%s\n' "$CONFIG_FILE" "${TRACE_FILTER:+ matching '$TRACE_FILTER'}"
else
        log_msg "=== Starting health check run (config: $CONFIG_FILE) ==="
fi

while IFS='|' read -r url max_hops auth expected_text final_want extra <&3 || [[ -n "${url:-}" ]]; do
        url="${url:-}"
        max_hops="${max_hops:-}"
        auth="${auth:-}"
        expected_text="${expected_text:-}"
        final_want="${final_want:-}"

        trim url
        trim max_hops
        trim auth
        trim expected_text
        trim final_want

        [[ -z "$url" || "$url" == \#* ]] && continue
        if (( TRACE )) && [[ -n "$TRACE_FILTER" && "$url" != *"$TRACE_FILTER"* ]]; then
                continue
        fi
        (( ++TOTAL ))

        # More than 5 fields means a '|' inside a value; refuse rather than guess
        # which field it belongs to.
        problem=""
        if [[ -n "${extra:-}" ]]; then
                problem='too many "|" fields (values cannot contain "|")'
        elif ! parse_auth "$auth"; then
                problem="$A_ERR"
        fi
        if [[ -n "$problem" ]]; then
                if (( TRACE )); then
                        printf '\n== %s\n  config error: %s\n' "$url" "$problem"
                        continue
                fi
                (( ++FAILURES ))
                printf -v LAST_ERROR '[FAIL] %s -> Config error: %s' "$url" "$problem"
                log_msg "$LAST_ERROR"
                FAILURE_DETAILS+="${LAST_ERROR}"$'\n'
                continue
        fi

        if (( TRACE )); then
                trace_target "$url" "$max_hops" "$A_COOKIE" "$expected_text" "$final_want" \
                        "$A_TOKEN" "$A_DOMAIN"
                continue
        fi

        LAST_ERROR=""
        if ! check_target "$url" "$max_hops" "$A_COOKIE" "$expected_text" "$final_want" \
                "$A_TOKEN" "$A_DOMAIN"; then
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
