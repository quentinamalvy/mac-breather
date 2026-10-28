# Mac Breather

**Give your Mac a breather.** A tiny menu bar app for macOS 26 that shows, at a glance, how much memory your Mac has left and what your AI coding sessions (Claude Code, Codex) are doing.

Built for 8 GB Macs that start swapping the moment you run Claude, Codex, a browser and a simulator side by side.

## What it does

Mac Breather adds two icons to the menu bar.

**The memory ring.** Green, orange or red, with the share of memory in use. Click it to see:
- memory used, swap and free disk space;
- *Give your Mac a breather*: concrete tips with a button, such as shutting down a Simulator left running without Xcode, closing idle AI sessions, quitting heavy apps sitting in the background, or restarting when swap gets large;
- the six heaviest apps, with a bar each (hover to quit one).

**The session dots.** One dot per Claude Code or Codex session:

| Dot | State | Meaning |
|---|---|---|
| blue, breathing | Working | the agent is working right now |
| orange | Needs you | a question, a permission or a plan is waiting for you |
| green | Your turn | finished, waiting for your next message |
| grey circle | Idle | done for more than 30 min with nothing running; it still holds memory and can be closed |

Click it to see every session with its title, its state and since when, and its memory. Click a row to jump to the app. You can get a notification when a session finishes or needs you.

Idle sessions can be put in low priority automatically (`PRIO_DARWIN_BG`). They go back to normal as soon as they start working again.

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

- macOS 26 (Tahoe) or later
- Xcode command line tools (`swiftc`), for building

Claude Code (desktop app) and Codex (inside the ChatGPT app) are detected in their default locations under `/Applications`.

## Build and run

```bash
git clone https://github.com/quentinamalvy/mac-breather.git
cd mac-breather
./build.sh
open ~/Applications/"Mac Breather.app"
```

`build.sh` compiles the sources with `swiftc`, assembles `~/Applications/Mac Breather.app` and signs it ad hoc. To start it automatically, turn on **Launch at login** at the bottom of the memory panel.

## Handy flags

```bash
MB="$HOME/Applications/Mac Breather.app/Contents/MacOS/MacBreather"
"$MB" --dump               # print one sample: apps, sessions, tips
"$MB" --render ~/Desktop   # render both panels to PNG, light and dark
"$MB" --test-panels        # open both panels, log their size, quit
```

## Code

| File | Role |
|---|---|
| `Sources/Measure.swift` | memory, processes, app grouping, sessions, Claude registry |
| `Sources/States.swift` | the four session states, Claude rules, incremental Codex reader |
| `Sources/Model.swift` | 5 s tick, tips, actions, auto priority, notifications, launch at login |
| `Sources/Views.swift` | the two SwiftUI panels |
| `Sources/App.swift` | menu bar icons, popovers, command-line flags |

Before closing a session or changing its priority, Mac Breather checks again that the process is still the same one (same start time, same executable), so a reused pid is never hit.

## Notes

- The panels use the system popover, which gets Liquid Glass on macOS 26. Inside, color is kept for states only.
- Mac and macOS are trademarks of Apple Inc. Claude and Claude Code are trademarks of Anthropic, PBC. ChatGPT and Codex are trademarks of OpenAI. This project is not affiliated with or endorsed by any of them.

## License

MIT, see [LICENSE](LICENSE).
