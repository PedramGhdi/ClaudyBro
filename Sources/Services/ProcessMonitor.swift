import Combine
import Foundation

/// Monitors the child process tree of the shell process.
/// Detects truly orphaned node processes while excluding legitimate MCP servers.
/// Idle MCP servers are killed after a configurable timeout — Claude Code auto-restarts them.
final class ProcessMonitor: ObservableObject {
    @Published var childProcesses: [TrackedProcess] = []
    @Published var orphanedProcesses: [TrackedProcess] = []
    @Published var currentDirectory: String = ""
    @Published var contextUsage: ContextUsage = ContextUsage()

    var monitorInterval: TimeInterval = 5
    var orphanTimeout: TimeInterval = 30
    var autoKillTimeout: TimeInterval = 90
    var mcpIdleTimeout: TimeInterval = 90

    var hasActiveProcesses: Bool { !childProcesses.isEmpty }

    private var timer: Timer?
    private var shellPID: pid_t = 0
    private var lastContextFileDate: Date?
    private var cliWasRunning: Bool = false
    private var mcpCleanupWorkItem: DispatchWorkItem?
    private var cliExitGracePeriod: TimeInterval = 15
    private var idlePollStreak: Int = 0
    private var activeInterval: TimeInterval = 0
    private var cancellables = Set<AnyCancellable>()

