import Foundation

/// A tracked child process with CPU/memory stats, description, and orphan status.
struct TrackedProcess: Identifiable {
    let id: pid_t
    var pid: pid_t { id }
    let name: String
    let parentPid: pid_t
    let startTime: Date

    // Populated once on first discovery
    var processDescription: String = ""
    var isMCPServer: Bool = false
    /// Which AI CLI this process is, if any. Cached so the per-poll CLI scan
    /// never re-reads argv for a process it has already classified.
    var cliProvider: CLIProvider?
    var isPinned: Bool = false
    var lastActiveTime: Date?

    // Updated each poll cycle
    var lastCPUTime: Double = 0
    var previousCPUTime: Double = 0
    var idlePollCount: Int = 0
    var isOrphanCandidate: Bool = false
    var orphanSince: Date?
    var confirmedOrphanSince: Date?
    var memoryBytes: UInt64 = 0
    /// CPU burned since the previous sample, as a share of one core. Work
    /// spread over threads legitimately exceeds 100.
    var cpuPercent: Double = 0
    /// When `lastCPUTime` was read. The poll interval is adaptive (2s–15s), so
    /// turning a CPU-time delta into a percentage means measuring the gap
    /// rather than assuming it.
    var lastSampleTime: Date?
    /// Polls this process has been seen in. Keeps sub-poll helpers — the
    /// `bash -c` a CLI spawns for a two-second grep — out of the status bar,
    /// where they would do nothing but flicker.
    var pollCount: Int = 0

    var formattedMemory: String {
        ByteCountFormatter.string(fromByteCount: Int64(memoryBytes), countStyle: .memory)
    }

    var formattedCPU: String {
        cpuPercent >= 10
            ? "\(Int(cpuPercent.rounded()))% CPU"
            : String(format: "%.1f%% CPU", cpuPercent)
    }

    /// A command running in this shell whose cost is the user's to see.
    ///
    /// Excludes the AI CLI itself and its MCP servers: both are already
    /// represented elsewhere in the UI, and an MCP server sitting at 0% is the
    /// normal case, not news. What is left is what actually runs unnoticed —
    /// a dev server, a deploy script, a watcher, the background shell a CLI
    /// started and never mentioned again.
    var isRunningJob: Bool {
        cliProvider == nil && !isMCPServer && pollCount >= 2
    }

    var isNodeProcess: Bool {
        name == "node" || name.hasPrefix("node ")
    }

    var idleDuration: TimeInterval {
        guard let since = orphanSince else { return 0 }
        return Date().timeIntervalSince(since)
    }

    var formattedIdleTime: String {
        let seconds = Int(idleDuration)
        if seconds < 60 { return "\(seconds)s idle" }
        let minutes = seconds / 60
        return "\(minutes)m \(seconds % 60)s idle"
    }

    func autoKillCountdown(timeout: TimeInterval) -> TimeInterval {
        guard let since = confirmedOrphanSince else { return timeout }
        return max(0, timeout - Date().timeIntervalSince(since))
    }

    func formattedAutoKillCountdown(timeout: TimeInterval) -> String {
        let remaining = Int(autoKillCountdown(timeout: timeout))
        if remaining <= 0 { return "killing..." }
        if remaining < 60 { return "auto-kill in \(remaining)s" }
        return "auto-kill in \(remaining / 60)m \(remaining % 60)s"
    }
}
