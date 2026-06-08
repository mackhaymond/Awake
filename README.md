# Awake

A native macOS menu-bar app that shows **who is keeping your Mac awake** — and lets
you keep it awake yourself, with timed holds and a global hotkey. Instead of a single
on/off, it breaks down every power assertion by **owner** and lets you start/stop holds
natively.

Zero external dependencies — only Apple system frameworks (SwiftUI, AppKit,
IOKit, Carbon, ServiceManagement).

## What it shows

The dropdown groups every sleep-relevant power assertion into four buckets:

| Bucket | What it is |
|---|---|
| **This App** | Caffeination you started *here* (a native `IOPMAssertion`). |
| **You** | `caffeinate` *you* started — typed in a terminal. Shows the command (`caffeinate -i -t 300`), a live countdown, and the source (`CLI` / terminal name). |
| **Apps** | An app/tool keeping sleep open — including **tools that spawn `caffeinate` under the hood** (e.g. **Claude Code** → "Claude Code · via caffeinate"), plus apps holding native assertions (**Arc** WebRTC/audio, ChatGPT, Messages…). Apps that hold sleep "on behalf of" another (via `runningboardd`) are attributed to the real app. |
| **System** | OS plumbing — `powerd` (display-on), `WindowServer`, and background daemons (`mds_stores`, `dataaccessd`, `cloudd`…). Hidden by default; toggle in Settings. |

### How caffeinate attribution works

The `caffeinate` CLI is used by *you* (typed in a terminal) **and** by tools that
keep the Mac awake while they run — Claude Code, for instance, spawns
`caffeinate -i -t 300` and refreshes it every 5 minutes. To tell these apart,
Awake walks each `caffeinate` process's **parent/ancestor chain** (`sysctl` +
`proc_pidpath`) and credits the nearest meaningful originator:

- nearest non-shell ancestor is a **terminal emulator** (WezTerm, iTerm, Terminal…)
  or the process is shell/launchd-rooted → **You** (`CLI`) — you typed it
- nearest ancestor is **any other tool/app** (Claude Code, build scripts, Electron
  apps…) → **Apps**, labelled "*Tool* · via caffeinate"

Shells, `tmux`, `login`, `sudo`, etc. are treated as pass-through; generic
runtimes (`node`, `electron`…) are bridged up to the owning `.app`.

The **menu-bar icon** encodes two axes independently — **shape** = is an app involved,
**color/fill** = are *you* holding it — so you can always tell whether you have it
caffeinated yourself even when an app is also keeping it awake:

| State | Shape | Default color |
|---|---|---|
| idle — Mac can sleep | outline cup | adaptive |
| you via Awake only | filled cup | adaptive (template) |
| you via CLI only | filled cup | adaptive (template) |
| an app only | outline cup **+ corner badge** | orange badge |
| you (Awake) + an app | filled cup **+ corner badge** | orange badge |
| you (CLI) + an app | filled cup **+ corner badge** | orange badge |

Precedence is Awake > CLI when both hold. The combined states draw the app-colored
circle as a small corner badge (with a neutral separation ring) over your cup, so your
own hold stays visible. By default your own holds render as adaptive **template** glyphs
that follow the menu bar's light/dark appearance; set a custom color to opt out.

### Customizing the colors

**Settings → Appearance** has a live preview of all six states and color wells for
the four base colors (This App / You / Apps / Idle). The self/CLI/idle slots default to
*adaptive* template glyphs that follow the menu-bar appearance; pick a custom color or
revert. A "Reset Icon Colors" button restores the shipped palette. Colors persist in
`UserDefaults` and the menu-bar glyph re-renders immediately.

Render the current palette's states to a PNG: `Awake.app/Contents/MacOS/Awake --icons /tmp/states.png`

## Controls

- **Toggle / timed holds**: 15m / 30m / 1h / 2h / 4h / 8h / custom / "until time" /
  indefinite, with a live countdown and a "+15 min" extend. Timed holds use a kernel
  auto-release timeout (`IOPMAssertion`), so the hold ends even if the app is killed.
- **Global hotkey** to toggle from anywhere — default **⌃⌥⌘A** — rebindable in Settings
  (Carbon `RegisterEventHotKey`; no Accessibility permission needed).
- **Stop Terminal Commands** — sends SIGTERM to the stray `caffeinate` processes
  you started in a terminal.
- **Launch at login** via `SMAppService` (toggle in Settings).
- **Categories** — manually override any holder's bucket (Settings → Categories);
  overrides persist and flow into the dropdown and the menu-bar icon.

## Build & run

```sh
cd ~/Projects/Awake
bash build.sh          # swift build -c release → assembles + ad-hoc-signs Awake.app
open Awake.app         # registers with LaunchServices; menu-bar icon appears
```

Requires the Swift toolchain (Xcode). macOS 14+ (`LSMinimumSystemVersion`); built/tested on macOS 26.

## Headless diagnostics

```sh
Awake.app/Contents/MacOS/Awake --dump            # print the classified buckets and exit
Awake.app/Contents/MacOS/Awake --selftest        # verify the caffeination lifecycle (create → detect → release)
Awake.app/Contents/MacOS/Awake --icons [path]    # render all icon states to a PNG
Awake.app/Contents/MacOS/Awake --appicon <dir>   # render an AppIcon.iconset (used by build.sh)
Awake.app/Contents/MacOS/Awake --help            # show usage
```

## Note: crowded menu bars & the notch

macOS hides menu-bar items that don't fit (behind the notch on notched MacBooks).
If Awake's icon doesn't appear, your bar is full — use a menu-bar manager such as
[Ice](https://github.com/jordanbaird/Ice) (free, open source) or Bartender, or
remove other items.

## Layout

```
Package.swift            executableTarget "Awake", no dependencies
build.sh                 builds + bundles + ad-hoc signs Awake.app
Info.plist               reference plist (build.sh generates the authoritative one)
Sources/Awake/
  AwakeApp.swift           @main entry (+ --dump/--selftest/--icons/--appicon/--help), MenuBarExtra + colored icon + app delegate
  AwakeModel.swift         coordinator: caffeination, hotkey, login item, refresh timer
  AssertionReader.swift    reads assertions via IOKit (IOPMCopyAssertionsByProcess), pmset fallback
  AssertionClassifier.swift buckets holders + derives friendly reasons
  AppIdentityResolver.swift PID/bundle → friendly app name + icon
  CaffeinationController.swift native IOPMAssertion create/release + kill-stray-caffeinate
  HotKey.swift             Carbon global hotkey wrapper
  LoginItem.swift          SMAppService launch-at-login
  AppPreferences.swift     UserDefaults-backed settings
  Models.swift             value types (PowerAssertion, Bucket, AssertionRow, key combo…)
  MenuContentView.swift    the dropdown UI
  SettingsView.swift       tabbed settings (General / Appearance / Categories / Advanced / About)
  DebugDump.swift          --dump / --selftest implementations
```
