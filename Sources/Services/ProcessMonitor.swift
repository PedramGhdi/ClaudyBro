import Combine
import Foundation

/// Monitors the child process tree of the Claude CLI process.
/// Detects truly orphaned node processes while excluding legitimate MCP servers.
final class ProcessMonitor: ObservableObject {
    @Published var childProcesses: [TrackedProcess] = []
    @Published var orphanedProcesses: [TrackedProcess] = []
    @Published var currentDirectory: String = ""

    var monitorInterval: TimeInterval = 5
    var orphanTimeout: TimeInterval = 30
    var autoKillTimeout: TimeInterval = 120

    var hasActiveProcesses: Bool { !childProcesses.isEmpty }

    private var timer: Timer?
    private var claudePID: pid_t = 0
    private var claudeWasRunning: Bool = false
    private var cancellables = Set<AnyCancellable>()

    init() {
        NotificationCenter.default.publisher(for: .killOrphanProcesses)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.cleanupOrphans() }
            .store(in: &cancellables)
    }

    deinit { stopMonitoring() }

    func startMonitoring(claudePID pid: pid_t) {
        claudePID = pid
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

    // MARK: - Private

    private func poll() {
        guard claudePID > 0 else { return }

        let descendants = ProcessTreeQuery.getDescendantProcesses(of: claudePID)
        var updated: [TrackedProcess] = []
        var orphans: [TrackedProcess] = []

        for entry in descendants {
            // Reuse existing tracked entry or create new
            var tracked = childProcesses.first(where: { $0.pid == entry.pid })
                ?? createTrackedProcess(from: entry)

            // Always fetch memory for the child process panel
            tracked.memoryBytes = ProcessTreeQuery.getProcessMemory(pid: entry.pid)

            // Only run orphan detection on node processes that are NOT MCP servers
            if tracked.isNodeProcess && !tracked.isMCPServer {
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

        // Kill duplicate MCP servers (keep newest, kill older ones)
        let duplicatePids = findDuplicateMCPServers(in: updated)
        for pid in duplicatePids {
            kill(pid, SIGTERM)
            updated.removeAll { $0.pid == pid }
        }

        // Detect Claude exit — if Claude was running but no claude process remains, kill MCP servers
        let claudeStillRunning = updated.contains {
            $0.processDescription.lowercased().contains("claude")
        }
        if claudeWasRunning && !claudeStillRunning && !updated.isEmpty {
            let mcpPids = updated.filter(\.isMCPServer).map(\.pid)
            for pid in mcpPids { kill(pid, SIGTERM) }
            updated.removeAll { $0.isMCPServer }
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                for pid in mcpPids {
                    if ProcessTreeQuery.isProcessAlive(pid) { kill(pid, SIGKILL) }
                }
            }
        }
        claudeWasRunning = claudeStillRunning

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
        let cwd = ProcessTreeQuery.getProcessCurrentDirectory(pid: claudePID) ?? ""

        DispatchQueue.main.async { [weak self] in
            self?.childProcesses = updated
            self?.orphanedProcesses = orphans
            if cwd != self?.currentDirectory { self?.currentDirectory = cwd }
        }
    }

    /// Find duplicate MCP servers — returns PIDs of older duplicates to kill.
    private func findDuplicateMCPServers(in processes: [TrackedProcess]) -> [pid_t] {
        let mcpServers = processes.filter(\.isMCPServer)
        var seen: [String: TrackedProcess] = [:]
        var duplicates: [pid_t] = []

        // Group by description, keep newest (highest PID = most recent)
        for server in mcpServers {
            let key = server.processDescription
            if let existing = seen[key] {
                // Kill the older one (lower PID)
                let older = existing.pid < server.pid ? existing : server
                duplicates.append(older.pid)
                seen[key] = existing.pid < server.pid ? server : existing
            } else {
                seen[key] = server
            }
        }
        return duplicates
    }

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
        return tracked
    }
}
