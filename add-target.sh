#!/usr/bin/env bash
#
# add-target.sh: interactive helper for web-ping.sh
#
# Adds a target to the config file, or updates one that's already there. It
# asks for each check and how the site logs in, then sets that up: for
# cookies it builds a Netscape-format cookie file from the Cookie header you
# copy out of your browser, and for a bearer token it records the name of the
# environment variable that will hold it. Before saving, it tests the target
# with web-ping.sh and lets you fix anything that fails.
#
# Usage
#
#   add-target.sh [CONFIG]
#
#       CONFIG defaults to ./targets.conf and is created if it doesn't exist.
#
#   Run it from the directory you run web-ping.sh from, because cookie paths
#   in the config are relative to the current directory.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
WEB_PING="$SCRIPT_DIR/web-ping.sh"
CONFIG_FILE="${1:-./targets.conf}"

trim() {
        # trim VAR
        #
        # Strip leading and trailing whitespace from the variable named VAR. The
        # variable is changed in place, so pass its name, not its value.

        local -n _ref="$1"
        _ref="${_ref#"${_ref%%[![:space:]]*}"}"
        _ref="${_ref%"${_ref##*[![:space:]]}"}"
}

# die MESSAGE: print an error and exit. note MESSAGE: print a line.
die()  { printf 'Error: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*"; }

ask() {
        # ask VAR "Prompt" [DEFAULT]
        #
        # Prompt for one line of input, trim it, and store it in the variable named
        # VAR. If the answer is empty, DEFAULT is used instead.

        local -n __a_out="$1"
        local __prompt="$2"
        local __def="${3:-}"
        local __line
        [[ -n "$__def" ]] && __prompt+=" [$__def]"
        read -r -p "$__prompt: " __line || die "input closed"
        trim __line
        __a_out="${__line:-$__def}"
}

# restore_tty: put the terminal back the way ask_secret found it. It runs on
# exit and when the script is interrupted, so the terminal is never left with
# echo off.
TTY_SAVED=""
restore_tty() { [[ -n "$TTY_SAVED" ]] && stty "$TTY_SAVED" 2>/dev/null; TTY_SAVED=""; }
trap restore_tty EXIT
trap 'restore_tty; printf "\n"; exit 130' INT TERM

ask_secret() {
        # ask_secret VAR "Prompt"
        #
        # Like ask, but the input isn't shown on screen. On a terminal, the tty is
        # taken out of canonical (line-editing) mode for the read, because canonical
        # mode silently cuts a line off at 4095 bytes and cookie headers can be
        # longer. The catch is that backspace doesn't work at this prompt, so paste
        # the value and press Enter. restore_tty puts the terminal back afterwards,
        # including when the script is interrupted.

        local -n __s_out="$1"
        local __line=""
        local __rc=0
        if [[ -t 0 ]]; then
                TTY_SAVED=$(stty -g)
                stty -echo -icanon min 1 time 0
                printf '%s: ' "$2" >&2   # prompt only after echo is off
                IFS= read -r __line || __rc=$?
                restore_tty
                printf '\n' >&2
        else
                IFS= read -r __line || __rc=$?
        fi
        (( __rc == 0 )) || [[ -n "$__line" ]] || die "input closed"
        trim __line
        __s_out="$__line"
}

confirm() {
        # confirm "Question" y|n
        #
        # Ask a yes/no question, with y or n as the answer used when Enter is
        # pressed. Returns 0 for yes and 1 for no.

        local __prompt="$1"
        local __def="$2"
        local __line
        local __hint="y/N"
        [[ "$__def" == y ]] && __hint="Y/n"
        while :; do
                read -r -p "$__prompt [$__hint]: " __line || die "input closed"
                trim __line
                __line="${__line,,}"
                __line="${__line:-$__def}"
                case "$__line" in
                        y|yes) return 0 ;;
                        n|no)  return 1 ;;
                esac
        done
}

