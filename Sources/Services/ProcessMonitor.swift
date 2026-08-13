import Combine
import Foundation

/// Monitors the child process tree of the shell process.
/// Detects truly orphaned node processes while excluding legitimate MCP servers.
/// For CLIs that auto-restart MCPs (see CLIProvider.autoRestartsKilledMCPs),
/// idle MCP servers are reaped after a configurable timeout. For CLIs that
/// don't, the entire CLI subtree is protected.
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
    /// Master switch for every automatic kill path. Orphans are still detected
    /// and displayed when off — the user just does the reaping by hand.
    var autoKillEnabled: Bool = true

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
    /// Accumulates every process seen in the active CLI's subtree across polls.
    ///
    /// Serves two purposes. It is the kill list at CLI-exit cleanup (npm, head,
    /// node helpers — not just MCP servers), and it is the *eligibility* record
    /// that makes automatic killing safe: a process we never saw under a CLI is
    /// something the user started, and is never reaped. Entries are identities
    /// rather than bare pids so a recycled pid can't inherit a death sentence.
    private var cliSubtreeSnapshot: Set<ProcessTreeQuery.ProcessIdentity> = []

    /// Private dup of the PTY primary fd, used to ask who owns the terminal.
    /// Owned by this monitor so its lifetime can't be cut short by the view.
    private var ptyFd: Int32 = -1

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

    /// - Parameter ptyMasterFd: primary side of the shell's PTY. Duplicated so
    ///   this monitor can read the foreground process group for as long as it
    ///   polls, independent of the terminal view's own fd lifetime. Pass -1 if
    ///   unavailable — foreground protection is then simply skipped.
    func startMonitoring(shellPID pid: pid_t, ptyMasterFd: Int32 = -1) {
        shellPID = pid
        if ptyFd >= 0 { close(ptyFd) }
        ptyFd = ptyMasterFd >= 0 ? dup(ptyMasterFd) : -1
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
        if ptyFd >= 0 {
            close(ptyFd)
            ptyFd = -1
        }
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
        autoKillEnabled = config.autoKillEnabled

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

        // Find the active CLI and build a set of PIDs in its subtree. Only
        // these — plus anything previously recorded in cliSubtreeSnapshot — are
        // eligible for automatic killing at all; everything else in the shell's
        // tree belongs to the user and is left alone.
        // Single pass: classify each PID at most once, reusing cached results.
        var detectedCLI: CLIProvider?
        var cliPid: pid_t = 0
        for entry in descendants {
            // Cached entries already know what they are; only newly-seen pids
            // pay for a KERN_PROCARGS2 read.
            let provider: CLIProvider?
            if let cached = cache[entry.pid] {
                provider = cached.cliProvider
            } else {
                provider = ProcessTreeQuery.detectCLIProvider(pid: entry.pid)
            }
            if let provider {
                detectedCLI = provider
                cliPid = entry.pid
                break
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
            cliSubtreeSnapshot.formUnion(
                descendants.lazy.filter { cliOwnedPids.contains($0.pid) }.map(\.identity)
            )
        }

        // The job that currently owns the terminal, 0 when unknown.
        let foregroundPgid = ProcessTreeQuery.foregroundProcessGroup(ptyFd: ptyFd)

        for entry in descendants {
            // Reuse existing tracked entry from the snapshot cache or create new
            var tracked = cache[entry.pid] ?? createTrackedProcess(from: entry)

            tracked.memoryBytes = ProcessTreeQuery.getProcessMemory(pid: entry.pid)

            // CPU is sampled for every descendant, not just killable ones, so
            // the process panel shows real activity for the user's own jobs.
            let cpuTime = ProcessTreeQuery.getProcessCPUTime(pid: entry.pid)
            tracked.previousCPUTime = tracked.lastCPUTime
            tracked.lastCPUTime = cpuTime

            let cpuDelta = tracked.lastCPUTime - tracked.previousCPUTime
            if cpuDelta > 0.01 || tracked.previousCPUTime == 0 {
                tracked.lastActiveTime = Date()
            }
            let isIdleNow = tracked.previousCPUTime > 0 && cpuDelta < 0.01

            // Eligibility for automatic termination is decided by provenance,
            // never by idleness alone. Being idle is normal: `ssh` blocked on
            // the network, a pager waiting for a keypress and a suspended job
            // all burn zero CPU. What actually distinguishes junk from a real
            // session is who started it — we only ever reap processes we have
            // seen inside an AI CLI's subtree, because those are the ones the
            // user never launched and cannot see.
            //
            // Three things are off-limits:
            //   1. the CLI process itself,
            //   2. the job that currently owns the terminal (the user is typing
            //      into it this instant, whatever its provenance),
            //   3. the whole subtree of CLIs that don't respawn killed
            //      children — reaping a worker there crashes the session.
            //
            // (2) deliberately matches the process group *leader* only, not
            // every member. Children spawned by a CLI inherit its process
            // group, so testing group membership would mark every MCP server
            // as foreground while the CLI is running and disable their cleanup
            // entirely. The leader is the job the user actually launched.
            let protectsSubtree = !(detectedCLI?.autoRestartsKilledMCPs ?? true)
            let isCLISpawned = cliOwnedPids.contains(entry.pid)
                || cliSubtreeSnapshot.contains(entry.identity)
            let ownsTerminal = foregroundPgid != 0 && entry.pid == foregroundPgid

            let isReapable = isCLISpawned
                && entry.pid != cliPid
                && !ownsTerminal
                && !(protectsSubtree && cliOwnedPids.contains(entry.pid))

            if isReapable {
                // Dynamic kill: a CLI-spawned helper idle past the timeout gets
                // SIGTERM. `previousCPUTime > 0` in `isIdleNow` enforces at
                // least one poll of grace for freshly-spawned processes.
                if autoKillEnabled,
                   !tracked.isPinned,
                   isIdleNow,
                   let lastActive = tracked.lastActiveTime,
                   Date().timeIntervalSince(lastActive) >= mcpIdleTimeout
                {
                    kill(entry.pid, SIGTERM)
                    mcpKilled.append(entry.pid)
                    continue // don't add to updated
                }

                // Orphan detection — CLI-spawned, non-MCP descendants get
                // surfaced in the UI with a countdown, both in AND out of the
                // current CLI subtree. In-subtree leaks (duplicate CLI
                // workers, one-shot `head`/`npm`, subagent helpers) used to be
                // invisible because this block gated on `isOutsideCliTree`;
                // users had no way to tell why the child-process count was
                // climbing. MCP servers are still excluded — they're handled
                // silently by the dynamic kill above and clutter the orphan
                // panel otherwise.
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
            } else {
                // Not reapable — clear any orphan bookkeeping so the panel
                // never shows an auto-kill countdown that will not fire. A
                // long-lived `ssh` or `vim` is idle by nature, not orphaned.
                tracked.idlePollCount = 0
                tracked.isOrphanCandidate = false
                tracked.orphanSince = nil
                tracked.confirmedOrphanSince = nil
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
                let snapshot = cliSubtreeSnapshot
                let snapshotPids = Set(snapshot.map(\.pid))

                let workItem = DispatchWorkItem { [weak self] in
                    guard self != nil else { return }

                    // Re-check: is the CLI still gone?
                    let currentDescendants = ProcessTreeQuery.getDescendantProcesses(of: shellPid)
                    let cliBack = currentDescendants.contains { entry in
                        ProcessTreeQuery.detectCLIProvider(pid: entry.pid) != nil
                    }
                    guard !cliBack else { return }

                    // Kill list = snapshot ∩ still-the-same-process ∩ not pinned.
                    // Matching on identity (pid + start time) rather than mere
                    // existence is what keeps a recycled pid — say, a brand-new
                    // `ssh` that inherited a dead MCP server's number — out of
                    // the kill list.
                    let killPids = snapshot
                        .filter { !pinnedPids.contains($0.pid) && ProcessTreeQuery.matchesIdentity($0) }
                        .map(\.pid)

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
            // bounced the CLI within the grace period, the previous run's MCP
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
        for orphan in orphans where autoKillEnabled {
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

        // Read context usage from statusline JSON. Only CLIs that emit
        // telemetry (see CLIProvider.supportsContextTelemetry) populate it.
        let supportsTelemetry = detectedCLI?.supportsContextTelemetry ?? false
        let newContextUsage: ContextUsage? = supportsTelemetry ? pollContextFile() : nil

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
            } else if !supportsTelemetry {
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
        // Expensive calls — done once per process, not every poll. The argv is
        // read a single time and shared by all three classifiers.
        let args = ProcessTreeQuery.getProcessArgs(pid: entry.pid)
        tracked.processDescription = ProcessTreeQuery.describeProcess(args: args)
        tracked.isMCPServer = ProcessTreeQuery.isMCPServer(args: args)
        tracked.cliProvider = ProcessTreeQuery.detectCLIProvider(args: args)
        tracked.isPinned = AppConfiguration.shared.pinnedProcessDescriptions.contains(tracked.processDescription)
        if tracked.isMCPServer {
            tracked.lastActiveTime = Date()
        }
        return tracked
    }
}
