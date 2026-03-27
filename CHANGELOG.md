# Changelog

All notable changes to ClaudyBro are documented here.

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
