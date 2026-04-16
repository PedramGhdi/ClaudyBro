# Changelog

All notable changes to ClaudyBro are documented here.

## [v1.12.0](https://github.com/PedramGhdi/ClaudyBro/releases/tag/v1.12.0) — Tab-Close Process Leak Fix & Kilo Code Support

### Bug Fixes
- **Fixed runaway CPU/memory from closed tabs leaking their entire shell + CLI trees** — `TabManager.closeTab` removed the tab from the array but never terminated the PTY. SwiftUI's NSView release timing is non-deterministic, so `ClaudyTerminalView.deinit` (and therefore SwiftTerm's cleanup) often didn't run for minutes or hours. In one observed session, closing 3 tabs over 11 hours left 5 hidden `claude` processes still running under ClaudyBro — combined ~65% CPU, fully invisible because the status bar only scans the active tab's subtree. `closeTab` now sends `SIGTERM` to the tab's full process group (`-shellPID`) and escalates to `SIGKILL` after 3 s if the shell ignores it, plus stops the tab's `ProcessMonitor` immediately so polling doesn't continue on a dying tree. `ClaudyTerminalView.deinit` also calls `terminate()` now as a safety net for any path that does reach dealloc (app quit, etc.).
- **Fixed idle-kill crashing non-Claude CLIs** — the v1.11.1 dynamic idle-kill protected only `cliPid` itself, which was safe for Claude Code (it auto-restarts killed MCPs) but broke Gemini, Codex, and Kilo — those CLIs don't auto-restart their workers, so reaping an idle child crashed the whole session. `poll()` now protects the entire subtree for non-Claude CLIs (`detectedCLI != .claude && cliOwnedPids.contains(pid)`) while keeping Claude's aggressive cleanup. MCPs under Claude are still eligible for idle-kill; everything under Gemini/Codex/Kilo rides along with the CLI.
- **Fixed wrong npx package for Gemini** — `CLIProvider.npxPackage` for Gemini was `@anthropic-ai/gemini-cli` (Anthropic doesn't publish Gemini). Corrected to `@google/gemini-cli`, so "Run via npx" actually works.

### New Features
- **Kilo Code CLI support** — added `kilo` as a first-class `CLIProvider` alongside Claude, Gemini, and Codex. Includes binary path discovery (`/usr/local/bin/kilo`, Homebrew, npm-global), npx fallback via `@kilocode/cli`, orange accent color, and bolt icon. Kilo path is user-configurable in Settings and persisted to `config.json`.

### Internal
- `TabManager.closeTab` is now the single chokepoint for tab teardown: stop monitor → kill process group → remove from array. The `tabs.count > 1` guard is preserved so the last tab still quits the app via `requestCloseTab` rather than leaving the window empty.
- `ClaudyTerminalView.deinit` guards `terminate()` on `process?.shellPid ?? 0 > 0` to avoid touching SwiftTerm internals on a view that never finished `makeNSView` (unlikely, but cheap insurance).
- `ProcessMonitor.poll()`'s protection predicate replaces the old `isCliItself` boolean with `isProtected`, with the CLI-type gate inline so future CLIs (Codex, Kilo) get correct behavior by default.

## [v1.11.1](https://github.com/PedramGhdi/ClaudyBro/releases/tag/v1.11.1) — Dynamic In-Subtree Process Cleanup

### Bug Fixes
- **Fixed runaway child-process accumulation while a CLI is running** — sessions were observed hitting 60, 73, 87+ descendants (duplicate "Claude Code" workers at ~1 MB, leaked `node` processes at 200 MB–1 GB, `head`/`npm` one-shots from bash-tool pipelines, Task subagent helpers). `ProcessMonitor.poll()` previously skipped all CPU tracking for non-MCP processes *inside* the active CLI's subtree, so nothing short of the CLI exiting would reap them. The inner loop now tracks CPU for every descendant except `cliPid` itself, and any non-pinned child idle past `mcpIdleTimeout` gets SIGTERM immediately (SIGKILL 3s later if it ignores). Kills are safe: MCP servers auto-restart on the next tool call, and `head`/`npm`/subagent helpers are already finished by the time they hit this path.
- **Fixed in-subtree leaks being invisible in the orphan panel** — the bottom-right orphan badge used to gate on `!cliOwnedPids.contains(pid)`, so the very processes causing the runaway count never showed up in the UI. Users had no way to tell why the child-process count was climbing. Orphan detection now surfaces all non-MCP descendants (in and out of subtree) with the existing idle countdown; MCPs are still excluded so the panel doesn't drown in normal idle servers.

### Internal
- The active CLI process (`cliPid`) is now the only protected entry in the loop — every other descendant runs through the CPU-delta idle check. The protection is tight enough that SwiftUI views, the shell, and pinned processes are unaffected.
- CPU tracking now runs for ~every descendant per poll instead of only MCPs + out-of-tree orphans. `proc_pidinfo` is cheap (<1 ms/call), so even ~60 descendants on a 2 s poll interval stays well under the existing performance budget.

## [v1.11.0](https://github.com/PedramGhdi/ClaudyBro/releases/tag/v1.11.0) — Process Cleanup Overhaul & Main-Thread Crash Fix

### Bug Fixes
- **Fixed system-level hang / restart under heavy process load** — `TerminalTab.runningCLI` was a computed property that called `ProcessTreeQuery.getDescendantProcesses()` (full `KERN_PROC_ALL` sysctl scan) on the **main thread** every time SwiftUI re-evaluated the view body. With ~60 descendants, every published change in any monitor triggered a fresh scan, saturating the main thread and eventually taking the whole system down. `runningCLI` now reads a cached `@Published` value (`ProcessMonitor.activeCLI`) that the background poll updates — zero sysctl calls during view rendering. `LaunchToolbar` lost its dead `hasRunningCLI` parameter since it was declared but never read.
- **Fixed leaked non-MCP descendants after CLI exit** — when Claude/Gemini exited, the child-process popover kept growing unbounded (32 → 37 → 46 processes observed in a single session). The grace-period cleanup only killed processes flagged `isMCPServer`, and orphan detection only ran on processes flagged `isNodeProcess`. `npm`, `head`, shell helpers, and non-node descendants of the CLI had no cleanup path at all. Now tracks the full CLI subtree via iterative BFS (previously 2 levels deep), accumulates it across polls in `cliSubtreeSnapshot`, and on CLI exit kills every pid in the snapshot that's still alive and not pinned — regardless of type. Orphan detection is no longer restricted to node processes either.
- **Fixed "kill idle MCP after 0s" being treated as "disabled"** — the `mcpIdleTimeout > 0` and `autoKillTimeout > 0` guards made 0 mean "feature off" instead of "kill immediately". Both guards removed. 0s now means "kill on the first poll where the target is idle", with an `isIdleNow` check (`previousCPUTime > 0 && cpuDelta < 0.01`) so freshly spawned or actively working processes get a one-poll grace period.
- **Fixed MCP idle-kill being vetoed while a CLI was running** — an overly conservative `!cliStillRunning` guard blocked the user-configured idle timeout whenever any CLI was active. Setting "Kill idle MCPs after: 30s" did nothing if Claude was running. The guard is gone — the existing `isIdleNow` check already protects actively working MCPs (any CPU activity bumps `lastActiveTime` and resets the idle counter), and Claude Code / Gemini auto-restart MCPs on demand so killing idle ones between tool calls is safe.
- **Fixed duplicate MCP leak when bouncing the CLI within the 15s grace period** — exiting Claude scheduled cleanup, restarting Claude cancelled it, and the old MCPs (now reparented under the shell, unreachable from the new CLI pid) leaked because the snapshot was reset to just the new CLI's subtree. The snapshot is now preserved across CLI restarts, so stragglers from the previous run get reaped on the next exit.
- **Fixed npm/npx wrappers looking like duplicate MCP entries in the popover** — `npm exec shadcn@latest mcp` creates both a wrapper process and the actual node MCP process; both carry `"shadcn"` in their args, so `describeProcess()` labelled both as "Shadcn UI MCP Server". They looked like duplicates and killing one killed the other (SIGTERM propagated through the process group). `describeProcess()` now detects npm/npx/yarn/bun/pnpm wrappers via `args[0]` basename and suffixes the label with ` (wrapper)`.

### Improvements
- **Settings helper captions** — the Process Monitor section now explains the 0s semantics under "Auto-kill orphans after" and "Kill idle MCP servers after", so the behavior is visible without reading the source.
- **Grace-period cleanup gated on the snapshot, not on `updated`** — if the CLI's descendants already died by the time the grace period fires, the cleanup still runs against the accumulated snapshot, catching anything that briefly existed but isn't in the current poll's tracked list.

### Internal
- Iterative BFS for `cliOwnedPids` runs as a pure in-memory loop over the already-fetched `descendants` array — no extra sysctl calls, microseconds of work even on large subtrees.
- `ProcessMonitor.poll()` still runs entirely on `DispatchQueue.global(qos: .utility)` with exactly one brief `DispatchQueue.main.sync` to snapshot the tracked cache (<1ms), plus a fire-and-forget `DispatchQueue.main.async` to publish updates. No new main-thread blocking introduced.

## [v1.10.0](https://github.com/PedramGhdi/ClaudyBro/releases/tag/v1.10.0) — Gemini CLI Support, OSC Leak Fix & Tab Reordering

### New Features
- **Tab drag-to-reorder** — drag tabs left or right to rearrange them, with a visual drop indicator highlighting the target slot and a smooth reorder animation.
- **Kill running CLI before launching another** — switching CLIs via the toolbar dropdown now SIGTERM-kills the currently running CLI, waits up to 5 seconds for it to exit, then launches the new one. No more stacking Claude on top of Gemini.
- **Cmd+V image paste for all CLIs** — when the clipboard contains an image but no text, Cmd+V now sends Ctrl+V so the CLI (Gemini, Claude, etc.) can handle the paste via its own clipboard detection.
- **ANSI palette tuned for dark theme** — installed a 16-color ANSI palette where color 0 (black) matches the dark navy background (#1a1a2e), eliminating visible bands in CLI UI blocks, code areas, and status bars.
- **COLORFGBG environment variable** — CLIs now receive `COLORFGBG=15;0` as a dark-mode hint, so tools that don't issue OSC 10/11 color queries still render their dark theme correctly.

### Bug Fixes
- **Fixed OSC color query responses leaking into the shell** — terminal responses like `rgb:1a1c/1a1c/2e14` and `command not found: 11` were appearing as plaintext in the shell prompt.
  - Root cause 1: SwiftTerm's async `DispatchIO.write` on the PTY fd raced with its own read loop on the same fd. Overridden with synchronous `Darwin.write` on a dup'd fd to serialize I/O, matching Ghostty's model.
  - Root cause 2: Some OSC 4/10/11/12 color query responses still leaked despite sync writes. Added `OSCResponseFilter` to suppress only those specific codes while letting DA, cursor position, DCS, clipboard, and title reports pass through so CLI tools still get proper terminal capability detection.
- **Fixed orphan killer breaking Gemini CLI** — Gemini spawns child Node processes that appear idle and were being auto-killed after 30 seconds, producing `read EIO` crashes. The process monitor now builds a set of PIDs owned by the active CLI's subtree (CLI + children + grandchildren) and exempts them from orphan detection, while still cleaning up unrelated Node processes outside the CLI tree.
- **Fixed context status bar showing stale Claude data for other CLIs** — model name, effort level, and session cost now only display during Claude sessions and clear when Gemini or Codex is running.

### Improvements
- **MCP idle kill still runs while CLI is active** — only orphan detection respects the CLI subtree protection; MCP servers are still killed after their idle timeout regardless of which CLI owns them, since Claude Code restarts them on demand.
- **Active CLI detection rewritten** — the process monitor now identifies the active CLI by walking the descendant tree and matching against `CLIProvider.processKeyword`, replacing the previous string scan over the updated tracked list.

## [v1.9.1](https://github.com/PedramGhdi/ClaudyBro/releases/tag/v1.9.1) — Pin Processes & UI Fixes

### New Features
- **Pin processes** — pinned processes are immune to auto-kill and MCP idle cleanup. Pin state persists across tabs and app restarts via config file.
- **Pin button in process inspector** — toggle pin/unpin per process with a pin icon; pinned processes show a yellow "PINNED" badge.
- **Editable stepper fields in Settings** — process monitor timeout fields now have a text input alongside the stepper for direct numeric entry.

### Bug Fixes
- **Fixed toolbar Run button hit area** — clicking on the icon or padding area of the primary Run button now works; previously only the text label was clickable.

## [v1.9.0](https://github.com/PedramGhdi/ClaudyBro/releases/tag/v1.9.0) — Context Usage Status Bar

### New Features
- **Live context usage in status bar** — shows context window usage percentage, model name, session cost, effort level, and bypass mode indicator directly in ClaudyBro's bottom status bar
- **StatusLine bridge** — auto-configures Claude Code's `statusLine` setting to pipe session data to a temp JSON file that ClaudyBro reads
- **Effort level display** — reads effort from Claude Code settings (project and global) with terminal buffer scanning as override for session-level `/effort` changes
- **Color-coded context percentage** — green under 60%, orange 60-80%, red above 80%
- **Model badge** — compact display of current model (e.g., "Opus 4.6")
- **Mode indicator** — shows "bypass" badge when dangerous permissions mode is active

### Improvements
- **Context-aware polling** — JSON file only re-read when modification date changes, avoiding unnecessary disk I/O
- **Merge-based context updates** — terminal-scanned effort/mode values preserved when JSON file updates, preventing data loss

## [v1.8.0](https://github.com/PedramGhdi/ClaudyBro/releases/tag/v1.8.0) — Full Scrollback History

### New Features
- **Full scrollback in Claude sessions** — disabled alternate screen buffer by default so all Claude Code output stays in the main scrollback buffer. Previous messages no longer disappear when new output arrives.
- **Alt-screen byte filter** — new `AltScreenFilter` strips DEC private modes 47/1047/1049 from the PTY stream with support for split-sequence handling and combined parameters.
- **Settings toggle** — "Full scrollback (disable alternate screen)" option in Settings under Terminal section.
- **Configurable via JSON** — `disableAltScreen` key in `~/.config/claudybro/config.json` (default: `true`).

## [v1.7.0](https://github.com/PedramGhdi/ClaudyBro/releases/tag/v1.7.0) — Kill Idle MCP Servers

### Breaking Changes
- **Removed MCP standby mode** — `SIGSTOP`/`SIGCONT` standby replaced with simple idle kill. The standby feature consumed significant CPU (1-second pulse timer waking all frozen servers constantly) while only saving CPU, not memory. Idle MCP servers are now killed after 90 seconds — Claude Code auto-restarts them on demand.
- Config key `mcpStandbyEnabled` and `mcpStandbyIdleSeconds` replaced with `mcpIdleKillSeconds`

### Improvements
- **Adaptive poll interval** — process monitor now polls every 2s when CLI is active, 5s normally, and slows to 15s after 30 seconds of full idle. Reduces process table scans from 12/min to 4/min when idle.
- **Fixed potential deadlock** — removed `DispatchQueue.main.sync` call from background thread in MCP cleanup path
- **Reduced resource overhead** — eliminated ~100 lines of standby complexity (pulse timer, wake/refreeze logic, CLI CPU tracking, SIGSTOP/SIGCONT signals)

## [v1.6.1](https://github.com/PedramGhdi/ClaudyBro/releases/tag/v1.6.1) — Fix Directory Persistence

### Bug Fixes
- **Fixed working directory not remembered on app restart** — `saveWorkingDirectory()` was scanning all child processes of the app instead of the active tab's own shell PID, often saving the wrong directory or failing entirely at quit time
- **Fixed new tabs starting in stale directory** — new tabs read `lastWorkingDirectory` from UserDefaults which was only written at the last app quit. New tabs now inherit the active tab's live working directory
- **Fixed `lastWorkingDirectory` going stale** — the active tab's cwd is now persisted to UserDefaults every 2 seconds via the existing window title timer, so the saved directory is always current

## [v1.6.0](https://github.com/PedramGhdi/ClaudyBro/releases/tag/v1.6.0) — MCP Server Stability & Standby Mode

### Bug Fixes
- **Fixed MCP servers being incorrectly killed** — duplicate detection was grouping all unrecognized MCP servers under the generic "MCP Server" label and killing all but the newest. Removed the duplicate-killing logic entirely; Claude Code manages its own MCP lifecycle.
- **Fixed Brave Search, Playwright, Shadcn, Context7 triggering orphan detection** — `isMCPServer()` now recognizes all known server patterns, aligned with the UI labels in `describeProcess()`. Previously these servers could be flagged as orphans and auto-killed.
- **Fixed MCP servers killed instantly on Claude exit** — added a 15-second grace period before killing MCP servers when the CLI disappears, allowing Claude to restart without losing its MCP connections.
- **Fixed Settings not opening** — `Settings…` menu item and Cmd+, were posting a notification that nobody was listening to. MainWindow now subscribes and opens the sheet correctly.
- **Fixed settings changes not applying to running monitors** — all process monitor settings (timeouts, intervals, standby) now propagate live to every tab's monitor when you click Done, without needing to restart.

### New Features
- **MCP Standby Mode** — idle MCP servers are suspended with `SIGSTOP` after 90 seconds of inactivity. macOS aggressively compresses their memory while frozen. A 1-second pulse timer briefly wakes each standby server to check for pending requests (≤1s latency overhead). Servers resume automatically when Claude calls them.
- **Standby UI** — suspended servers show an orange `STANDBY` badge and moon icon instead of the green `MCP` badge.
- **Live settings propagation** — changing any process monitor setting in Settings → Done instantly applies to all running tabs.

### Changes
- Auto-kill orphan timeout reduced from 120s → 90s
- MCP standby idle threshold defaults to 90s (configurable in Settings)
- Improved MCP server descriptions: `@scope/mcp-server-github` now shows as "Github MCP Server" instead of generic "MCP Server"

## [v1.5.1](https://github.com/PedramGhdi/ClaudyBro/releases/tag/v1.5.1) — Fix Cmd+Click URL Opening

### Bug Fixes
- Fixed Cmd+Click on terminal links failing with macOS error -50 ("The application can't be opened")
  - Root cause: SwiftTerm's implicit link detection returns bare hostnames like `github.com/user/repo` without a scheme, causing `URL(string:)` to parse the hostname as the URL scheme
  - Added a delegate proxy that prepends `https://` to scheme-less URLs before opening
  - URLs with existing schemes (`https://`, `mailto:`, `tel:`, etc.) pass through unchanged

## [v1.5.0](https://github.com/PedramGhdi/ClaudyBro/releases/tag/v1.5.0) — Remember CLI Selection

### New Features
- **Persistent CLI preference** — The split-button toolbar now remembers your last-used CLI and launch mode across app restarts
- **Dangerous mode persistence** — If you select "Skip Permissions" or "Full Auto", it becomes the default on next launch
- **Visual indicator** — Primary button shows a bolt icon when dangerous mode is the saved default

### How It Works
- Selecting any option from the dropdown saves it as the new default in `~/.config/claudybro/config.json`
- Two new config keys: `preferredCLI` (provider name) and `preferredDangerousMode` (boolean)
- Falls back to first detected CLI if the preferred one is no longer available

## [v1.4.0](https://github.com/PedramGhdi/ClaudyBro/releases/tag/v1.4.0) — Multi-CLI Support

### New Features
- **Multi-CLI support** — ClaudyBro now supports Claude, Gemini CLI, and OpenAI Codex CLI as first-class citizens
- **Auto-detection** — All installed AI CLIs are discovered at startup by scanning known paths and `$PATH`
- **Split-button launcher** — Compact VS Code-style toolbar button: one-click to run the default CLI, dropdown chevron for all options including dangerous-mode variants (Skip Permissions, Full Auto)
- **npx fallback** — CLIs not installed globally can be launched via npx when available
- **Per-CLI branding** — Each CLI gets its own icon and color in the process inspector and status bar (Claude = brain/blue, Gemini = sparkles/blue, Codex = terminal/green)
- **Extensible architecture** — Adding a new CLI requires only adding one enum case to `CLIProvider.swift`

### Improvements
- **Always-confirm dialogs** — Tab close (Cmd+W), last-tab close, and app quit (Cmd+Q) now always show a confirmation dialog to prevent accidental closure, regardless of whether a CLI is running
- **Dynamic confirmation messages** — Dialogs show the specific CLI name when one is running (e.g., "Claude is running. Closing will terminate the session.")
- **Multi-CLI settings** — Settings panel now shows binary path overrides for all supported CLIs
- **Generic process monitoring** — Process monitor detects exit of any supported CLI and cleans up MCP servers accordingly

### Architecture
- Renamed `ClaudeProcessManager` to `CLIProcessManager` with multi-provider discovery
- New `CLIProvider` enum centralizes all CLI-specific data (binary names, search paths, commands, colors, icons)
- Configuration backward compatible — existing `claudePath` setting preserved, new `geminiPath`/`codexPath` default to "auto"

## [v1.3.0](https://github.com/PedramGhdi/ClaudyBro/releases/tag/v1.3.0) — Kitty Keyboard, Scroll & Selection Fixes

### Bug Fixes
- Fixed arrow keys producing raw escape sequences (`[57420u`) inside Claude Code's TUI (e.g., `/resume` session picker, search dialogs)
  - Root cause: macOS marks regular arrow keys with `.numericPad` flag, causing SwiftTerm to encode them as keypad variants instead of standard arrows
- Fixed arrow keys showing raw escape sequences after exiting Claude Code with Ctrl+C
  - Terminal now resets Kitty keyboard protocol, bracketed paste mode, and application cursor mode on Claude exit
- Fixed terminal auto-scrolling to bottom when new output arrives while user is reading scrollback
  - Terminal now preserves scroll position when user has scrolled up, matching Ghostty's behavior
  - Scroll bar no longer flickers when output streams in while scrolled up
- Fixed text selection being cleared when Claude sends new output — you can now highlight text while Claude is responding
- Fixed double-click drag selection dropping the original word when dragging backward
- Double-click word selection now includes `@`, `+`, `~` characters — selecting emails like `user@example.com` works with a single double-click

## [v1.2.1](https://github.com/PedramGhdi/ClaudyBro/releases/tag/v1.2.1) — Fix Arrow Keys After Ctrl+C

### Bug Fixes
- Fixed arrow keys showing raw escape sequences (`[57420u[57419u`) after exiting Claude Code with Ctrl+C
- Terminal now automatically resets Kitty keyboard protocol, bracketed paste mode, and application cursor mode when Claude exits unexpectedly
- Fix applies per-tab — background tabs with Claude running are also cleaned up correctly

## [v1.2.0](https://github.com/PedramGhdi/ClaudyBro/releases/tag/v1.2.0) — Auto-Kill Orphaned Processes

### New Features
- Orphaned processes are now automatically killed after 2 minutes of confirmed orphan status
- Countdown timer displayed in the status bar orphan badge (e.g., "auto-kill 1m 23s")
- Per-process countdown in the orphan detail panel with color progression (normal → orange → red)
- Configurable auto-kill timeout via Settings or `~/.config/claudybro/config.json` (`autoKillTimeoutSeconds`, default 120s, set to 0 to disable)

### Improvements
- Replaced boolean `autoCleanOrphans` toggle with smarter timed auto-kill approach
- Orphan detail panel now shows auto-kill policy info in header
- Settings panel shows auto-kill timeout stepper (0–600s range)

## [v1.1.0](https://github.com/PedramGhdi/ClaudyBro/releases/tag/v1.1.0) — Tab System Overhaul

### New Features
- Redesigned tab bar matching Terminal.app style — full-width tabs showing current directory path
- ⌘1..9 shortcuts for direct tab selection with labels on each tab
- Auto-focus terminal on new tab creation — no need to click before typing
- Last-tab close confirmation dialog (⌘W on single tab)
- Reactive directory path updates in tab titles, toolbar, and window title

### Bug Fixes
- Fixed ⌘Arrow Left/Right (Home/End) broken after creating new tabs
- Fixed ⌘W closing entire app instead of just the active tab
- Fixed CWD tracking showing wrong directory — now uses SwiftTerm shellPid for reliable per-tab paths
- Fixed tab click area — entire tab button is now clickable, not just text
- Fixed toolbar path not updating when changing directories

### Improvements
- Tab hover states with subtle background feedback
- Smooth tab transition animations
- Rounded pill active tab indicator
- Close button with proper hit target on hover/active tabs
- Tab separators for visual clarity

## [v1.0.0](https://github.com/PedramGhdi/ClaudyBro/releases/tag/v1.0.0) — Initial Release

- Native Swift macOS terminal for Claude Code
- Image paste support (Cmd+V clipboard images)
- File drag-and-drop path injection
- Multi-tab terminal sessions
- Process inspector with MCP server badges
- Orphaned process detection and cleanup
- Smart MCP server lifecycle management
- Dark theme matching Claude Code aesthetic
- Settings panel (font size, Claude path, orphan timeout)
- Directory persistence across restarts
- Update checker via GitHub Releases