choose() {
        # choose VAR "Prompt" DEFAULT "a b c"
        #
        # Ask until the answer is one of the listed single letters, and store it in
        # the variable named VAR. Enter on its own picks DEFAULT.

        local -n __c_out="$1"
        local __prompt="$2"
        local __def="$3"
        local __valid=" $4 "
        local __line
        while :; do
                read -r -p "$__prompt [$__def]: " __line || die "input closed"
                trim __line
                __line="${__line,,}"
                __line="${__line:-$__def}"
                if [[ "$__line" != *[[:space:]]* && "$__valid" == *" $__line "* ]]; then
                        __c_out="$__line"
                        return 0
                fi
        done
}

find_entry() {
        # find_entry URL
        #
        # Look up URL in the config. Returns 1 if it isn't there.
        #
        # Sets:
        # - E_HOPS:             The entry's MAX_HOPS.
        # - E_TEXT:             The entry's EXPECTED_TEXT.
        # - E_FINAL:            The entry's FINAL_URL.
        # - E_COOKIE:           Its cookie file, if AUTH names one.
        # - E_TOKEN:            NAME or NAME@domain, if AUTH names a token.
        # - E_BLANK:            1 if AUTH is blank, so web-ping's default applies.

        local want="$1"
        local u
        local h
        local a
        local t
        local f
        local x
        [[ -f "$CONFIG_FILE" ]] || return 1
        while IFS='|' read -r u h a t f x || [[ -n "${u:-}" ]]; do
                u="${u:-}"; h="${h:-}"; a="${a:-}"; t="${t:-}"; f="${f:-}"
                trim u; trim h; trim a; trim t; trim f
                [[ -z "$u" || "$u" == \#* ]] && continue
                if [[ "$u" == "$want" ]]; then
                        E_HOPS="$h"; E_TEXT="$t"; E_FINAL="$f"
                        E_COOKIE=""; E_TOKEN=""; E_BLANK=0
                        case "${a,,}" in
                                "")       E_BLANK=1 ;;
                                -)        ;;
                                token:*)  E_TOKEN="${a#*:}"; E_TOKEN="${E_TOKEN#\$}" ;;
                                cookie:*) E_COOKIE="${a#*:}" ;;
                                *)        E_COOKIE="$a" ;;
                        esac
                        return 0
                fi
        done < "$CONFIG_FILE"
        return 1
}

auth_field() {
        # auth_field COOKIE TOKEN [BLANK]
        #
        # Print the AUTH value to write to the config for a cookie file or a token.
        # When BLANK is 1 it prints nothing, so web-ping falls back to its
        # DEFAULT_COOKIE_FILE argument. A cookie path that itself starts with a word
        # and a colon gets an explicit cookie: prefix, so web-ping doesn't mistake
        # the word for an AUTH type.

        if [[ "${3:-0}" == 1 ]]; then
                return 0
        elif [[ -n "${2:-}" ]]; then
                printf 'token:%s' "$2"
        elif [[ -n "${1:-}" && "$1" != "-" ]]; then
                if [[ "$1" =~ ^[A-Za-z]+: ]]; then
                        printf 'cookie:%s' "$1"
                else
                        printf '%s' "$1"
                fi
        else
                printf -- '-'
        fi
}

remove_entry() {
        # remove_entry URL
        #
        # Remove the line for URL from the config, keeping the file's permissions.

        local tmp
        tmp=$(mktemp)
        awk -F'|' -v u="$1" '{ f = $1; gsub(/^[[:space:]]+|[[:space:]]+$/, "", f); if (f == u) next; print }' \
                "$CONFIG_FILE" > "$tmp"
        cat "$tmp" > "$CONFIG_FILE"
        rm -f "$tmp"
}

entry_line() {
        # entry_line URL HOPS AUTH TEXT FINAL
        #
        # Print one config line. FINAL is left off when it's empty.

        printf '%s|%s|%s|%s' "$1" "$2" "$3" "$4"
        [[ -n "${5:-}" ]] && printf '|%s' "$5"
        printf '\n'
}

