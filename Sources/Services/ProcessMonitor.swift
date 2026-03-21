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
    var autoCleanup: Bool = false

    var hasActiveProcesses: Bool { !childProcesses.isEmpty }

    private var timer: Timer?
    private var claudePID: pid_t = 0
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
                }

                if tracked.idlePollCount >= 2 {
                    if !tracked.isOrphanCandidate {
                        tracked.isOrphanCandidate = true
                        tracked.orphanSince = Date()
                    }
                    tracked.memoryBytes = ProcessTreeQuery.getProcessMemory(pid: entry.pid)

                    if let since = tracked.orphanSince,
                       Date().timeIntervalSince(since) >= orphanTimeout
                    {
                        orphans.append(tracked)
                    }
                }
            }

            updated.append(tracked)
        }

        // Also get current directory (from deepest child or shell)
        var cwd = ""
        for desc in descendants.reversed() {
            if let dir = ProcessTreeQuery.getProcessCurrentDirectory(pid: desc.pid) {
                cwd = dir
                break
            }
        }
        if cwd.isEmpty {
            cwd = ProcessTreeQuery.getProcessCurrentDirectory(pid: claudePID) ?? ""
        }

        DispatchQueue.main.async { [weak self] in
            self?.childProcesses = updated
            self?.orphanedProcesses = orphans
            if cwd != self?.currentDirectory { self?.currentDirectory = cwd }

            if self?.autoCleanup == true, !orphans.isEmpty {
                self?.cleanupOrphans()
            }
        }
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
