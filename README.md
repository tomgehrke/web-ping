# web-ping

A small health checker for websites, including ones behind a login. It is written in Bash.

For each target it fetches the page with curl and follows redirects the way a browser does, carrying cookies from hop to hop. A target passes only if all of these hold:

- the server answered **HTTP 200**
- it took **no more redirects** than you allowed
- the page contains your **expected text**
- the page you **end up on** after the redirects has the URL you expect

Failures are logged and can be emailed. The exit code tells cron or other scripts whether everything passed.

Checking a page behind a login works by replaying your browser's session cookies or sending a bearer token. A plain uptime check can't catch an expired login: the site quietly redirects to a sign-in page, which returns 200. web-ping is built to catch that case.

## Files

| File | Purpose |
|---|---|
| `web-ping.sh` | Runs the checks, logs results and sends alerts. Also has a `--trace` mode for setting up targets. |
| `add-target.sh` | Interactive helper. Adds or updates a target, builds its cookie file from cookies copied out of your browser, and tests it. |
| `targets.conf.example` | Documented example config. |
| `targets.conf` | Your targets. Not committed. |
| `cookies/` | Cookie files for targets that need a login. Not committed. |
| `health_check.log` | Run log. Not committed. |

## Requirements

- Bash 4.4 or newer. macOS ships Bash 3.2; install a newer one with Homebrew.
- curl
- Optional, for email alerts: `mail` or `sendmail`.

## Quick start

```bash
./add-target.sh   # add a target interactively; creates ./targets.conf if needed
./web-ping.sh     # check every target in ./targets.conf
```

You can also start from `cp targets.conf.example targets.conf`. If you do, delete its example targets: the login example points to a cookie file that doesn't exist, so it fails on every run.

## Configuration

Each line of `targets.conf` has up to five fields separated by `|`:

```
URL | MAX_HOPS | AUTH | EXPECTED_TEXT | FINAL_URL
```

