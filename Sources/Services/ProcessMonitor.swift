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
    /// Cached CLI state — set by background poll, read by main thread. Avoids expensive sysctl on render.
    @Published var activeCLI: CLIProvider? = nil

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
    /// Accumulates every PID seen in the active CLI's subtree across polls.
    /// Used at CLI-exit cleanup to kill the entire former subtree (npm, head,
    /// node helpers — not just MCP servers). Reset when cleanup completes or
    /// when a new CLI session begins.
    private var cliSubtreeSnapshot: Set<pid_t> = []

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
        cliSubtreeSnapshot.removeAll()
        childProcesses = []
        orphanedProcesses = []
    }

    /// Kill a single orphaned process by PID.
    func killProcess(_ pid: pid_t) {
        kill(pid, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if ProcessTreeQuery.isProcessAlive(pid) { kill(pid, SIGKILL) }
        }
        // Re-poll on the background queue — poll() uses main.sync for its snapshot,
        // so invoking it from the main thread would deadlock.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) { [weak self] in
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

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) { [weak self] in
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
        // poll() takes a snapshot via main.sync below, so it must run off-main.
        // Guard against accidental main invocation (e.g. from Timer callbacks or
        // post-kill re-polls) by bouncing to the utility queue.
        if Thread.isMainThread {
            DispatchQueue.global(qos: .utility).async { [weak self] in self?.poll() }
            return
        }

        guard shellPID > 0 else { return }

        let descendants = ProcessTreeQuery.getDescendantProcesses(of: shellPID)

        // Thread-safe snapshot of tracked state for O(1) lookup during this poll.
        // Previously we read `childProcesses` directly from the background thread
        // while the main thread published updates to it — an exclusive-access
        // violation that crashed the app once the process list grew large.
        var cache: [pid_t: TrackedProcess] = [:]
        DispatchQueue.main.sync {
            cache.reserveCapacity(childProcesses.count)
            for proc in childProcesses { cache[proc.pid] = proc }
        }

        var updated: [TrackedProcess] = []
        updated.reserveCapacity(descendants.count)
        var orphans: [TrackedProcess] = []
        var mcpKilled: [pid_t] = []

        // Find the active CLI and build a set of PIDs in its subtree.
        // Only these are protected from orphan/MCP killing — other node
        // processes outside the CLI's tree are still cleaned up normally.
        // Single pass: describe each PID at most once, reusing cached descriptions.
        let cliKeywords = CLIProvider.allCases.map(\.processKeyword)
        var detectedCLI: CLIProvider?
        var cliPid: pid_t = 0
        cliScan: for entry in descendants {
            let desc = (cache[entry.pid]?.processDescription
                ?? ProcessTreeQuery.describeProcess(pid: entry.pid)).lowercased()
            for provider in CLIProvider.allCases where desc.contains(provider.processKeyword) {
                detectedCLI = provider
                cliPid = entry.pid
                break cliScan
            }
        }
        let cliStillRunning = detectedCLI != nil

        // Build set of PIDs owned by the CLI (the CLI itself + every descendant
        // at any depth). Iterative BFS over the in-memory `descendants` snapshot —
        // no extra sysctl calls. Repeats until the set stops growing so deep
        // chains like CLI → bash → npm → node → grandchild are fully captured.
        var cliOwnedPids = Set<pid_t>()
        if cliPid > 0 {
            cliOwnedPids.insert(cliPid)
            var changed = true
            while changed {
                changed = false
                for entry in descendants
                    where !cliOwnedPids.contains(entry.pid)
                    && cliOwnedPids.contains(entry.parentPid)
                {
                    cliOwnedPids.insert(entry.pid)
                    changed = true
                }
            }
            // Persist across polls so transient pids aren't lost between snapshots.
            cliSubtreeSnapshot.formUnion(cliOwnedPids)
        }

        for entry in descendants {
            // Reuse existing tracked entry from the snapshot cache or create new
            var tracked = cache[entry.pid] ?? createTrackedProcess(from: entry)

            tracked.memoryBytes = ProcessTreeQuery.getProcessMemory(pid: entry.pid)

            // Dynamic idle-kill applies to every descendant EXCEPT the active
            // CLI itself. Previously only MCP servers and out-of-subtree
            // orphans were tracked, so the CLI's own subtree could accumulate
            // dozens of idle children (duplicate Claude Code workers, leaked
            // `head`/`npm`/`node` from bash-tool one-shots, Task subagents)
            // without any cleanup. Protecting only `cliPid` lets every other
            // descendant be reaped once it sits idle past `mcpIdleTimeout`.
            //
            // The idle check uses CPU delta since the previous poll — any
            // process doing real work bumps `lastActiveTime` and survives.
            // Killed MCPs auto-restart on the next tool call, and one-shot
            // helpers (head, npm, subagents) are already done when they hit
            // this path, so termination is safe.
            let isCliItself = (entry.pid == cliPid)

            if !isCliItself {
                let cpuTime = ProcessTreeQuery.getProcessCPUTime(pid: entry.pid)
                tracked.previousCPUTime = tracked.lastCPUTime
                tracked.lastCPUTime = cpuTime

                let cpuDelta = tracked.lastCPUTime - tracked.previousCPUTime
                if cpuDelta > 0.01 || tracked.previousCPUTime == 0 {
                    tracked.lastActiveTime = Date()
                }
                let isIdleNow = tracked.previousCPUTime > 0 && cpuDelta < 0.01

                // Dynamic kill: any non-CLI descendant idle past the timeout
                // gets SIGTERM. `previousCPUTime > 0` in `isIdleNow` enforces
                // at least one poll of grace for freshly-spawned processes.
                if !tracked.isPinned,
                   isIdleNow,
                   let lastActive = tracked.lastActiveTime,
                   Date().timeIntervalSince(lastActive) >= mcpIdleTimeout
                {
                    kill(entry.pid, SIGTERM)
                    mcpKilled.append(entry.pid)
                    continue // don't add to updated
                }

                // Orphan detection — non-MCP descendants get surfaced in the
                // UI with a countdown, both in AND out of the CLI subtree.
                // In-subtree leaks (duplicate Claude workers, one-shot
                // `head`/`npm`, Task subagent helpers) used to be invisible
                // because this block gated on `isOutsideCliTree`; users had
                // no way to tell why the child-process count was climbing.
                // MCP servers are still excluded — they're handled silently
                // by the dynamic kill above and clutter the orphan panel
                // otherwise.
                if !tracked.isMCPServer {
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

        // Handle CLI exit — schedule full subtree cleanup after grace period.
        // We kill EVERY pid that was ever in the CLI's subtree (snapshot accumulated
        // across polls while it was running), not just MCP servers — so npm, head,
        // node helpers, and shell pipelines spawned under the CLI all get reaped.
        // Gate on the snapshot, not `updated`: leaked descendants might already be
        // gone from this poll's tracked list but still alive as orphans.
        if cliWasRunning && !cliStillRunning && !cliSubtreeSnapshot.isEmpty {
            if mcpCleanupWorkItem == nil {
                let shellPid = self.shellPID
                // Snapshot the tracked pin state so we don't kill pinned entries.
                // Keyed by pid for O(1) lookup inside the work item.
                let pinnedPids = Set(updated.filter(\.isPinned).map(\.pid))
                let snapshotPids = cliSubtreeSnapshot

                let workItem = DispatchWorkItem { [weak self] in
                    guard self != nil else { return }

                    // Re-check: is the CLI still gone?
                    let currentDescendants = ProcessTreeQuery.getDescendantProcesses(of: shellPid)
                    let cliBack = currentDescendants.contains { entry in
                        let desc = ProcessTreeQuery.describeProcess(pid: entry.pid).lowercased()
                        return cliKeywords.contains { desc.contains($0) }
                    }
                    guard !cliBack else { return }

                    // Kill list = snapshot ∩ alive ∩ not pinned. Intersecting with
                    // currently-alive pids guards against killing pids the OS reused
                    // for unrelated processes after the CLI's children exited.
                    let killPids = snapshotPids.filter { pid in
                        !pinnedPids.contains(pid) && ProcessTreeQuery.isProcessAlive(pid)
                    }

                    for pid in killPids { kill(pid, SIGTERM) }
                    DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                        for pid in killPids {
                            if ProcessTreeQuery.isProcessAlive(pid) { kill(pid, SIGKILL) }
                        }
                    }

                    DispatchQueue.main.async { [weak self] in
                        guard let self = self else { return }
                        self.mcpCleanupWorkItem = nil
                        self.childProcesses.removeAll { snapshotPids.contains($0.pid) && !$0.isPinned }
                        self.cliSubtreeSnapshot.removeAll()
                        self.clearContextUsage()
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
            // CLI is (still/again) running — cancel any pending cleanup.
            // IMPORTANT: do NOT reset cliSubtreeSnapshot here. If the user
            // bounced Claude within the grace period, the previous run's MCP
            // servers may still be alive (reparented under the shell) but
            // unreachable from the new cliPid — they won't be in cliOwnedPids.
            // Keeping the old accumulated snapshot ensures they still get
            // killed on the NEXT CLI exit. Clearing here is how the duplicate
            // MCP leak happens.
            mcpCleanupWorkItem?.cancel()
            mcpCleanupWorkItem = nil
        }
        cliWasRunning = cliStillRunning

        // Auto-kill orphans that exceeded the auto-kill timeout.
        // autoKillTimeout == 0 means "kill immediately on the first poll
        // after the orphan is confirmed" (the inner `>=` already handles this).
        var autoKilled: [pid_t] = []
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

        // Get current directory from the shell process directly
        // (descendants like MCP servers may have different CWDs)
        let cwd = ProcessTreeQuery.getProcessCurrentDirectory(pid: shellPID) ?? ""

        // Read context usage from statusline JSON (Claude-specific, skip for other CLIs)
        let newContextUsage: ContextUsage? = (detectedCLI == .claude) ? pollContextFile() : nil

        // Adaptive poll interval: fast when CLI active, slow when fully idle
        adjustPollInterval(cliActive: cliStillRunning)

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.childProcesses = updated
            self.orphanedProcesses = orphans
            if self.activeCLI != detectedCLI { self.activeCLI = detectedCLI }
            if cwd != self.currentDirectory { self.currentDirectory = cwd }
            if let ctx = newContextUsage {
                self.updateContextUsage(ctx)
            } else if detectedCLI != .claude {
                self.clearContextUsage()
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
