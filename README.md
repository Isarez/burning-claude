# Burning Claude

A macOS menu bar app that tracks how close each of your Claude accounts is to
its **5-hour** and **7-day** limits.

```
      I ▓▓░░░░  32%    G ░░░░░░  —     ← 5-hour limit
 🔥     ▓▓▓▓░░  57%      ░░░░░░  —     ← 7-day limit
```

**One pair of bars per signed-in account**, labelled by initial, with a flame
that takes the colour of whichever limit is hottest across all of them. Bar
length is adjustable in Settings. Click for the full breakdown.

**Nothing is tracked until you add it** — not even `~/.claude`. A fresh install
opens on a sign-in prompt rather than guessing which of your config directories
you meant.

Two ways to track an account, and you can mix them:

| | Source | Freshness | Covers |
|---|---|---|---|
| **Session key** | claude.ai's usage endpoint | Every refresh | The whole account, including claude.ai and the mobile apps |
| **Config directory** | Local files only | Whenever Claude Code last ran | Claude Code on this Mac |

Inspired by [ClaudeMeter](https://github.com/eddmann/ClaudeMeter), whose
approach the session-key path adopts — see
[Choosing a source](#choosing-a-source).

## What it shows

The panel lists **each account separately**, because limits are per-account and
combining them would be meaningless. For every account:

- **5-hour limit** — percentage used and when it resets
- **7-day limit** — percentage used and when it resets
- A model-mix strip for the last 30 days, for config-directory accounts — it is
  built from transcripts, and a session key has none behind it

Refresh and settings sit at the top; the flame and both bars sit in the menu bar.

## Where the percentages come from

Every figure below is Anthropic's own — none of them is estimated locally. They
differ only in how they reach the app and how quickly they go stale.

### Session-key accounts

**Settings → Accounts → Sign in with session key** asks for the `sessionKey`
cookie from a browser signed in to claude.ai:

1. Open DevTools (⌥⌘I)
2. Application → Storage → Cookies → `https://claude.ai`
3. Copy the value of `sessionKey`

The key is checked against the API before anything is saved — a typo or an
expired cookie fails at the sheet rather than becoming a permanently broken
row — and then stored in your **login keychain**. Each refresh calls
`GET /api/organizations/{uuid}/usage`, which returns exactly the `five_hour`
and `seven_day` figures shown here. Failures are per-account and visible: an
expired key says so in the panel instead of silently reading as 0%.

This is the only option that reports **on demand** and covers the **whole
account** — usage from claude.ai and the mobile apps never touches this machine,
so no local source can see it. It is also the only one that reads a credential;
[Choosing a source](#choosing-a-source) has the trade-offs.

### Config-directory accounts

**The same source your status line uses.** Claude Code passes the live 5-hour
and 7-day percentages to your status line command on stdin, but never writes
them to disk. Adding one line to that script publishes them, and the panel then
matches the terminal exactly:

```bash
printf '%s' "$input" | jq -c '{rate_limits, at: now}' \
  > "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.claudetokenmeter-ratelimits.json"
```

Settings → **Live figures** shows this with a copy button and reports which
config directories are publishing.

Without it the app falls back to `cachedUsageUtilization` in `.claude.json`.
That is Anthropic's own figure, but it refreshes only rarely — in testing it was
**9 hours stale** with its 5-hour window long since reset — and, critically, it
is **not cleared when you switch accounts**, so it can describe a completely
different account than the one signed in. The app therefore only uses it when
its `accountUuid` matches the account `claude auth status` reports, and shows
`—` rather than a number it cannot stand behind.

**No local estimation.** An earlier version counted transcript tokens and scaled
them against a ceiling. That is unfixable, because these limits are account-wide
while transcripts only cover Claude Code usage under the directories this app
watches — claude.ai, the desktop and mobile apps, and other machines all consume
the same limit invisibly. Checked against known-correct values, a local count
came to roughly **a third** of real usage: plausible-looking and badly wrong.

| Badge | Meaning |
|---|---|
| ✓ `from claude.ai · 2m ago` | Fetched with a session key on the last refresh |
| ✓ `from Claude · 2m ago` | Claude Code's cached figure; matches the terminal |
| ↻ `expired — run /usage` | Cached figure's window has closed |
| ? `—` | Nothing reported for this account yet |

## Multi-account support

Session-key accounts are the easy case: one key per account, added from
Settings, each identified by its organisation and fetched independently. If a
key covers several organisations the first is used.

Config directories are the awkward case, because Claude Code makes them so:
**transcripts contain no account identity**, and `~/.claude.json` records only
the account logged in *right now*.

Config directories are **discovered but never adopted**. Settings lists what it
finds under **Found on this Mac** — `~/.claude`, whatever `CLAUDE_CONFIG_DIR`
points at in your shell, any `~/.claude-*` sibling, and anything under
`~/.claude-accounts/` — each with a `+` to start tracking it.

Earlier versions tracked all of them and made you remove the ones you did not
want. That is the wrong default in both directions: a directory you never use
reports an idle account's figures in the menu bar, which looks merely wrong
rather than misconfigured, and every new `~/.claude-*` directory silently
enrolled itself. An offered directory is one click away; an unwanted one is
noise you have to chase.

**Every account can be removed, `~/.claude` included.** Removing one deletes
nothing outside this app — the directory, its transcripts and its credentials
are untouched, and it drops straight back to being a suggestion under **Found on
this Mac**. Removing a session-key account additionally deletes its key from the
keychain. Remove them all and you are back at the sign-in prompt; that is a
supported state, not a broken one, and is what you want if you only care about
the session-key figures.

Re-adding a directory recovers its full history: untracking throws away the
derived state, and the next scan rebuilds it from the transcripts.

**Adding a config directory.** **Settings → Accounts → Add config directory**
creates a fresh one under `~/.claude-accounts/` and runs Claude Code's own
sign-in against it in Terminal:

```bash
CLAUDE_CONFIG_DIR=~/.claude-accounts/work claude auth login
```

Claude performs the OAuth and keeps the credentials throughout — this app only
notices that an account has appeared in the new directory. Each row shows the
command that runs Claude under that account, with a copy button, because
**usage only lands in a directory when Claude is actually run against it**:

```bash
CLAUDE_CONFIG_DIR=~/.claude-accounts/work claude
```

Directories added by hand still work and are listed alongside. The app looks for
`.claude.json` both inside the directory and next to it, and picks whichever
actually contains an account — the default install has a stub at
`~/.claude/.claude.json` and the real file at `~/.claude.json`.

**Account-switch timeline (one shared directory).** If you `/login` back and
forth in a single directory, the app records who is logged in on every refresh,
building a timeline of windows, and attributes entries by timestamp.

The timeline starts when you first run the app, so **usage from before then is
attributed to the earliest account seen in that directory and flagged as
inferred** (the ⓘ badge). Going forward it is exact, to the resolution of your
refresh interval.

## Accuracy

Three things make this harder than summing the `usage` fields:

**Duplicates.** Resuming or forking a session rewrites earlier turns into the
new transcript file, so the same assistant response appears in several files. On
the history this was developed against, **1.82× the true token count** came from
replayed entries. Every entry is deduplicated globally on the API's
`message.id`, which is stable across replays.

**Nested transcripts.** Some sessions write `.jsonl` files into subdirectories
under `projects/`, so a one-level glob silently misses them. The scanner walks
the tree recursively.

**Synthetic entries.** `<synthetic>` messages are local placeholders carrying no
usage — except the 429s, which are captured *before* that filter because they
are the calibration source.

Verified against an independent implementation over 4,291 deduplicated messages
and 1.69 B tokens: every token counter matched exactly.

## Settings

| Setting | Effect |
|---|---|
| **Meter length** | Length of each menu bar track, 8–80pt (default 28) |
| **Warn at** / **Critical at** | Where bars turn amber and red, and alerts fire (75% / 90%) |
| **Refresh every** | 1, 5 or 10 minutes; also refreshes when the panel opens |
| **Accounts** | Add a session key or a config directory; remove any account, `~/.claude` included; add discovered directories from **Found on this Mac** |

There is no manual token budget: the ceiling is measured, not configured.

## Install

Requires macOS 14+.

```bash
brew install Isarez/tap/burning-claude
xattr -dr com.apple.quarantine /Applications/BurningClaude.app
```

No `brew tap` first and no `--cask`: naming the tap in full installs from it
directly, and `brew install` falls back to casks when no formula shares the
name. After that first install the short `brew install burning-claude` works
too, since the tap is now on the machine.

That third line is not optional. The build is ad-hoc signed but not notarized —
there is no Developer ID behind this — so Gatekeeper refuses to open it until
the quarantine flag Homebrew sets is cleared. Homebrew 6 removed the
`--no-quarantine` flag that used to avoid the extra step.

`brew uninstall burning-claude` removes it; add `--zap` to take settings and
usage history with it. Session keys live in the login keychain and survive
either way — delete them from Keychain Access by searching for
`com.local.claudetokenmeter.sessionkey`.

### Building it yourself

Swift 5.9+ via Command Line Tools is enough — no Xcode.

Build an installer package:

```bash
./make-pkg.sh
sudo installer -pkg dist/BurningClaude-1.0.0.pkg -target /
```

It installs to `/Applications` and launches. The package quits any running copy
first (including a pre-rename `ClaudeTokenMeter`) and leaves settings, tracked
accounts and usage history alone. It is unsigned — there is no Developer ID
behind this — so double-clicking it is refused by Gatekeeper; either use
`installer` as above, or right-click the `.pkg` → **Open** → **Open**.

Or build and copy the app by hand:

```bash
./build-app.sh
cp -R build/BurningClaude.app /Applications/
open /Applications/BurningClaude.app
```

It runs as a menu bar item only (`LSUIElement`) — no Dock icon. Quit from the
power button in the panel footer. Nothing starts it at login; add it under
System Settings › General › Login Items if you want it back after a restart.

The icon is drawn from source by `Tools/MakeIcon.swift` rather than checked in
as pixels — a flame around the burst, rendered natively at every size in the
`.icns` so the 16pt Finder icon stays sharp. `build-app.sh` redraws it whenever
the generator is newer than `Resources/AppIcon.icns`.

Settings opens as an ordinary window (closable, minimisable, resizable, ⌘,) not
as a sheet inside the popover. That matters more than it looks: a `.transient`
popover closes whenever the app stops being frontmost, so a sheet inside one can
be left orphaned with nothing to close it. A window also becomes key properly,
which is what lets a text field accept a paste at all.

The build is ad-hoc signed, which is what lets notifications work. It is not
notarized, so on first launch Gatekeeper may need a right-click → Open.

## Privacy

**Config-directory accounts** read files already on disk, and nothing else —
no network, no credentials:

- `<root>/projects/**/*.jsonl` — token counts, model names, timestamps, 429s
- `<root>/.claude.json` — the `oauthAccount` block and `cachedUsageUtilization`
- `<root>/.claudetokenmeter-ratelimits.json` — live figures, if published
- `claude auth status` — which account is *actually* signed in, since
  `oauthAccount` goes stale after a switch

**Session-key accounts** are the exception, and the only reason this app touches
a credential at all. Adding one means:

- The key is read from a field you paste it into — never from your browser's
  cookie store, which this app cannot and does not access.
- It is written to the **login keychain** (service
  `com.local.claudetokenmeter.sessionkey`) and nowhere else: not `UserDefaults`,
  not the JSON below, not a log line. The UI shows it redacted or not at all.
- It is sent to `claude.ai` and to no other host, over HTTPS, as the `sessionKey`
  cookie on two `GET` requests. No telemetry, no analytics, no third party.
- Removing the account deletes it from the keychain.

A session key grants full access to the account, so treat it like a password.
App state lives in `~/Library/Application Support/BurningClaude/`:

| File | Contents |
|---|---|
| `events.json` | Deduplicated usage events, 180-day retention |
| `limits.json` | Recorded limit hits and their reset times |
| `accounts.json` | Account metadata and the observation timeline |
| `scan-state.json` | Per-file read offsets and seen message IDs |

**Rescan all transcripts** in Settings rebuilds all of it from source.

## Choosing a source

Both paths return Anthropic's own percentages. Neither estimates anything. The
choice is between staleness and credential handling.

**Session key.** Fetched on demand, so the figure is as current as your last
refresh, and it covers the whole account — claude.ai, the desktop and mobile
apps, other machines. Nothing local can see that usage, so nothing local can be
made correct. The costs: the app holds a credential that grants full access to
the account; the endpoint is a **private API**, undocumented and free to change
or disappear without notice; it sits behind Cloudflare, which can refuse a
request that does not look enough like a browser; and ClaudeMeter's own README
notes that using it **may violate Anthropic's Terms of Service**. That applies
here unchanged — it is your call to make, which is why it is opt-in per account
and never the default.

**Config directory.** No credential, no network, no ToS question, and per-root
detail with a model mix from the transcripts. But it can only report what Claude
Code last cached: between sessions that goes stale, and in testing it was **9
hours out of date** with its 5-hour window long since reset. Publishing the
figures from your status line (above) fixes the staleness while Claude Code is
running; it cannot fix the blind spot for usage from anywhere else.

**Both, on the same account,** is supported and shows two rows. They are not
merged: a config directory is identified by its `accountUuid` and a session key
by its organisation UUID, and nothing reliably links the two.

An earlier version of this app also estimated usage by counting transcript
tokens against a ceiling. That is gone. Measured against known-correct values it
came to roughly **a third** of real usage — plausible-looking and badly wrong —
for the same reason the config-directory path is a lower bound.

## Implementation notes

| File | Role |
|---|---|
| `Models.swift` | Token counts, usage/limit events, accounts, config-root paths |
| `SessionKey.swift` | Session-key validation and the session-account model |
| `Keychain.swift` | The one place a session key is stored |
| `ClaudeWebClient.swift` | claude.ai's organisations and usage endpoints |
| `Utilization.swift` | Reads Claude's cached usage figures |
| `RateLimitBridge.swift` | Reads live figures published by a status line |
| `ConfigDiscovery.swift` | Finds config directories to *offer*; tracking stays opt-in |
| `AuthStatus.swift` | Asks Claude Code which account is signed in |
| `LimitParser.swift` | Parses 429 refusal text into kind + reset instant |
| `Calibration.swift` | Turns limit hits into measured ceilings |
| `AccountRegistry.swift` | Account discovery and the attribution timeline |
| `UsageScanner.swift` | Incremental JSONL parsing, global dedupe |
| `Aggregate.swift` | 5-hour and 7-day gauges, window anchoring, formatting |
| `AccountLauncher.swift` | Creates account directories and drives `claude auth login` |
| `UsageStore.swift` | Refresh pipeline, notifications |
| `StatusBarView.swift` | Flame plus per-account two-row meter rendering |
| `PopoverView.swift` / `SettingsView.swift` | SwiftUI panel and settings |
| `AppDelegate.swift` | Status item, popover hosting, Settings window |
| `MainMenu.swift` | Invisible menu that makes ⌘V (and friends) work at all |

Transcripts only grow, so each file is read from the byte offset where the last
scan stopped; a trailing partial line is left unconsumed until it is complete.
Attribution is re-derived on every recompute rather than frozen at scan time, so
it self-corrects as the observation timeline fills in.

Untracking a config directory rebuilds the derived state rather than deleting
that root's slice of it. The scanner's byte offsets and its global set of seen
`message.id`s are not attributed to a root, so a targeted delete would leave the
directory unreadable on a later re-add — nothing new to read, and everything
deduplicated away. Throwing the lot away and re-parsing is what makes removal
reversible.

`ClaudeWebClient` returns the same `UtilizationSnapshot` that Claude Code's
cache is parsed into, so the gauges, thresholds, notifications and menu bar are
indifferent to which source a reading came from — only the badge distinguishes
them. The network fetch runs alongside the transcript scan rather than after it,
and a failed fetch keeps the previous reading (visibly ageing via its `from
claude.ai · Nm ago` label) instead of blanking the account.

## License

MIT — see [LICENSE](LICENSE).

The Claude name and the mark in `Resources/claude.svg` belong to Anthropic and
are not covered by that grant; they appear here to label an unofficial tool for
Claude, which is neither built nor endorsed by Anthropic.
