import Darwin
import Foundation

/// Low-level process table queries using sysctl — no shell spawning needed.
enum ProcessTreeQuery {
    struct ProcessEntry {
        let pid: pid_t
        let parentPid: pid_t
        let name: String
        let startTime: Date
    }

    /// Query the full process table via sysctl(KERN_PROC_ALL).
    static func getAllProcesses() -> [ProcessEntry] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        var bufferSize: Int = 0

        guard sysctl(&mib, UInt32(mib.count), nil, &bufferSize, nil, 0) == 0 else {
            return []
        }

        let count = bufferSize / MemoryLayout<kinfo_proc>.stride
        guard count > 0 else { return [] }
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: count)

        guard sysctl(&mib, UInt32(mib.count), &processes, &bufferSize, nil, 0) == 0 else {
            return []
        }

        let actualCount = bufferSize / MemoryLayout<kinfo_proc>.stride
        return processes.prefix(actualCount).map(toProcessEntry)
    }

    /// Get direct children of a given PID.
    static func getChildProcesses(of parentPID: pid_t) -> [ProcessEntry] {
        getAllProcesses().filter { $0.parentPid == parentPID }
    }

    /// Recursively collect all descendants of a given PID (BFS).
    static func getDescendantProcesses(of rootPID: pid_t) -> [ProcessEntry] {
        let allProcs = getAllProcesses()
        var descendants: [ProcessEntry] = []
        var queue: [pid_t] = [rootPID]

        while !queue.isEmpty {
            let current = queue.removeFirst()
            let children = allProcs.filter { $0.parentPid == current }
            descendants.append(contentsOf: children)
            queue.append(contentsOf: children.map(\.pid))
        }

        return descendants
    }

    /// Resident memory in bytes for a process (proc_pidinfo).
    static func getProcessMemory(pid: pid_t) -> UInt64 {
        var taskInfo = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        let result = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &taskInfo, size)
        guard result == size else { return 0 }
        return taskInfo.pti_resident_size
    }

    /// Total CPU time (user + system) in seconds.
    static func getProcessCPUTime(pid: pid_t) -> Double {
        var taskInfo = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        let result = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &taskInfo, size)
        guard result == size else { return 0 }
        let nanoseconds = taskInfo.pti_total_user + taskInfo.pti_total_system
        return Double(nanoseconds) / 1_000_000_000.0
    }

    /// Check if a process is alive (signal 0 test).
    static func isProcessAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }

    // MARK: - Command Line & Description

    /// Get the full command line arguments for a process via KERN_PROCARGS2.
    static func getProcessArgs(pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size: Int = 0

        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }

        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buffer.deallocate() }

        guard sysctl(&mib, 3, buffer, &size, nil, 0) == 0 else { return [] }

        // First 4 bytes = argc
        var argc: Int32 = 0
        memcpy(&argc, buffer, 4)

        // Skip executable path (starts at offset 4)
        var pos = 4
        while pos < size && buffer[pos] != 0 { pos += 1 }
        // Skip null padding after exec path
        while pos < size && buffer[pos] == 0 { pos += 1 }

        // Read argc null-terminated argument strings
        var args: [String] = []
        var argCount: Int32 = 0
        while pos < size && argCount < argc {
            let start = pos
            while pos < size && buffer[pos] != 0 { pos += 1 }
            if pos > start {
                let data = Data(bytes: buffer + start, count: pos - start)
                if let str = String(data: data, encoding: .utf8) {
                    args.append(str)
                }
            }
            pos += 1
            argCount += 1
        }

        return args
    }

    /// Human-readable description of a process based on its command line.
    static func describeProcess(pid: pid_t) -> String {
        let args = getProcessArgs(pid: pid)
        let joined = args.joined(separator: " ").lowercased()

        // MCP servers
        if joined.contains("shadcn") { return "Shadcn UI MCP Server" }
        if joined.contains("brave-search") { return "Brave Search MCP Server" }
        if joined.contains("playwright") || joined.contains("@playwright") { return "Playwright MCP Server" }
        if joined.contains("context7") { return "Context7 MCP Server" }
        if joined.contains("mcp") { return "MCP Server" }

        // Language servers / tools
        if joined.contains("tsserver") || joined.contains("typescript-language") { return "TypeScript Language Server" }
        if joined.contains("getdiagnostics") { return "getDiagnostics Worker" }
        if joined.contains("eslint") { return "ESLint Process" }
        if joined.contains("prettier") { return "Prettier Process" }

        // AI CLI tools
        for provider in CLIProvider.allCases {
            if joined.contains(provider.processKeyword) { return provider.processDescription }
        }

        // npm
        if joined.contains("npm") { return "npm Process" }

        // Fallback: use executable name
        if let first = args.first {
            return URL(fileURLWithPath: first).lastPathComponent
        }

        return "Unknown Process"
    }

    /// Check if a process is an MCP server (legitimately idle, should not be flagged as orphan).
    static func isMCPServer(pid: pid_t) -> Bool {
        let args = getProcessArgs(pid: pid)
        let joined = args.joined(separator: " ").lowercased()
        return joined.contains("mcp")
            || joined.contains("language-server")
            || joined.contains("tsserver")
    }

    // MARK: - Working Directory

    /// Get the current working directory of a process via proc_pidinfo.
    static func getProcessCurrentDirectory(pid: pid_t) -> String? {
        var vnodeInfo = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let result = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vnodeInfo, size)
        guard result == size else { return nil }

        return withUnsafePointer(to: vnodeInfo.pvi_cdir.vip_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { charPtr in
                let path = String(cString: charPtr)
                return path.isEmpty ? nil : path
            }
        }
    }

    // MARK: - Private

    private static func toProcessEntry(_ proc: kinfo_proc) -> ProcessEntry {
        let pid = proc.kp_proc.p_pid
        let ppid = proc.kp_eproc.e_ppid
        let name = extractName(from: proc)
        let startSec = proc.kp_proc.p_starttime.tv_sec
        let startTime = Date(timeIntervalSince1970: TimeInterval(startSec))
        return ProcessEntry(pid: pid, parentPid: ppid, name: name, startTime: startTime)
    }

    private static func extractName(from proc: kinfo_proc) -> String {
        withUnsafePointer(to: proc.kp_proc.p_comm) { ptr in
            ptr.withMemoryRebound(
                to: CChar.self,
                capacity: Int(MAXCOMLEN + 1)
            ) { charPtr in
                String(cString: charPtr)
            }
        }
    }
}
