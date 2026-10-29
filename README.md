# Mac Breather - AI sessions follower

**Give your Mac a breather.** A tiny menu bar app that shows, at a glance, how much memory your Mac has left and what your AI coding sessions (Claude Code, Codex) are doing.

Runs on any Mac with macOS 14 or later, Apple Silicon or Intel. Born on an 8 GB Mac that started swapping the moment Claude, Codex, a browser and a simulator ran side by side; thresholds scale with your Mac's memory.

## What it does

Mac Breather adds two icons to the menu bar. Keep both, or only the one you need: the gear at the bottom of each panel offers **Memory and Sessions**, **Memory Only** or **Sessions Only**, along with the alert switches.

**The memory ring.** Green, orange or red, with the share of memory in use. Click it to see:
- memory used, swap and free disk space, and a 30 minute memory curve;
- *Give your Mac a breather*: concrete tips with a button, such as shutting down a Simulator left running without Xcode, closing idle AI sessions, quitting heavy apps sitting in the background, or restarting when swap gets large;
- the six heaviest apps, with a bar each (hover to quit one).

**The session dots.** One dot per Claude Code or Codex session:

| Dot | State | Meaning |
|---|---|---|
| blue, breathing | Working | the agent is working right now |
| orange | Needs you | a question, a permission or a plan is waiting for you |
| green | Your turn | finished, and you have not looked at it yet |
| grey | Seen | finished, and you opened the app since (or clicked its row or alert) |
| grey circle | Idle | done for more than 30 min with nothing running; it still holds memory and can be closed |

Click it to see every session with its title, its state and since when, and its memory. Click a row to jump to the app.

Idle sessions can be put in low priority automatically (`PRIO_DARWIN_BG`). They go back to normal as soon as they start working again.

## Alerts

Mac Breather draws its own alerts: small glass cards under the menu bar, with a short chime (it can be turned off), a button that says where it leads (**Open Claude**, **Show Memory**) and **Dismiss**. They close after 6 seconds, a little later while your pointer rests on them, never with VoiceOver on, and at most three stack up. They stay out of full-screen apps, screen sharing and recordings. It stays quiet unless something is worth it:

| Alert | When |
|---|---|
| Memory | 90% or more for a full minute; then silent until memory drops under 80% |
| Swapping hard | swap grows by more than 2 GB within 10 minutes |
| Heavy session | a Claude session uses more than a fifth of your memory (every 3 h at most) |
| Simulator | still running 10 min after Xcode closed, once per run |
| Disk | under 15 GB free, once a day |
| Your turn | a session finishes after working for more than a minute |
| Needs you | a session asks a question, a permission or a plan, plus one reminder after 10 min |

Session alerts are skipped while the tool's app is already in front of you. Memory and session alerts can each be turned off, and **Pause Alerts for 1 Hour** silences everything. These alerts do not follow Focus modes: use the pause button, or turn them off.

## How it knows

- **Memory**: `host_statistics64` (same formula as Activity Monitor), `vm.swapusage` and the kernel memory pressure level.
- **Apps**: every process of the current user, through `libproc`, grouped by the `.app` bundle it belongs to.
- **Claude Code sessions**: the status file Claude Code itself keeps for each session in `~/.claude/sessions/<pid>.json` (`busy`, `waiting`, `idle`, plus the session name). Mac Breather opens only `<pid>.json` for each running `claude` process, never the `.key` files next to them.
- **Codex threads**: task start and completion events from the logs in `~/.codex/sessions/**/*.jsonl`. These logs hold whole conversations: Mac Breather reads at most the last 4 MB of each, then only what gets appended, and decodes only short `event_msg` lines. Thread names come from `~/.codex/session_index.jsonl`. For a `codex` command-line process, its working directory is used as its label.
- **Never read**: process arguments, process environments, `~/.codex/auth.json`, any credential.

What it can change on your Mac, only when you ask (or when you turn on the matching option):
- quit an app (a normal quit, the app can still ask to save), send `SIGTERM` to a Claude session, run `xcrun simctl shutdown all`;
- set idle sessions to low priority (`PRIO_DARWIN_BG`), reset to normal when they wake, at launch and at quit;
- write `~/Library/LaunchAgents/io.github.quentinamalvy.macbreather.plist` when **Launch at login** is on.

Everything stays on your Mac. No network access, no analytics, no dependencies.

## Requirements

- macOS 14 (Sonoma) or later, Apple Silicon or Intel. Liquid Glass on macOS 26, a frosted material before.
- Xcode command line tools (`swiftc`), for building.

Claude (desktop app) and Codex (the ChatGPT app) are found wherever they are installed. Without either, the session icon stays hidden.

## Download

Grab `Mac-Breather.zip` from the [latest release](https://github.com/quentinamalvy/mac-breather/releases/latest), unzip it and move **Mac Breather** to your Applications folder.

The app is not notarized by Apple (it is a free side project), so macOS blocks the first launch. Either:
- open it once, then go to **System Settings › Privacy & Security** and click **Open Anyway**; or
- clear the download flag in Terminal: `xattr -dr com.apple.quarantine "/Applications/Mac Breather.app"`

Prefer to build it yourself? See below, it takes a minute.

## Build and run

```bash
git clone https://github.com/quentinamalvy/mac-breather.git
cd mac-breather
./build.sh
open ~/Applications/"Mac Breather.app"
```

`build.sh` compiles a universal binary (Apple Silicon and Intel) with `swiftc`, assembles `~/Applications/Mac Breather.app` and signs it ad hoc. To start it automatically, turn on **Launch at login** at the bottom of the memory panel.

## Handy flags

```bash
MB="$HOME/Applications/Mac Breather.app/Contents/MacOS/MacBreather"
"$MB" --dump               # print one sample: apps, sessions, tips
"$MB" --render ~/Desktop   # render both panels to PNG, light and dark
"$MB" --test-panels        # open both panels, log their size, quit
"$MB" --demo-toasts        # show sample alerts on screen
```

## Code

| File | Role |
|---|---|
| `Sources/Measure.swift` | memory, processes, app grouping, sessions, Claude registry |
| `Sources/States.swift` | session states, Claude rules, incremental Codex reader |
| `Sources/Model.swift` | 5 s tick, tips, actions, auto priority, notifications, launch at login |
| `Sources/Views.swift` | the two SwiftUI panels |
| `Sources/Toasts.swift` | the glass alerts and their chime |
| `Sources/App.swift` | menu bar icons, popovers, command-line flags |
| `sounds/` | the chime and the script that synthesizes it (original sound, MIT like the code) |

Before closing a session or changing its priority, Mac Breather checks again that the process is still the same one (same start time, same executable), so a reused pid is never hit.

## Notes

- The panels use the system popover, which gets Liquid Glass on macOS 26. Inside, color is kept for states only.
- "Seen" is a best guess: bringing Claude or the ChatGPT app to the front marks all its finished sessions as seen, since an app cannot tell which conversation you are reading.
- Mac and macOS are trademarks of Apple Inc. Claude and Claude Code are trademarks of Anthropic, PBC. ChatGPT and Codex are trademarks of OpenAI. This project is not affiliated with or endorsed by any of them.

## License

MIT, see [LICENSE](LICENSE).
