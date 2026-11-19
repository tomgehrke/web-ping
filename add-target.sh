#!/usr/bin/env bash
# Interactive helper for web-ping.sh: add or update a target in the config file
# and, when the site needs authentication, build its Netscape-format cookie file
# from cookies copied out of the browser.
#
# Usage: ./add-target.sh [CONFIG_FILE]   (default: ./targets.conf)
# Run it from the same directory you run web-ping.sh from, since cookie paths
# in the config are relative to the current directory.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
WEB_PING="$SCRIPT_DIR/web-ping.sh"
CONFIG_FILE="${1:-./targets.conf}"

# ---------------------------------------------------------------- helpers ---

trim() {
  local -n _ref="$1"
  _ref="${_ref#"${_ref%%[![:space:]]*}"}"
  _ref="${_ref%"${_ref##*[![:space:]]}"}"
}

die()  { printf 'Error: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*"; }

# ask VAR "Prompt" [default]: read one trimmed line, falling back to default
ask() {
  local -n __a_out="$1"
  local __prompt="$2" __def="${3:-}" __line
  [[ -n "$__def" ]] && __prompt+=" [$__def]"
  read -r -p "$__prompt: " __line || die "input closed"
  trim __line
  __a_out="${__line:-$__def}"
}

# ask_secret VAR "Prompt": like ask, but input is not echoed. On a terminal the
# tty is switched out of canonical mode for the read, because canonical mode
# silently truncates a line at 4095 bytes and cookie headers can be longer.
# (Side effect: backspace does not work at this prompt. Paste, then Enter.)
TTY_SAVED=""
restore_tty() { [[ -n "$TTY_SAVED" ]] && stty "$TTY_SAVED" 2>/dev/null; TTY_SAVED=""; }
trap restore_tty EXIT
trap 'restore_tty; printf "\n"; exit 130' INT TERM

ask_secret() {
  local -n __s_out="$1"
  local __line="" __rc=0
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

# confirm "Question" y|n: returns 0 for yes
confirm() {
  local __prompt="$1" __def="$2" __line __hint="y/N"
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

# choose VAR "Prompt" default "a b c": read one of the listed single letters
choose() {
  local -n __c_out="$1"
  local __prompt="$2" __def="$3" __valid=" $4 " __line
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

# Look up URL in the config. Sets E_HOPS, E_COOKIE, E_TEXT; returns 1 if absent.
find_entry() {
  local want="$1" u h c t
  [[ -f "$CONFIG_FILE" ]] || return 1
  while IFS='|' read -r u h c t || [[ -n "${u:-}" ]]; do
    u="${u:-}"; h="${h:-}"; c="${c:-}"; t="${t:-}"
    trim u; trim h; trim c; trim t
    [[ -z "$u" || "$u" == \#* ]] && continue
    if [[ "$u" == "$want" ]]; then
      E_HOPS="$h"; E_COOKIE="$c"; E_TEXT="$t"
      return 0
    fi
  done < "$CONFIG_FILE"
  return 1
}

# Remove the line for URL from the config, keeping the file's permissions.
remove_entry() {
  local tmp
  tmp=$(mktemp)
  awk -F'|' -v u="$1" '{ f = $1; gsub(/^[[:space:]]+|[[:space:]]+$/, "", f); if (f == u) next; print }' \
    "$CONFIG_FILE" > "$tmp"
  cat "$tmp" > "$CONFIG_FILE"
  rm -f "$tmp"
}

append_entry() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    printf '%s\n' "# Format: URL | MAX_HOPS | COOKIE_PATH (leave blank or use '-' for none) | EXPECTED_TEXT" \
      > "$CONFIG_FILE"
  elif [[ -s "$CONFIG_FILE" && -n "$(tail -c1 "$CONFIG_FILE")" ]]; then
    printf '\n' >> "$CONFIG_FILE"   # file did not end with a newline
  fi
  printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" >> "$CONFIG_FILE"
}

# ------------------------------------------------------------- cookies ------

C_NAMES=()
C_VALUES=()

add_cookie() {
  local name="$1" value="$2"
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
  local mode line part name value
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

# write_cookie_file PATH DOMAIN URL
write_cookie_file() {
  local path="$1" domain="$2" url="$3" sub=FALSE secure=FALSE i
  [[ "$domain" == .* ]] && sub=TRUE
  [[ "$url" == https://* ]] && secure=TRUE
  local dir tmp
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

# Ask for cookies and a domain, then write the file.
make_cookies() {
  local path="$1" url="$2" host domain def_domain
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

# ---------------------------------------------------------------- testing ---

run_test() {
  local tmp rc=0
  tmp=$(mktemp)
  printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" > "$tmp"
  note ""
  note "Testing with web-ping.sh..."
  ALERT_EMAIL='' "$WEB_PING" "$tmp" "" "" /dev/null || rc=$?
  rm -f "$tmp"
  return "$rc"
}

# ------------------------------------------------------------------- main ---

# ask_hops_text DEFAULT_HOPS DEFAULT_TEXT: sets HOPS and TEXT
ask_hops_text() {
  while :; do
    ask HOPS "Max redirects allowed (0 = page must load directly)" "$1"
    [[ "$HOPS" =~ ^(0|[1-9][0-9]*)$ ]] && break
    note "  enter a whole number without leading zeros"
  done
  note "Expected text: pick something only shown after login, so a login page fails the check."
  while :; do
    if [[ -n "$2" ]]; then
      ask TEXT "Text the page must contain ('-' = none required)" "$2"
    else
      ask TEXT "Text the page must contain (blank = none required)"
    fi
    [[ "$TEXT" == "-" ]] && TEXT=""
    [[ "$TEXT" != *'|'* ]] && break
    note "  text cannot contain '|'"
  done
}

[[ -x "$WEB_PING" ]] || die "web-ping.sh not found next to this script ($WEB_PING)"

ask URL "URL to check (e.g. https://app.example.com/psp/ps/)"
[[ "$URL" =~ ^https?://[^/[:space:]]+ ]] || die "URL must start with http:// or https://"
[[ "$URL" != *'|'* ]] || die "URL cannot contain '|'"

MODE=new
E_HOPS=""; E_COOKIE=""; E_TEXT=""
if find_entry "$URL"; then
  note ""
  note "Already in $CONFIG_FILE: $URL|$E_HOPS|$E_COOKIE|$E_TEXT"
  if [[ -n "$E_COOKIE" && "$E_COOKIE" != "-" ]]; then
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
  HOPS="$E_HOPS"; COOKIE="$E_COOKIE"; TEXT="$E_TEXT"
  make_cookies "$COOKIE" "$URL"
else
  ask_hops_text "${E_HOPS:-1}" "$E_TEXT"

  COOKIE="-"
  default_auth=n
  [[ -n "$E_COOKIE" && "$E_COOKIE" != "-" ]] && default_auth=y
  if confirm "Does this site need a login cookie?" "$default_auth"; then
    host="${URL#*://}"; host="${host%%/*}"; host="${host##*@}"; host="${host%%:*}"
    while :; do
      def_cookie="./cookies/$host"
      [[ -n "$E_COOKIE" && "$E_COOKIE" != "-" ]] && def_cookie="$E_COOKIE"
      ask COOKIE "Cookie file path" "$def_cookie"
      [[ "$COOKIE" == "-" || -z "$COOKIE" || "$COOKIE" == *'|'* ]] \
        && { note "  enter a file path (no '|')"; continue; }
      if [[ -e "$COOKIE" && "$COOKIE" != "$E_COOKIE" ]]; then
        confirm "$COOKIE already exists. Overwrite it?" n || continue
      fi
      break
    done
    make_cookies "$COOKIE" "$URL"
  fi
fi

# Test, and let the user fix things until it passes or they decide.
while :; do
  if run_test "$URL" "$HOPS" "$COOKIE" "$TEXT"; then
    note "Check passed."
    break
  fi
  note ""
  note "Check failed. What now?"
  options="s q"
  default_action=q
  if [[ "$MODE" != c ]]; then
    note "  e) Edit max redirects / expected text"
    options="e $options"
    default_action=e
  fi
  if [[ "$COOKIE" != "-" ]]; then
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
      ask_hops_text "$HOPS" "$TEXT"
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
append_entry "$URL" "$HOPS" "$COOKIE" "$TEXT"
note "Saved to $CONFIG_FILE: $URL|$HOPS|$COOKIE|$TEXT"