append_entry() {
        # append_entry URL HOPS AUTH TEXT FINAL
        #
        # Add a config line to the end of the config. A new config file starts with
        # a short header explaining the format.

        if [[ ! -f "$CONFIG_FILE" ]]; then
                {
                        printf '%s\n' "# Format: URL | MAX_HOPS | AUTH | EXPECTED_TEXT | FINAL_URL"
                        printf '%s\n' "# EXPECTED_TEXT starting with '~' ignores case ('\\~' = literal '~'). FINAL_URL (optional): space-separated terms, '!term' = must not contain."
                        printf '%s\n' "# AUTH: '-' none, PATH or cookie:PATH cookie file, token:NAME[@domain] bearer token from \$NAME."
                        printf '%s\n' "# See targets.conf.example for details."
                } > "$CONFIG_FILE"
        elif [[ -s "$CONFIG_FILE" && -n "$(tail -c1 "$CONFIG_FILE")" ]]; then
                printf '\n' >> "$CONFIG_FILE"   # file did not end with a newline
        fi
        entry_line "$@" >> "$CONFIG_FILE"
}

C_NAMES=()
C_VALUES=()

add_cookie() {
        # add_cookie NAME VALUE
        #
        # Add one cookie to C_NAMES and C_VALUES. Invalid names, values containing
        # a tab, and repeats of a name already added are skipped with a note.

        local name="$1"
        local value="$2"
        if [[ -z "$name" || "$name" =~ [[:space:]] ]]; then
                note "  skipped: invalid cookie name '${name}'"
                return
        fi
        if [[ "$value" == *$'\t'* ]]; then
                note "  skipped: value for '${name}' contains a tab"
                return
        fi
        local existing
        for existing in "${C_NAMES[@]}"; do
                if [[ "$existing" == "$name" ]]; then
                        # Browsers list the most specific cookie first, so keep the first one.
                        note "  skipped: duplicate '${name}' (kept the first one)"
                        return
                fi
        done
        C_NAMES+=("$name")
        C_VALUES+=("$value")
}