| Field | Meaning |
|---|---|
| `URL` | The page to fetch. Redirects are followed, up to 15. |
| `MAX_HOPS` | The most redirects allowed. Use `0` if the page loads directly. |
| `AUTH` | How the target logs in: `-` for no login; blank to use the `DEFAULT_COOKIE_FILE` argument; a cookie file as `cookie:PATH` or just `PATH` (relative to the directory you run `web-ping.sh` from; use the `cookie:` form if the path itself starts with a word and a colon); or a bearer token as `token:NAME`, read from the environment variable `$NAME`. One value only. See [Cookies](#cookies-for-sites-behind-a-login) and [Bearer tokens](#bearer-tokens). |
| `EXPECTED_TEXT` | Text the page must contain. Leave it blank to skip this check. Start it with `~` to ignore upper/lower case (`~sign out`). Write `\~` for a literal leading `~`. |
| `FINAL_URL` | Optional. Checks the URL of the page you end up on after the redirects. Give terms separated by spaces, ignoring case: each must appear in that URL, and a term starting with `!` must not. Use `-`, or leave the field off, to skip this check. |

Lines starting with `#` and blank lines are ignored. Values can't contain `|`.

Examples:

```
# Public page, no login
https://www.example.com/|0|-|Example Domain

# Page behind a login
https://app.example.com/|1|./cookies/app.example.com|~sign out|app.example.com/home !login

# Page that needs a bearer token from $APP_TOKEN
https://api.example.com/status|0|token:APP_TOKEN|"ok"

# Starts on www and redirects to app; both need the token
https://www.example.com/|1|token:APP_TOKEN@example.com|~sign out|app.example.com
```

### Choosing checks

A broken site doesn't always return an error. During patching it may redirect to a maintenance page. When a login expires, it redirects to a sign-in page. Either can return HTTP 200, so the status code alone looks healthy. The other checks catch these cases.

- **`MAX_HOPS`**: The redirect to a sign-in page usually adds hops. Set it to the number a logged-in request takes. Better still, point `URL` at the page you end up on, and use `0`.
- **`EXPECTED_TEXT`**: Pick text that only appears when you're logged in. Avoid the product name, which the sign-in page shows too. Take the text from what curl receives, not from what your browser shows. Many apps build their pages with JavaScript, which curl doesn't run, so on-screen text may never reach curl. `--trace` shows what curl gets.
- **`FINAL_URL`**: This checks which page you ended up on. Required terms catch being sent to a different host or path, such as a maintenance site or a single sign-on host. `!` terms catch a wrong page on the right host, such as the app's own login or maintenance page. For example: `app.example.com/home !login !maintenance`. Text-based checks can miss these pages because they often share text, like a site footer, with the real page.

## Commands

### Run the checks

```bash
./web-ping.sh [CONFIG] [DEFAULT_COOKIE_FILE] [ALERT_EMAIL] [LOG_FILE]
```

| Argument | Default | Notes |
|---|---|---|
| `CONFIG` | `./targets.conf` | |
| `DEFAULT_COOKIE_FILE` | none | Used for targets whose `AUTH` field is blank. A field set to `-` means no login. |
| `ALERT_EMAIL` | the `$ALERT_EMAIL` variable | If any target fails, one summary email is sent. |
| `LOG_FILE` | the `$LOG_FILE` variable, or `./health_check.log` | |

Exit codes:

| Code | Meaning |
|---|---|
| `0` | All targets passed. |
| `1` | At least one target failed. |
| `2` | The config file was not found. |

Output in a terminal shows `[ OK ]` and `[FAIL]` in green and red. The log, emails and piped output stay plain text. Set `NO_COLOR=1` to turn the colors off.

### Trace targets while setting them up

```bash
./web-ping.sh --trace [CONFIG] [URL_FILTER]
```

For each target, or only those whose URL contains `URL_FILTER`, this prints every response in the redirect chain. It shows where the chain ended, whether each check passed, and the overall verdict. Targets with a cookie or token are traced twice, with and without them, so you can compare a working session with an expired one. Trace mode doesn't log or send email.

### Add or update a target

```bash
./add-target.sh [CONFIG]
```

It prompts for the URL and each check, then asks how the site logs in (none, cookies or a bearer token) and sets that up: for cookies it builds the cookie file, for a token it asks for the variable name. Then it tests the target and lets you fix anything that fails before saving. For a URL that's already in the config, you can replace the whole entry or just refresh its cookies.

## Cookies for sites behind a login

Sites that use single sign-on (Oracle IDCS, Azure AD, Okta and others) log you in through a series of browser redirects, scripts and often MFA. curl can't reproduce that. So you log in with your browser and give web-ping a copy of the cookies it ends up with.

1. Log in with your browser and open DevTools (F12). Go to the **Network** tab.
2. Reload, then click the request for the **page itself on the host you'll check** (not a `.js` or `.css` file). Cookies set for only one host aren't sent to its other hosts, so the host matters.
3. Under **Request Headers**, copy the value of `Cookie`. In Firefox, turn on **Raw** first.
4. Run `./add-target.sh`, choose **c** (cookies) when it asks how the site logs in, and paste the value with option `p`. Input is hidden, and long headers are fine.
5. For the cookie domain, use the host. Use a leading dot (`.example.com`) if the site redirects between subdomains and the cookies must follow.

The file is written in the Netscape cookie format that curl reads.

**Cookies expire.** When they do, the target starts failing. That is the check doing its job. To refresh them, run `./add-target.sh` again with the same URL and choose **c** to refresh only the cookies. How long a session lasts is set by the site, so expect to refresh periodically. For fully unattended monitoring, ask the site's owners about a monitoring account or a health URL that doesn't need a login.

## Bearer tokens

Some sites accept an OAuth access token in an `Authorization: Bearer …` header instead of cookies. Put the token in an environment variable and set the target's `AUTH` field to `token:NAME`. The token itself never goes in the config.

```bash
export APP_TOKEN='eyJ...'
./web-ping.sh
```

To keep the token from leaking to other sites, web-ping follows redirects itself and decides at each hop whether the token goes along:

- It's sent only over **https**.
- By default it's sent only to the **target's own host**, so a redirect to any other host doesn't get it.
- If the site redirects between hosts that all need the token, name the domain they share: `token:APP_TOKEN@example.com` sends it to `example.com` and every `*.example.com` host, so `www` → `app` keeps it, while a sign-in service on another domain still doesn't get it. The target must be inside that domain. Choose it carefully: a broad domain such as `tn.gov`, or a shared one such as `github.io`, would send the token to sites run by other people.
- curl reads it from a private temporary file, so it doesn't show up in the process list.

web-ping only follows redirects to `http` and `https` URLs. A redirect to any other scheme (`file:`, `ftp:`, `gopher:` …) fails the check.

If the variable isn't set when the check runs, the target fails with "Token variable … is not set" rather than being checked without it.

## Running from cron

Cookie paths are relative, so `cd` into the project first:

```cron
*/15 * * * * cd /path/to/web-ping && ./web-ping.sh ./targets.conf "" ops@example.com >/dev/null 2>&1
```

An alert email is sent on every run that has a failure. With the schedule above, a site that stays down sends one every 15 minutes.

cron starts with an almost empty environment, so tokens set in your shell aren't there. Keep them in a file only you can read, and load it in the cron line:

```cron
*/15 * * * * cd /path/to/web-ping && . ~/.web-ping.env && ./web-ping.sh ./targets.conf "" ops@example.com >/dev/null 2>&1
```

Here `~/.web-ping.env` contains lines like `export APP_TOKEN='…'`. Make it private with `chmod 600 ~/.web-ping.env`.

## Security

- **Cookie files are live login sessions.** Anyone who has them can act as you until they expire. `add-target.sh` makes them readable only by you, and `.gitignore` keeps them out of git. Don't paste them into chats, tickets or email.
- **Bearer tokens are credentials too.** Keep them in environment variables or a private env file, never in `targets.conf` or the repository.
- On WSL, files on a Windows drive (`/mnt/c`, `/mnt/d`, …) ignore Linux permissions by default, so cookie files there are readable by everyone. Keep the project in your Linux home folder, or enable `metadata` in `/etc/wsl.conf`.

## Limitations

- curl doesn't run JavaScript. Choose text that is in the HTML the server sends.
- Each target gets one expected-text check, and it is a plain substring match, not a regular expression.
- Logs aren't rotated.
