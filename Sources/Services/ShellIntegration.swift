import AppKit
import Foundation

/// Installs the shell hooks that make OSC 133 prompt marks available.
///
/// Prompt navigation and command decoration need the *shell* to announce where
/// prompts and commands begin; no terminal can infer it. This writes a script
/// into the app's own config directory and adds a single `source` line to the
/// user's rc file — never more, and only when they explicitly ask for it.
enum ShellIntegration {

    enum Shell: String, CaseIterable {
        case zsh, bash

        var rcFile: URL {
            let home = FileManager.default.homeDirectoryForCurrentUser
            switch self {
            case .zsh: return home.appendingPathComponent(".zshrc")
            case .bash: return home.appendingPathComponent(".bashrc")
            }
        }

        var scriptName: String { "shell-integration.\(rawValue)" }
    }

    /// The shell the user actually runs, inferred from $SHELL.
    static var current: Shell? {
        let name = URL(fileURLWithPath: Constants.defaultShell).lastPathComponent
        return Shell(rawValue: name)
    }

    static func scriptURL(for shell: Shell) -> URL {
        Constants.configDirectory.appendingPathComponent(shell.scriptName)
    }

    static func sourceLine(for shell: Shell) -> String {
        "[ -f \"\(scriptURL(for: shell).path)\" ] && . \"\(scriptURL(for: shell).path)\""
    }

    /// True when the rc file already sources our script.
    static func isInstalled(for shell: Shell) -> Bool {
        guard let contents = try? String(contentsOf: shell.rcFile, encoding: .utf8) else {
            return false
        }
        return contents.contains(shell.scriptName)
    }

    /// Write the script and append the source line if it isn't there yet.
    ///
    /// Appending is idempotent — guarded on the script name already appearing
    /// in the file — so running it twice can't leave duplicate lines behind.
    static func install(for shell: Shell) throws {
        try script(for: shell).write(
            to: scriptURL(for: shell), atomically: true, encoding: .utf8
        )
        guard !isInstalled(for: shell) else { return }

        let existing = (try? String(contentsOf: shell.rcFile, encoding: .utf8)) ?? ""
        let separator = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
        let addition = """
        \(separator)
        # ClaudyBro shell integration (prompt marks for ⌘↑ / ⌘↓ navigation)
        \(sourceLine(for: shell))

        """
        try (existing + addition).write(
            to: shell.rcFile, atomically: true, encoding: .utf8
        )
    }

    // MARK: - Scripts

    /// Emits OSC 133 A/B/C/D around the prompt and each command.
    ///
    /// `A` opens a prompt, `B` marks where user input starts, `C` marks the
    /// command output, and `D` reports the exit status — the sequence every
    /// OSC 133-aware terminal expects.
    static func script(for shell: Shell) -> String {
        switch shell {
        case .zsh:
            return """
            # ClaudyBro shell integration — OSC 133 semantic prompts.
            # Generated automatically; edits will be overwritten on reinstall.

            __claudybro_preexec() { printf '\\033]133;C\\007' }
            __claudybro_precmd()  { printf '\\033]133;D;%s\\007' "$?" }

            autoload -Uz add-zsh-hook 2>/dev/null || return
            add-zsh-hook precmd __claudybro_precmd
            add-zsh-hook preexec __claudybro_preexec

            # The marks are embedded as literal bytes via $'...', which zsh
            # expands at assignment. Using $(...) instead would need
            # PROMPT_SUBST, and turning that on globally would change how the
            # user's own PS1 is interpreted — a good way to break their prompt.
            # %{...%} keeps the sequences out of the prompt's width calculation.
            PS1=$'%{\\e]133;A\\a%}'"$PS1"$'%{\\e]133;B\\a%}'

            """
        case .bash:
            return """
            # ClaudyBro shell integration — OSC 133 semantic prompts.
            # Generated automatically; edits will be overwritten on reinstall.

            __claudybro_precmd() {
                local status=$?
                printf '\\033]133;D;%s\\007' "$status"
                printf '\\033]133;A\\007'
            }
            PROMPT_COMMAND="__claudybro_precmd${PROMPT_COMMAND:+;$PROMPT_COMMAND}"

            PS1='\\[\\033]133;A\\007\\]'"$PS1"'\\[\\033]133;B\\007\\]'
            trap 'printf "\\033]133;C\\007"' DEBUG

            """
        }
    }
}
