import Combine
import Foundation

/// Monitors the child process tree of the shell process.
/// Detects truly orphaned node processes while excluding legitimate MCP servers.
/// Supports MCP server standby mode (SIGSTOP/SIGCONT) for memory optimization.
final class ProcessMonitor: ObservableObject {
    @Published var childProcesses: [TrackedProcess] = []
    @Published var orphanedProcesses: [TrackedProcess] = []
    @Published var currentDirectory: String = ""

    var monitorInterval: TimeInterval = 5
    var orphanTimeout: TimeInterval = 30
    var autoKillTimeout: TimeInterval = 90
    var standbyEnabled: Bool = true
    var standbyIdleThreshold: TimeInterval = 90

    var hasActiveProcesses: Bool { !childProcesses.isEmpty }

    private var timer: Timer?
    private var shellPID: pid_t = 0
    private var cliWasRunning: Bool = false
    private var mcpCleanupWorkItem: DispatchWorkItem?
    private var cliExitGracePeriod: TimeInterval = 15
    private var pulseTimer: DispatchSourceTimer?
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
        stopPulseTimer()
        // Resume any standby servers so they aren't left frozen
        for process in childProcesses where process.isInStandby {
            kill(process.pid, SIGCONT)
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.poll()
        }
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

    /// Re-read settings from AppConfiguration and apply to this monitor.
    func applyConfiguration() {
        let config = AppConfiguration.shared
        monitorInterval = TimeInterval(config.processMonitorInterval)
        orphanTimeout = TimeInterval(config.orphanTimeoutSeconds)
        autoKillTimeout = TimeInterval(config.autoKillTimeoutSeconds)
        standbyIdleThreshold = TimeInterval(config.mcpStandbyIdleSeconds)

        let wasEnabled = standbyEnabled
        standbyEnabled = config.mcpStandbyEnabled

        // If standby was just disabled, wake all sleeping servers
        if wasEnabled && !standbyEnabled {
            for process in childProcesses where process.isInStandby {
                kill(process.pid, SIGCONT)
            }
            for i in childProcesses.indices where childProcesses[i].isInStandby {
                childProcesses[i].isInStandby = false
            }
            stopPulseTimer()
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

        for entry in descendants {
            // Reuse existing tracked entry or create new
            var tracked = childProcesses.first(where: { $0.pid == entry.pid })
                ?? createTrackedProcess(from: entry)

            // Always fetch memory for the child process panel
            tracked.memoryBytes = ProcessTreeQuery.getProcessMemory(pid: entry.pid)

            if tracked.isMCPServer {
                // MCP server standby: track CPU to detect idle servers
                if standbyEnabled && !tracked.isInStandby {
                    let cpuTime = ProcessTreeQuery.getProcessCPUTime(pid: entry.pid)
                    tracked.previousCPUTime = tracked.lastCPUTime
                    tracked.lastCPUTime = cpuTime

                    let cpuDelta = tracked.lastCPUTime - tracked.previousCPUTime
                    if cpuDelta > 0.01 || tracked.previousCPUTime == 0 {
                        tracked.lastActiveTime = Date()
                    }

                    if let lastActive = tracked.lastActiveTime,
                       Date().timeIntervalSince(lastActive) >= standbyIdleThreshold
                    {
                        tracked.isInStandby = true
                        kill(entry.pid, SIGSTOP)
                        startPulseTimerIfNeeded()
                    }
                }
                // If in standby, skip CPU sampling (process is frozen)
            } else if tracked.isNodeProcess {
                // Orphan detection for non-MCP node processes
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

        // Detect CLI exit — schedule deferred MCP cleanup with grace period
        let cliKeywords = CLIProvider.allCases.map(\.processKeyword)
        let cliStillRunning = updated.contains { proc in
            let desc = proc.processDescription.lowercased()
            return cliKeywords.contains { desc.contains($0) }
        }
        if cliWasRunning && !cliStillRunning && !updated.isEmpty {
            // CLI just disappeared — schedule MCP cleanup after grace period
            if mcpCleanupWorkItem == nil {
                let shellPid = self.shellPID
                let workItem = DispatchWorkItem { [weak self] in
                    guard let self = self else { return }
                    self.mcpCleanupWorkItem = nil

                    // Re-check: is the CLI still gone?
                    let currentDescendants = ProcessTreeQuery.getDescendantProcesses(of: shellPid)
                    let cliBack = currentDescendants.contains { entry in
                        let desc = ProcessTreeQuery.describeProcess(pid: entry.pid).lowercased()
                        return cliKeywords.contains { desc.contains($0) }
                    }
                    guard !cliBack else { return }

                    // CLI is truly gone — kill MCP servers (SIGCONT first if in standby)
                    let mcpPids: [pid_t] = DispatchQueue.main.sync {
                        let mcps = self.childProcesses.filter(\.isMCPServer)
                        let pids = mcps.map(\.pid)
                        // Resume standby servers before killing
                        for mcp in mcps where mcp.isInStandby {
                            kill(mcp.pid, SIGCONT)
                        }
                        self.childProcesses.removeAll { $0.isMCPServer }
                        return pids
                    }
                    for pid in mcpPids { kill(pid, SIGTERM) }
                    DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                        for pid in mcpPids {
                            if ProcessTreeQuery.isProcessAlive(pid) { kill(pid, SIGKILL) }
                        }
                    }

                    DispatchQueue.main.async {
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
                if let since = orphan.confirmedOrphanSince,
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

        DispatchQueue.main.async { [weak self] in
            self?.childProcesses = updated
            self?.orphanedProcesses = orphans
            if cwd != self?.currentDirectory { self?.currentDirectory = cwd }
        }
    }

    // MARK: - MCP Standby Pulse

    /// Pulse timer briefly wakes standby MCP servers to check for pending work.
    /// Runs every 1 second on a background queue.
    private func pulse() {
        let standbyServers: [TrackedProcess] = DispatchQueue.main.sync {
            childProcesses.filter { $0.isMCPServer && $0.isInStandby }
        }
        guard !standbyServers.isEmpty else {
            stopPulseTimer()
            return
        }

        // Record CPU, then SIGCONT all standby servers
        var cpuBefore: [pid_t: Double] = [:]
        for server in standbyServers {
            cpuBefore[server.pid] = ProcessTreeQuery.getProcessCPUTime(pid: server.pid)
            kill(server.pid, SIGCONT)
        }

        // Wait 200ms for servers to process any pending requests
        Thread.sleep(forTimeInterval: 0.2)

        // Check which servers actually did work
        var wokenPids: [pid_t] = []
        for server in standbyServers {
            guard ProcessTreeQuery.isProcessAlive(server.pid) else { continue }
            let cpuAfter = ProcessTreeQuery.getProcessCPUTime(pid: server.pid)
            let delta = cpuAfter - (cpuBefore[server.pid] ?? 0)
            if delta > 0.001 {
                // Server processed a request — keep it awake
                wokenPids.append(server.pid)
            } else {
                // Still idle — put back to sleep
                kill(server.pid, SIGSTOP)
            }
        }

        if !wokenPids.isEmpty {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                for i in self.childProcesses.indices {
                    if wokenPids.contains(self.childProcesses[i].pid) {
                        self.childProcesses[i].isInStandby = false
                        self.childProcesses[i].lastActiveTime = Date()
                    }
                }
            }
        }
    }

    private func startPulseTimerIfNeeded() {
        guard pulseTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.pulse() }
        timer.resume()
        pulseTimer = timer
    }

    private func stopPulseTimer() {
        pulseTimer?.cancel()
        pulseTimer = nil
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
        if tracked.isMCPServer {
            tracked.lastActiveTime = Date()
        }
        return tracked
    }
}