    init() {
        NotificationCenter.default.publisher(for: .killOrphanProcesses)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.cleanupOrphans() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .configurationChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyConfiguration() }
            .store(in: &cancellables)
    }

    deinit { stopMonitoring() }

    func startMonitoring(shellPID pid: pid_t) {
        shellPID = pid
        timer?.invalidate()
        activeInterval = monitorInterval
        idlePollStreak = 0
        // Poll on background queue to avoid main-thread memory pressure
        timer = Timer.scheduledTimer(
            withTimeInterval: monitorInterval, repeats: true
        ) { [weak self] _ in
            DispatchQueue.global(qos: .utility).async { self?.poll() }
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in self?.poll() }
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        mcpCleanupWorkItem?.cancel()
        mcpCleanupWorkItem = nil
        childProcesses = []
        orphanedProcesses = []
    }

    /// Kill a single orphaned process by PID.
    func killProcess(_ pid: pid_t) {
        kill(pid, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if ProcessTreeQuery.isProcessAlive(pid) { kill(pid, SIGKILL) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.poll()
        }
    }

    /// Toggle pin state for a process by PID. Pinned processes are immune to auto-kill.
    func togglePin(for pid: pid_t) {
        guard let index = childProcesses.firstIndex(where: { $0.pid == pid }) else { return }
        childProcesses[index].isPinned.toggle()

        let description = childProcesses[index].processDescription
        let config = AppConfiguration.shared
        if childProcesses[index].isPinned {
            if !config.pinnedProcessDescriptions.contains(description) {
                config.pinnedProcessDescriptions.append(description)
            }
        } else {
            config.pinnedProcessDescriptions.removeAll { $0 == description }
        }
        config.save()
        NotificationCenter.default.post(name: .configurationChanged, object: nil)
    }

    /// Kill all confirmed orphaned processes.
    func cleanupOrphans() {
        let pids = orphanedProcesses.map(\.pid)
        guard !pids.isEmpty else { return }

        for pid in pids { kill(pid, SIGTERM) }

        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            for pid in pids {
                if ProcessTreeQuery.isProcessAlive(pid) { kill(pid, SIGKILL) }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.poll()
        }
    }

    /// Update context usage, merging new data with existing.
    /// Terminal-scanned fields (mode, effort) are preserved unless the new value provides them.
    func updateContextUsage(_ usage: ContextUsage) {
        var merged = usage
        // Preserve terminal-scanned mode/effort if the new source doesn't provide them
        if merged.modeIndicator == nil { merged.modeIndicator = contextUsage.modeIndicator }
        if merged.effort == nil { merged.effort = contextUsage.effort }
        guard merged != contextUsage else { return }
        contextUsage = merged
    }

    /// Clear context usage (e.g., when CLI exits).
    func clearContextUsage() {
        guard !contextUsage.isEmpty else { return }
        contextUsage = ContextUsage()
    }

    /// Re-read settings from AppConfiguration and apply to this monitor.
    func applyConfiguration() {
        let config = AppConfiguration.shared
        monitorInterval = TimeInterval(config.processMonitorInterval)
        orphanTimeout = TimeInterval(config.orphanTimeoutSeconds)
        autoKillTimeout = TimeInterval(config.autoKillTimeoutSeconds)
        mcpIdleTimeout = TimeInterval(config.mcpIdleKillSeconds)

        // Sync pin states from config (cross-tab consistency)
        let pinnedDescriptions = config.pinnedProcessDescriptions
        for i in childProcesses.indices {
            childProcesses[i].isPinned = pinnedDescriptions.contains(childProcesses[i].processDescription)
        }

        // Re-schedule poll timer if interval changed
        if let existingTimer = timer, existingTimer.timeInterval != monitorInterval {
            existingTimer.invalidate()
            timer = Timer.scheduledTimer(
                withTimeInterval: monitorInterval, repeats: true
            ) { [weak self] _ in
                DispatchQueue.global(qos: .utility).async { self?.poll() }
            }
        }
    }

    // MARK: - Private

    private func poll() {
        guard shellPID > 0 else { return }

        let descendants = ProcessTreeQuery.getDescendantProcesses(of: shellPID)
        var updated: [TrackedProcess] = []
        var orphans: [TrackedProcess] = []
        var mcpKilled: [pid_t] = []

        // Find the active CLI and build a set of PIDs in its subtree.
        // Only these are protected from orphan/MCP killing — other node
        // processes outside the CLI's tree are still cleaned up normally.
        let cliKeywords = CLIProvider.allCases.map(\.processKeyword)
        var activeCLI: CLIProvider?
        var cliPid: pid_t = 0
        for provider in CLIProvider.allCases {
            let keyword = provider.processKeyword
            for entry in descendants {
                let desc = (childProcesses.first(where: { $0.pid == entry.pid })?.processDescription
                    ?? ProcessTreeQuery.describeProcess(pid: entry.pid)).lowercased()
                if desc.contains(keyword) {
                    activeCLI = provider
                    cliPid = entry.pid
                    break
                }
            }
            if activeCLI != nil { break }
        }
        let cliStillRunning = activeCLI != nil

        // Build set of PIDs owned by the CLI (the CLI itself + its descendants)
        var cliOwnedPids = Set<pid_t>()
        if cliPid > 0 {
            cliOwnedPids.insert(cliPid)
            for entry in descendants where entry.parentPid == cliPid {
                cliOwnedPids.insert(entry.pid)
            }
            // Also include grandchildren (CLI → child → grandchild)
            for entry in descendants where cliOwnedPids.contains(entry.parentPid) {
                cliOwnedPids.insert(entry.pid)
            }
        }

        for entry in descendants {
            // Reuse existing tracked entry or create new
            var tracked = childProcesses.first(where: { $0.pid == entry.pid })
                ?? createTrackedProcess(from: entry)

            tracked.memoryBytes = ProcessTreeQuery.getProcessMemory(pid: entry.pid)

            if tracked.isMCPServer {
                // MCP idle kill: track CPU to detect idle servers, kill after timeout
                // Skip when a CLI is running — it manages its own MCP lifecycle
                let cpuTime = ProcessTreeQuery.getProcessCPUTime(pid: entry.pid)
                tracked.previousCPUTime = tracked.lastCPUTime
                tracked.lastCPUTime = cpuTime

                let cpuDelta = tracked.lastCPUTime - tracked.previousCPUTime
                if cpuDelta > 0.01 || tracked.previousCPUTime == 0 {
                    tracked.lastActiveTime = Date()
                }

                if !cliOwnedPids.contains(entry.pid),
                   !tracked.isPinned,
                   mcpIdleTimeout > 0,
                   let lastActive = tracked.lastActiveTime,
                   Date().timeIntervalSince(lastActive) >= mcpIdleTimeout
                {
                    kill(entry.pid, SIGTERM)
                    mcpKilled.append(entry.pid)
                    continue // don't add to updated
                }
            } else if !cliOwnedPids.contains(entry.pid), tracked.isNodeProcess {
                // Orphan detection — skip for processes owned by the active CLI
                let cpuTime = ProcessTreeQuery.getProcessCPUTime(pid: entry.pid)
                tracked.previousCPUTime = tracked.lastCPUTime
                tracked.lastCPUTime = cpuTime

                let cpuDelta = tracked.lastCPUTime - tracked.previousCPUTime
                if cpuDelta < 0.01 && tracked.previousCPUTime > 0 {
                    tracked.idlePollCount += 1
                } else {
                    tracked.idlePollCount = 0
                    tracked.isOrphanCandidate = false
                    tracked.orphanSince = nil
                    tracked.confirmedOrphanSince = nil
                }

                if tracked.idlePollCount >= 2 {
                    if !tracked.isOrphanCandidate {
                        tracked.isOrphanCandidate = true
                        tracked.orphanSince = Date()
                    }

                    if let since = tracked.orphanSince,
                       Date().timeIntervalSince(since) >= orphanTimeout
                    {
                        if tracked.confirmedOrphanSince == nil {
                            tracked.confirmedOrphanSince = Date()
                        }
                        orphans.append(tracked)
                    }
                }
            }

            updated.append(tracked)
        }

        // Force-kill MCP servers that didn't respond to SIGTERM
        if !mcpKilled.isEmpty {
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                for pid in mcpKilled {
                    if ProcessTreeQuery.isProcessAlive(pid) { kill(pid, SIGKILL) }
                }
            }
        }

        // Handle CLI exit — schedule deferred MCP cleanup with grace period

        if cliWasRunning && !cliStillRunning && !updated.isEmpty {
            // CLI just disappeared — schedule MCP cleanup after grace period
            if mcpCleanupWorkItem == nil {
                let shellPid = self.shellPID
                let mcpPids = updated.filter { $0.isMCPServer && !$0.isPinned }.map(\.pid)

                let workItem = DispatchWorkItem { [weak self] in
                    guard self != nil else { return }

                    // Re-check: is the CLI still gone?
                    let currentDescendants = ProcessTreeQuery.getDescendantProcesses(of: shellPid)
                    let cliBack = currentDescendants.contains { entry in
                        let desc = ProcessTreeQuery.describeProcess(pid: entry.pid).lowercased()
                        return cliKeywords.contains { desc.contains($0) }
                    }
                    guard !cliBack else { return }

                    for pid in mcpPids { kill(pid, SIGTERM) }
                    DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                        for pid in mcpPids {
                            if ProcessTreeQuery.isProcessAlive(pid) { kill(pid, SIGKILL) }
                        }
                    }

                    DispatchQueue.main.async { [weak self] in
                        self?.mcpCleanupWorkItem = nil
                        self?.childProcesses.removeAll { $0.isMCPServer && !$0.isPinned }
                        self?.clearContextUsage()
                        NotificationCenter.default.post(
                            name: .cliProcessExited, object: nil,
                            userInfo: ["shellPid": shellPid]
                        )
                    }
                }
                mcpCleanupWorkItem = workItem
                DispatchQueue.global(qos: .utility).asyncAfter(
                    deadline: .now() + cliExitGracePeriod, execute: workItem
                )
            }
        } else if cliStillRunning {
            // CLI is (still/again) running — cancel any pending MCP cleanup
            mcpCleanupWorkItem?.cancel()
            mcpCleanupWorkItem = nil
        }
        cliWasRunning = cliStillRunning

        // Auto-kill orphans that exceeded the auto-kill timeout
        var autoKilled: [pid_t] = []
        if autoKillTimeout > 0 {
            for orphan in orphans {
                if !orphan.isPinned,
                   let since = orphan.confirmedOrphanSince,
                   Date().timeIntervalSince(since) >= autoKillTimeout
                {
                    kill(orphan.pid, SIGTERM)
                    autoKilled.append(orphan.pid)
                }
            }
            if !autoKilled.isEmpty {
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                    for pid in autoKilled {
                        if ProcessTreeQuery.isProcessAlive(pid) { kill(pid, SIGKILL) }
                    }
                }
                orphans.removeAll { autoKilled.contains($0.pid) }
                updated.removeAll { autoKilled.contains($0.pid) }
            }
        }

        // Get current directory from the shell process directly
        // (descendants like MCP servers may have different CWDs)
        let cwd = ProcessTreeQuery.getProcessCurrentDirectory(pid: shellPID) ?? ""

        // Read context usage from statusline JSON (Claude-specific, skip for other CLIs)
        let newContextUsage: ContextUsage? = (activeCLI == .claude) ? pollContextFile() : nil

        // Adaptive poll interval: fast when CLI active, slow when fully idle
        adjustPollInterval(cliActive: cliStillRunning)

        DispatchQueue.main.async { [weak self] in
            self?.childProcesses = updated
            self?.orphanedProcesses = orphans
            if cwd != self?.currentDirectory { self?.currentDirectory = cwd }
            if let ctx = newContextUsage {
                self?.updateContextUsage(ctx)
            } else if activeCLI != .claude {
                self?.clearContextUsage()
            }
        }
    }

    // MARK: - Adaptive Poll Interval

    /// Adjust poll frequency: 2s when CLI active, default (5s) normally, 15s when fully idle.
    private func adjustPollInterval(cliActive: Bool) {
        let target: TimeInterval
        if cliActive {
            target = min(monitorInterval, 2)
            idlePollStreak = 0
        } else {
            idlePollStreak += 1
            // After 6 consecutive idle polls (~30s), slow down to 15s
            target = idlePollStreak > 6 ? 15 : monitorInterval
        }

        guard target != activeInterval else { return }
        activeInterval = target
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.timer?.invalidate()
            self.timer = Timer.scheduledTimer(
                withTimeInterval: target, repeats: true
            ) { [weak self] _ in
                DispatchQueue.global(qos: .utility).async { self?.poll() }
            }
        }
    }

    // MARK: - Context File Polling

    /// Read the context JSON file if it has been modified since last check.
    /// Returns nil if file unchanged or unreadable — avoids unnecessary SwiftUI updates.
    private func pollContextFile() -> ContextUsage? {
        let fm = FileManager.default
        let path = ContextUsageParser.contextFilePath

        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let modDate = attrs[.modificationDate] as? Date
        else { return nil }

        // Skip if file hasn't changed since last read
        if let last = lastContextFileDate, modDate <= last { return nil }
        lastContextFileDate = modDate

        return ContextUsageParser.readFromFile()
    }

    // MARK: - Process Discovery

    /// First-time discovery: fetch command line info to identify the process.
    private func createTrackedProcess(from entry: ProcessTreeQuery.ProcessEntry) -> TrackedProcess {
        var tracked = TrackedProcess(
            id: entry.pid,
            name: entry.name,
            parentPid: entry.parentPid,
            startTime: entry.startTime
        )
        // Expensive calls — done once per process, not every poll
        tracked.processDescription = ProcessTreeQuery.describeProcess(pid: entry.pid)
        tracked.isMCPServer = ProcessTreeQuery.isMCPServer(pid: entry.pid)
        tracked.isPinned = AppConfiguration.shared.pinnedProcessDescriptions.contains(tracked.processDescription)
        if tracked.isMCPServer {
            tracked.lastActiveTime = Date()
        }
        return tracked
    }
}
