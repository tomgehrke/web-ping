#!/usr/bin/env bash
#
# web-ping.sh: website health checker
#
# Checks each target in a config file by fetching it with curl and following
# redirects the way a browser does. A target passes when the final response
# is HTTP 200, it took no more redirects than allowed, the page contains the
# expected text, and the URL it ended up on is the one expected. Failures are
# logged and can be emailed, and the exit code says whether everything passed.
#
# Usage
#
#   web-ping.sh [CONFIG] [DEFAULT_COOKIE_FILE] [ALERT_EMAIL] [LOG_FILE]
#
#       Check every target in CONFIG (default: ./targets.conf).
#       DEFAULT_COOKIE_FILE  cookie file for targets whose AUTH field is blank
#       ALERT_EMAIL          where to email failures (default: $ALERT_EMAIL)
#       LOG_FILE             where to log (default: $LOG_FILE, then
#                            ./health_check.log)
#       Exits 0 if every target passed, 1 if any failed, 2 if CONFIG is missing.
#
#   web-ping.sh --trace [CONFIG] [URL_FILTER]
#
#       Show each target's redirect chain, with and without its credentials,
#       and what the check would conclude. Use it while setting up a target.
#       URL_FILTER limits it to targets whose URL contains that text. Nothing
#       is logged or emailed.
#
# Config format
#
#   One target per line; targets.conf.example explains each field in detail.
#
#       URL | MAX_HOPS | AUTH | EXPECTED_TEXT | FINAL_URL
#
#   AUTH is '-' for no login, a cookie file (PATH or cookie:PATH), or a bearer
#   token read from an environment variable (token:NAME). The token goes only
#   to the target's own host, unless written token:NAME@example.com, which
#   also allows example.com and its subdomains.
#
#   EXPECTED_TEXT starting with '~' is matched ignoring case.
#
#   FINAL_URL is optional: space-separated terms that must all appear in the
#   URL the redirects end at. A term starting with '!' must not appear.

set -euo pipefail

# Case-insensitive matching only handles accented letters correctly in a UTF-8
# locale, but cron often runs with LC_ALL=C. Switch to C.UTF-8 when it's
# installed, so that cron runs and interactive runs give the same results.
if locale -a 2>/dev/null | grep -qiE '^c\.utf-?8$'; then
        export LC_ALL=C.UTF-8
fi

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
MAX_REDIRECTS=15
MAX_TIME=30     # seconds for a whole target, across all of its redirects

# Create the following temporary files with mktemp, which makes them readable only
# by the current user and ensures they are unique. They will be automatically removed
# when the script exits, thanks to the trap command set up to clean them up.
#
# Files created:
# - CURL_ERR_FILE:      Stores curl's error output.
# - FETCH_BODY:         Stores the response body of the fetched URL.
# - FETCH_JAR:          Stores cookies between redirects.
# - FETCH_AUTH:         Stores the Authorization header for bearer tokens.

CURL_ERR_FILE=$(mktemp)
FETCH_BODY=$(mktemp)
FETCH_JAR=$(mktemp)
FETCH_AUTH=$(mktemp)
trap 'rm -f "$CURL_ERR_FILE" "$FETCH_BODY" "$FETCH_JAR" "$FETCH_AUTH"' EXIT

trim() {
        # trim VAR
        #
        # Strip leading and trailing whitespace from the variable named VAR. The
        # variable is changed in place, so pass its name, not its value.

        local -n _ref="$1"
        _ref="${_ref#"${_ref%%[![:space:]]*}"}"
        _ref="${_ref%"${_ref##*[![:space:]]}"}"
}

# Set up colors for the [ OK ] and [FAIL] labels. Colors are only used when
# output goes to a terminal and NO_COLOR isn't set, so the log file, alert
# emails and piped output always stay plain text.
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
        # Bold white on fixed 256-color backgrounds (#008700 green, #d70000
        # red). Terminal themes don't remap these, and both meet WCAG AA
        # contrast with white.
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
        # log_msg MESSAGE
        #
        # Add a timestamp to MESSAGE, append it to LOG_FILE, and print it. Only the
        # printed copy gets a colored [ OK ] or [FAIL] label; the log gets plain text.

        local msg="$1"
        local ts

        printf -v ts '%(%Y-%m-%d %H:%M:%S)T' -1
        printf '[%s] %s\n' "$ts" "$msg" >> "$LOG_FILE"
        msg="${msg/#'[ OK ]'/[${C_OK} OK ${C_RESET}]}"
        msg="${msg/#'[FAIL]'/[${C_FAIL}FAIL${C_RESET}]}"
        printf '[%s] %s\n' "$ts" "$msg"
}