collect_cookies() {
        # collect_cookies
        #
        # Ask for cookies, either pasted as a whole Cookie header or entered one
        # name and value at a time, and fill C_NAMES and C_VALUES. Exits if none
        # were entered.

        local mode
        local line
        local part
        local name
        local value
        local -a parts
        C_NAMES=()
        C_VALUES=()

        note ""
        note "How do you want to enter the cookies?"
        note "  p) Paste the Cookie request header. In browser DevTools: Network tab, reload,"
        note "     click the first request, Headers > Request Headers > Cookie, copy the value."
        note "  e) Enter each cookie name and value one at a time"
        choose mode "Choice" p "p e"

        if [[ "$mode" == p ]]; then
                ask_secret line "Paste Cookie header (input hidden)"
                note "Read ${#line} characters."
                [[ "${line,,}" == cookie:* ]] && line="${line#*:}"
                IFS=';' read -r -a parts <<< "$line"
                for part in "${parts[@]}"; do
                        trim part
                        [[ -z "$part" ]] && continue
                        if [[ "$part" != *=* ]]; then
                                note "  skipped: '${part:0:20}' is not name=value"
                                continue
                        fi
                        name="${part%%=*}"; value="${part#*=}"
                        trim name; trim value
                        add_cookie "$name" "$value"
                done
        else
                while :; do
                        ask name "Cookie name (blank when done)"
                        [[ -z "$name" ]] && break
                        ask_secret value "Value for $name (input hidden)"
                        add_cookie "$name" "$value"
                done
        fi

        (( ${#C_NAMES[@]} > 0 )) || die "no cookies entered"
        note "Got ${#C_NAMES[@]} cookie(s): ${C_NAMES[*]}"
}

write_cookie_file() {
        # write_cookie_file PATH DOMAIN URL
        #
        # Write the cookies in C_NAMES and C_VALUES to PATH in the Netscape format
        # that curl reads. The file is readable only by you, and a new cookie
        # directory is too. A DOMAIN with a leading dot also covers its subdomains,
        # and an https URL marks the cookies as secure.

        local path="$1"
        local domain="$2"
        local url="$3"
        local sub=FALSE
        local secure=FALSE
        local i
        [[ "$domain" == .* ]] && sub=TRUE
        [[ "$url" == https://* ]] && secure=TRUE
        local dir
        local tmp
        dir=$(dirname -- "$path")
        if [[ ! -d "$dir" ]]; then
                mkdir -p -- "$dir"
                chmod 700 -- "$dir"
        fi
        # mktemp creates the file 0600; mv then replaces any old file and its permissions.
        tmp=$(mktemp "$dir/.cookie.XXXXXX")
        {
                        printf '# Netscape HTTP Cookie File\n'
                        printf '# Created by add-target.sh on %(%Y-%m-%d %H:%M:%S)T for %s\n' -1 "$url"
                        for i in "${!C_NAMES[@]}"; do
                                # domain, include-subdomains, path, secure, expiry (0 = session), name, value
                                printf '%s\t%s\t/\t%s\t0\t%s\t%s\n' \
                                        "$domain" "$sub" "$secure" "${C_NAMES[i]}" "${C_VALUES[i]}"
                        done
        } > "$tmp"
        mv -f -- "$tmp" "$path"
        note "Wrote $path"
}

make_cookies() {
        # make_cookies PATH URL
        #
        # Ask for the cookie domain and the cookies, then write them to PATH. When
        # PATH already exists, its domain is offered as the default.

        local path="$1"
        local url="$2"
        local host
        local domain
        local def_domain
        host="${url#*://}"; host="${host%%/*}"; host="${host##*@}"; host="${host%%:*}"
        def_domain="$host"
        # When refreshing, keep the domain the existing file uses (e.g. .example.com).
        if [[ -f "$path" ]]; then
                domain=$(awk -F'\t' '!/^#/ && NF >= 7 { print $1; exit }' "$path")
                [[ -n "$domain" ]] && def_domain="$domain"
        fi

        note ""
        note "Cookie domain: the host the cookies are sent to. Use a leading dot (e.g. .example.com)"
        note "if the site redirects across hosts and the cookies must follow (common with PeopleSoft"
        note "behind a load balancer). Your browser's DevTools Application > Cookies shows each"
        note "cookie's Domain."
        ask domain "Cookie domain" "$def_domain"

        collect_cookies
        write_cookie_file "$path" "$domain" "$url"
}

run_test() {
        # run_test URL HOPS AUTH TEXT FINAL
        #
        # Check a single target with web-ping.sh, using a temporary config. Nothing
        # is logged or emailed. Returns web-ping's exit code.

        local tmp
        local rc=0
        tmp=$(mktemp)
        entry_line "$@" > "$tmp"
        note ""
        note "Testing with web-ping.sh..."
        ALERT_EMAIL='' "$WEB_PING" "$tmp" "" "" /dev/null || rc=$?
        rm -f "$tmp"
        return "$rc"
}

ask_checks() {
        # ask_checks DEFAULT_HOPS DEFAULT_TEXT DEFAULT_FINAL
        #
        # Ask for the target's checks, offering the defaults given.
        #
        # Sets:
        # - HOPS:               The most redirects allowed.
        # - TEXT:               The expected text, with a leading '~' if the match
        #                       should ignore case.
        # - FINAL:              The FINAL_URL terms, or empty to skip that check.

        # Stored form: '~text' = ignore case, '\~text' = literal leading '~'.
        local def_text="$2"
        local def_nocase=n
        if [[ "$def_text" == '\~'* ]]; then
                def_text="${def_text#'\'}"
        elif [[ "$def_text" == '~'?* ]]; then
                def_text="${def_text#'~'}"
                def_nocase=y
        fi

        while :; do
                ask HOPS "Max redirects allowed (0 = page must load directly)" "$1"
                [[ "$HOPS" =~ ^(0|[1-9][0-9]*)$ ]] && break
                note "  enter a whole number without leading zeros"
        done

        note ""
        note "Expected text: pick something only shown after login, so a login page fails the check."
        note "Take it from what curl receives (see ./web-ping.sh --trace), not what the browser shows."
        while :; do
                if [[ -n "$def_text" ]]; then
                        ask TEXT "Text the page must contain ('-' = none required)" "$def_text"
                else
                        ask TEXT "Text the page must contain (blank = none required)"
                fi
                [[ "$TEXT" == "-" ]] && TEXT=""
                [[ "$TEXT" != *'|'* ]] && break
                note "  text cannot contain '|'"
        done
        if [[ -n "$TEXT" ]]; then
                if confirm "Ignore upper/lower case when matching it?" "$def_nocase"; then
                        TEXT="~$TEXT"
                elif [[ "$TEXT" == '~'* ]]; then
                        TEXT="\\$TEXT"   # keep a typed leading '~' literal
                fi
        fi

        note ""
        note "Final URL: checks the URL of the page you end up on after the redirects, to"
        note "catch being sent somewhere else (maintenance page, sign-in page, error page)."
        note "Enter terms separated by spaces; each must appear in that URL. Start a term"
        note "with '!' if the URL must NOT contain it. Matching ignores case."
        note "  e.g. host.example.com/psp/ !cmd=login !maintenance"
        note "'./web-ping.sh --trace' shows where a target ends up with and without cookies."
        while :; do
                if [[ -n "$3" ]]; then
                        ask FINAL "Final URL must contain ('-' = not checked)" "$3"
                else
                        ask FINAL "Final URL must contain (blank = not checked)"
                fi
                [[ "$FINAL" == "-" ]] && FINAL=""
                [[ "$FINAL" != *'|'* ]] && break
                note "  cannot contain '|'"
        done
}

ask_token() {
        # ask_token DEFAULT
        #
        # Ask for the name of the environment variable holding the bearer token, and
        # the domain it may be sent to. Sets TOKEN to NAME when the token goes only
        # to the target's own host, or NAME@domain when it may also go to that domain
        # and its subdomains. DEFAULT uses the same form.

        local def_var="${1%%@*}"
        local def_domain=""
        local var
        local domain
        local host
        [[ "$1" == *@* ]] && def_domain="${1#*@}"
        host="${URL#*://}"; host="${host%%[/?#]*}"; host="${host##*@}"; host="${host%%:*}"
        host="${host,,}"

        note ""
        note "Enter the name of the environment variable that will hold the token. It is sent"
        note "as an \"Authorization: Bearer\" header, only over https. The token itself is"
        note "never saved."
        while :; do
                ask var "Token variable name" "$def_var"
                var="${var#\$}"
                [[ "$var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] && break
                note "  use letters, digits and _ only, not starting with a digit"
        done
        TOKEN="$var"

        note ""
        note "By default the token is sent only to $host. If the site redirects to other hosts"
        note "that also need it (e.g. www.example.com -> app.example.com), enter the domain"
        note "they share (example.com); it and all its subdomains will get the token. Only"
        note "name a domain you trust completely."
        while :; do
                ask domain "Token domain" "${def_domain:-$host}"
                domain="${domain,,}"
                domain="${domain#.}"
                if [[ "$domain" == *[!a-z0-9.-]* || "$domain" != *.* && "$domain" != "$host" ]]; then
                        note "  enter a domain name like example.com"
                        continue
                fi
                if [[ "$host" != "$domain" && "$host" != *".$domain" ]]; then
                        note "  $host is not in $domain; enter $host or a domain it belongs to"
                        continue
                fi
                break
        done
        [[ "$domain" != "$host" ]] && TOKEN="$var@$domain"

        if [[ -z "${!var:-}" ]]; then
                note "  Note: \$$var is not set in this shell, so the test will fail. Run"
                note "  'export $var=...' first, or save anyway and set it before checks run."
        fi
}

[[ -x "$WEB_PING" ]] || die "web-ping.sh not found next to this script ($WEB_PING)"

ask URL "URL to check (e.g. https://app.example.com/psp/ps/)"
[[ "$URL" =~ ^https?://[^/[:space:]]+ ]] || die "URL must start with http:// or https://"
[[ "$URL" != *'|'* ]] || die "URL cannot contain '|'"

MODE=new
E_HOPS=""; E_COOKIE=""; E_TEXT=""; E_FINAL=""; E_TOKEN=""; E_BLANK=0
if find_entry "$URL"; then
        note ""
        note "Already in $CONFIG_FILE: $(entry_line "$URL" "$E_HOPS" "$(auth_field "$E_COOKIE" "$E_TOKEN" "$E_BLANK")" "$E_TEXT" "$E_FINAL")"
        if [[ -n "$E_COOKIE" ]]; then
                note "  c) Refresh its cookies only"
                note "  r) Replace the whole entry"
                note "  q) Quit"
                choose MODE "Choice" c "c r q"
        else
                note "  r) Replace the whole entry"
                note "  q) Quit"
                choose MODE "Choice" r "r q"
        fi
        [[ "$MODE" == q ]] && exit 0
fi

if [[ "$MODE" == c ]]; then
        HOPS="$E_HOPS"; COOKIE="$E_COOKIE"; TEXT="$E_TEXT"; FINAL="$E_FINAL"; TOKEN=""; BLANK=0
        make_cookies "$COOKIE" "$URL"
else
        ask_checks "${E_HOPS:-1}" "$E_TEXT" "$E_FINAL"

        COOKIE="-"
        TOKEN=""
        BLANK=0
        default_auth=n
        auth_choices="n c t"
        [[ -n "$E_COOKIE" ]] && default_auth=c
        [[ -n "$E_TOKEN" ]] && default_auth=t
        note ""
        note "How does this site authenticate?"
        if (( E_BLANK )); then
                note "  d) Keep using web-ping's default cookie file argument (AUTH left blank)"
                default_auth=d
                auth_choices="d $auth_choices"
        fi
        note "  n) No login needed"
        note "  c) Cookies copied from your browser"
        note "  t) A bearer token from an environment variable"
        choose auth_kind "Choice" "$default_auth" "$auth_choices"
        case "$auth_kind" in
                d)
                        BLANK=1
                        note "  Note: the test below runs without the default cookie file."
                        ;;
                c)
                        host="${URL#*://}"; host="${host%%/*}"; host="${host##*@}"; host="${host%%:*}"
                        while :; do
                                ask COOKIE "Cookie file path" "${E_COOKIE:-./cookies/$host}"
                                [[ "${COOKIE,,}" == cookie:* ]] && COOKIE="${COOKIE#*:}"
                                if [[ "$COOKIE" == "-" || -z "$COOKIE" || "$COOKIE" == *'|'* \
                                        || "$COOKIE" == *[[:space:]]* ]]; then
                                        note "  enter a file path (no spaces or '|')"
                                        continue
                                fi
                                if [[ -e "$COOKIE" && "$COOKIE" != "$E_COOKIE" ]]; then
                                        confirm "$COOKIE already exists. Overwrite it?" n || continue
                                fi
                                break
                        done
                        make_cookies "$COOKIE" "$URL"
                        ;;
                t)
                        ask_token "$E_TOKEN"
                        ;;
        esac
fi

# Test the target, and let the user fix things until it passes or they
# decide to save or quit anyway.
while :; do
        if run_test "$URL" "$HOPS" "$(auth_field "$COOKIE" "$TOKEN" "$BLANK")" "$TEXT" "$FINAL"; then
                note "Check passed."
                break
        fi
        note ""
        note "Check failed. What now?"
        options="s q"
        default_action=q
        if [[ "$MODE" != c ]]; then
                note "  e) Edit max redirects / expected text / final URL"
                options="e $options"
                default_action=e
        fi
        if [[ -n "$COOKIE" && "$COOKIE" != "-" ]]; then
                note "  r) Re-enter cookies"
                options="r $options"
                default_action=r
        fi
        if [[ "$MODE" == c ]]; then
                note "  s) Keep the new cookies anyway"
                note "  q) Quit"
        else
                note "  s) Save the config entry anyway"
                note "  q) Quit without saving the config entry"
        fi
        choose action "Choice" "$default_action" "$options"
        case "$action" in
                r) make_cookies "$COOKIE" "$URL" ;;
                e)
                        ask_checks "$HOPS" "$TEXT" "$FINAL"
                        ;;
                s) break ;;
                q)
                        [[ "$MODE" == c ]] && note "The new cookie file was kept at $COOKIE."
                        exit 1
                        ;;
        esac
done

if [[ "$MODE" == c ]]; then
        note "Cookies refreshed; $CONFIG_FILE unchanged."
        exit 0
fi

[[ "$MODE" == r ]] && remove_entry "$URL"
AUTH=$(auth_field "$COOKIE" "$TOKEN" "$BLANK")
append_entry "$URL" "$HOPS" "$AUTH" "$TEXT" "$FINAL"
note "Saved to $CONFIG_FILE: $(entry_line "$URL" "$HOPS" "$AUTH" "$TEXT" "$FINAL")"
