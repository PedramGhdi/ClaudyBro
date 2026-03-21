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

    // Updated each poll cycle
    var lastCPUTime: Double = 0
    var previousCPUTime: Double = 0
    var idlePollCount: Int = 0
    var isOrphanCandidate: Bool = false
    var orphanSince: Date?
    var memoryBytes: UInt64 = 0

    var formattedMemory: String {
        ByteCountFormatter.string(fromByteCount: Int64(memoryBytes), countStyle: .memory)
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
}