send_alert() {
        # send_alert RECIPIENT SUBJECT BODY
        #
        # Email a failure report, using mail or sendmail, whichever is installed.

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

text_matches() {
        # text_matches BODY EXPECTED
        #
        # Check whether the page body contains the expected text. Returns 0 if it
        # does, 1 if it doesn't.
        #
        # How EXPECTED is read:
        # - empty:            Always matches.
        # - ~text:            Matches "text", ignoring upper/lower case.
        # - \~text:           Matches "~text" exactly, with case.
        # - ~ on its own:     Matches a literal "~", not "anything".
        # - anything else:    Matches exactly, with case.

        local body="$1"
        local want="$2"

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

final_matches() {
        # final_matches FINAL_URL WANT
        #
        # Check the URL the redirects ended on against the target's FINAL_URL terms.
        # WANT is a list of terms separated by spaces, compared ignoring case. Each
        # term must appear somewhere in FINAL_URL, except a term starting with '!',
        # which must not. An empty WANT, or '-', always matches.
        #
        # Returns 0 if every term is satisfied. Otherwise returns 1 and sets
        # FINAL_BAD to the first term that failed.

        local final="${1,,}"
        local term
        local t
        local negate
        local present
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

final_reason() {
        # final_reason
        #
        # Print a readable description of the term in FINAL_BAD, for use in failure
        # messages after final_matches returns 1.

        if [[ "$FINAL_BAD" == '!'* ]]; then
                printf 'contains "%s"' "${FINAL_BAD#'!'}"
        else
                printf 'does not contain "%s"' "$FINAL_BAD"
        fi
}

url_host() {
        # url_host URL
        #
        # Print the host part of URL in lower case, without any port or user name.

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

token_allowed() {
        # token_allowed URL SCOPE
        #
        # Decide whether a bearer token may be sent to URL. Returns 0 only when URL
        # uses https and its host is SCOPE or a subdomain of SCOPE. SCOPE is the
        # target's own host, unless the config names a domain (token:NAME@domain).

        local host
        [[ "${1,,}" == https://* ]] || return 1
        host=$(url_host "$1")
        [[ "$host" == "$2" || "$host" == *".$2" ]]
}

fetch() {
        # fetch URL COOKIE_FILE TOKEN_VAR TOKEN_DOMAIN
        #
        # Fetch URL and follow its redirects, up to MAX_REDIRECTS. Redirects are
        # followed here one hop at a time instead of by curl, so that this script
        # decides at each hop whether the bearer token goes along. It goes only to the
        # target's host, or to TOKEN_DOMAIN and its subdomains when one is given, and
        # never anywhere else. Only http and https redirects are followed. Cookies
        # from COOKIE_FILE, and any the site sets along the way, are carried from hop
        # to hop the way a browser does.
        #
        # Arguments:
        # - URL:                The page to fetch.
        # - COOKIE_FILE:        Netscape cookie file to start with, or empty for none.
        # - TOKEN_VAR:          Name of the variable holding a bearer token, or empty.
        # - TOKEN_DOMAIN:       Domain the token may also go to, or empty.
        #
        # Sets:
        # - F_STATUS:           HTTP status of the last response.
        # - F_HOPS:             Number of redirects followed.
        # - F_FINAL:            URL of the last response.
        # - F_RC:               curl's exit code (0 means success).
        # - F_ERR:              Error message, if anything went wrong.
        # - F_CHAIN:            One "STATUS[ -> NEXT_URL]" entry per response.
        #
        # The last response's body is left in FETCH_BODY.

        local url="$1"
        local cookie="$2"
        local token_var="$3"
        local token_domain="${4:-}"
        local scope=""
        local out
        local next
        local left
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

auth_problem() {
        # auth_problem URL COOKIE_FILE TOKEN_VAR TOKEN_DOMAIN
        #
        # Check that a target's credentials can be used before fetching it. Prints
        # the reason if they can't, such as a missing cookie file, a bad or unset
        # token variable, or a token domain that doesn't contain the target's host.
        # Prints nothing if everything is fine.

        local url="$1"
        local cookie="$2"
        local token_var="$3"
        local token_domain="${4:-}"
        local host

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

auth_label() {
        # auth_label COOKIE_FILE TOKEN_VAR TOKEN_DOMAIN
        #
        # Print a short description of the credentials, for result messages.

        local label="${1:-}"
        if [[ -n "$2" ]]; then
                label="${label:+$label, }token \$$2${3:+ for *.$3}"
        fi
        printf '%s' "${label:--}"
}

parse_auth() {
        # parse_auth FIELD
        #
        # Work out what a target's AUTH field asks for. A target uses either a cookie
        # file or a bearer token, never both.
        #
        # Accepted values:
        # - blank:              DEFAULT_COOKIE_FILE if one was given, otherwise none.
        # - -:                  No login.
        # - cookie:PATH, PATH:  A cookie file.
        # - token:NAME:         A bearer token from $NAME, for the target's host only.
        # - token:NAME@DOMAIN:  The same, also allowed for DOMAIN and its subdomains.
        #
        # Sets:
        # - A_COOKIE:           Path of the cookie file.
        # - A_TOKEN:            Name of the variable holding the bearer token.
        # - A_DOMAIN:           Domain the token may also go to.
        # - A_ERR:              What's wrong with FIELD, when it can't be used.
        #
        # Returns 1 if FIELD can't be used, otherwise 0.

        local field="$1"
        local kind
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
        # check_target URL MAX_HOPS COOKIE_FILE EXPECTED_TEXT FINAL_URL TOKEN_VAR TOKEN_DOMAIN
        #
        # Fetch one target, run every check against it, and log the result. Returns
        # 0 if it passed. Otherwise returns 1 and sets LAST_ERROR to the reason.

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

trace_pass() {
        # trace_pass LABEL URL MAX_HOPS COOKIE TOKEN_VAR TOKEN_DOMAIN EXPECTED_TEXT FINAL_URL
        #
        # Fetch URL once with the given credentials, which may be empty, and print
        # every response in the redirect chain followed by what each check concludes.
        # LABEL is printed as the heading, such as "with credentials".

        local label="$1"
        local url="$2"
        local max_hops="$3"
        local cookie="$4"
        local token_var="$5"
        local token_domain="$6"
        local expected_text="$7"
        local final_want="$8"
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
        # trace_target URL MAX_HOPS COOKIE_FILE EXPECTED_TEXT FINAL_URL TOKEN_VAR TOKEN_DOMAIN
        #
        # Trace one target twice: with its credentials, then without them. Comparing
        # the two shows what an expired session would look like.

        local url="$1"
        local max_hops="$2"
        local cookie_file="$3"
        local expected_text="$4"
        local final_want="$5"
        local token_var="$6"
        local token_domain="$7"
        local problem

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
