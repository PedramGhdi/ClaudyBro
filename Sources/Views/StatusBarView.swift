import SwiftUI

/// Bottom status strip with orphan detail popover.
struct StatusBarView: View {
    @ObservedObject var processMonitor: ProcessMonitor
    let shellPID: pid_t

    @State private var showOrphanPanel = false
    @State private var showChildPanel = false
    @State private var tick = Date()

    private let textColor = Color(nsColor: Constants.statusTextColor)
    private let countdownTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            // Left-aligned: PID + child processes
            HStack(spacing: 12) {
                if shellPID > 0 {
                    label("PID \(shellPID)")
                }

                let childCount = processMonitor.childProcesses.count
                if childCount > 0 {
                    Button(action: { showChildPanel.toggle() }) {
                        label("\(childCount) child \(childCount == 1 ? "process" : "processes")")
                    }
                    .buttonStyle(.plain)
                    .cursor(.pointingHand)
                    .popover(isPresented: $showChildPanel, arrowEdge: .top) {
                        ChildProcessPanel(processMonitor: processMonitor)
                    }
                }

                Spacer()
            }

            // Center: context usage
            if !processMonitor.contextUsage.isEmpty {
                contextUsageView
            }

            // Right-aligned: orphan badge
            HStack {
                Spacer()
                if !processMonitor.orphanedProcesses.isEmpty {
                    orphanBadge
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(height: 24)
        .background(Color(nsColor: Constants.statusBarBackground))
        .onReceive(countdownTimer) { newTick in
            // Only update tick when orphans exist — avoids unnecessary re-renders
            if !processMonitor.orphanedProcesses.isEmpty { tick = newTick }
        }
    }

    // MARK: - Context Usage Display

    private var contextUsageView: some View {
        let usage = processMonitor.contextUsage
        return HStack(spacing: 8) {
            // Context usage percentage
            if let pct = usage.usedPercentage {
                HStack(spacing: 3) {
                    Image(systemName: "brain")
                        .font(.system(size: 9))
                    Text("\(pct)%")
                }
                .foregroundColor(contextColor(pct))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
            }

            // Model name
            if let model = usage.modelName {
                Text(model)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(textColor.opacity(0.8))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(3)
            }

            // Effort
            if let effort = usage.effort {
                Text(effort)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(effortColor(effort))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(effortColor(effort).opacity(0.12))
                    .cornerRadius(3)
            }

            // Mode: "bypass"
            if let mode = usage.modeIndicator {
                Text(mode)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(Color.orange.opacity(0.9))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(3)
            }
        }
    }

    private func contextColor(_ percentage: Int) -> Color {
        if percentage >= 80 { return .red }
        if percentage >= 60 { return .orange }
        return Color(nsColor: Constants.accentColor)
    }

    private func effortColor(_ effort: String) -> Color {
        switch effort {
        case "high": return .green
        case "medium": return .yellow
        default: return .gray
        }
    }

    // MARK: - Orphan Badge (clickable → opens detail panel)

    private var orphanBadge: some View {
        let count = processMonitor.orphanedProcesses.count
        let mem = orphanMemory
        let timeout = processMonitor.autoKillTimeout
        let nearest = nearestAutoKillCountdown

        return Button(action: { showOrphanPanel.toggle() }) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundColor(orphanBadgeColor)

                Text("\(count) orphaned (\(mem))")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(orphanBadgeColor)

                if timeout > 0, let countdown = nearest {
                    Text(countdown)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(orphanBadgeColor)
                }
            }
        }
        .buttonStyle(.plain)
        .cursor(.pointingHand)
        .popover(isPresented: $showOrphanPanel, arrowEdge: .top) {
            OrphanDetailPanel(
                processMonitor: processMonitor,
                isPresented: $showOrphanPanel
            )
        }
    }

    private var orphanBadgeColor: Color {
        let timeout = processMonitor.autoKillTimeout
        guard timeout > 0 else { return Color(nsColor: Constants.warningColor) }
        let minCountdown = processMonitor.orphanedProcesses
            .compactMap(\.confirmedOrphanSince)
            .map { timeout - Date().timeIntervalSince($0) }
            .min() ?? timeout
        if minCountdown < 30 { return .red }
        return Color(nsColor: Constants.warningColor)
    }

    private var nearestAutoKillCountdown: String? {
        let timeout = processMonitor.autoKillTimeout
        guard timeout > 0 else { return nil }
        let _ = tick // force re-evaluation on timer
        let nearest = processMonitor.orphanedProcesses
            .map { $0.autoKillCountdown(timeout: timeout) }
            .min() ?? timeout
        let remaining = Int(nearest)
        if remaining <= 0 { return "killing..." }
        if remaining < 60 { return "auto-kill \(remaining)s" }
        return "auto-kill \(remaining / 60)m \(remaining % 60)s"
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(textColor)
    }

    private var orphanMemory: String {
        let bytes = processMonitor.orphanedProcesses.reduce(UInt64(0)) { $0 + $1.memoryBytes }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }
}

// MARK: - Child Process Panel (popover content)

struct ChildProcessPanel: View {
    @ObservedObject var processMonitor: ProcessMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Child Processes")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(processMonitor.childProcesses.count) total")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            if processMonitor.childProcesses.isEmpty {
                HStack {
                    Spacer()
                    Text("No child processes")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.vertical, 20)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(processMonitor.childProcesses) { process in
                            ChildProcessRow(process: process) {
                                processMonitor.killProcess(process.pid)
                            }
                            Divider().padding(.leading, 40)
                        }
                    }
                }
                .frame(maxHeight: 300)
            }
        }
        .frame(width: 380)
    }
}

// MARK: - Child Process Row

struct ChildProcessRow: View {
    let process: TrackedProcess
    let onKill: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 14))
                .foregroundColor(iconColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(process.processDescription.isEmpty ? process.name : process.processDescription)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text("PID \(process.pid)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)

                    if process.memoryBytes > 0 {
                        Text(process.formattedMemory)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                    }

                    if process.isMCPServer {
                        Text("MCP")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundColor(.green)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.green.opacity(0.15))
                            .cornerRadius(3)
                    }
                }
            }

            Spacer()

            Button(action: onKill) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.red.opacity(0.7))
            }
            .buttonStyle(.plain)
            .cursor(.pointingHand)
            .help("Kill this process")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var iconName: String {
        if process.isMCPServer { return "server.rack" }
        let desc = process.processDescription.lowercased()
        for provider in CLIProvider.allCases {
            if desc.contains(provider.processKeyword) { return provider.iconName }
        }
        if desc.contains("typescript") || desc.contains("tsserver") { return "chevron.left.forwardslash.chevron.right" }
        if desc.contains("diagnostics") { return "stethoscope" }
        if desc.contains("node") { return "circle.hexagongrid" }
        return "gearshape"
    }

    private var iconColor: Color {
        if process.isMCPServer { return .green }
        let desc = process.processDescription.lowercased()
        for provider in CLIProvider.allCases {
            if desc.contains(provider.processKeyword) { return Color(nsColor: provider.color) }
        }
        if desc.contains("typescript") { return .blue }
        if desc.contains("diagnostics") { return .orange }
        return .gray
    }
}

// MARK: - Orphan Detail Panel (popover content)

struct OrphanDetailPanel: View {
    @ObservedObject var processMonitor: ProcessMonitor
    @Binding var isPresented: Bool
    @State private var tick = Date()

    private let refreshTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Orphaned Processes")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(processMonitor.orphanedProcesses.count) total")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            if processMonitor.autoKillTimeout > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "timer")
                        .font(.system(size: 10))
                    Text("Auto-kill after \(Int(processMonitor.autoKillTimeout))s of orphan status")
                        .font(.system(size: 10))
                }
                .foregroundColor(.secondary)
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
            }

            Divider()

            // Process list
            if processMonitor.orphanedProcesses.isEmpty {
                HStack {
                    Spacer()
                    Text("No orphaned processes")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.vertical, 20)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(processMonitor.orphanedProcesses) { process in
                            OrphanProcessRow(
                                process: process,
                                autoKillTimeout: processMonitor.autoKillTimeout,
                                tick: tick
                            ) {
                                processMonitor.killProcess(process.pid)
                            }
                            Divider().padding(.leading, 40)
                        }
                    }
                }
                .frame(maxHeight: 300)
            }

            Divider()

            // Footer with Clean All
            HStack {
                Text(totalMemoryText)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                Spacer()

                Button(action: {
                    processMonitor.cleanupOrphans()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        if processMonitor.orphanedProcesses.isEmpty {
                            isPresented = false
                        }
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "trash")
                            .font(.system(size: 10))
                        Text("Clean All")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Color.red.opacity(0.8))
                    .cornerRadius(5)
                }
                .buttonStyle(.plain)
                .cursor(.pointingHand)
                .disabled(processMonitor.orphanedProcesses.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .frame(width: 380)
        .onReceive(refreshTimer) { tick = $0 }
    }

    private var totalMemoryText: String {
        let bytes = processMonitor.orphanedProcesses.reduce(UInt64(0)) { $0 + $1.memoryBytes }
        let formatted = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
        return "Total: \(formatted)"
    }
}

// MARK: - Individual Process Row

struct OrphanProcessRow: View {
    let process: TrackedProcess
    let autoKillTimeout: TimeInterval
    let tick: Date
    let onKill: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            // Icon
            Image(systemName: iconName)
                .font(.system(size: 14))
                .foregroundColor(iconColor)
                .frame(width: 24)

            // Description + PID
            VStack(alignment: .leading, spacing: 2) {
                Text(process.processDescription.isEmpty ? process.name : process.processDescription)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text("PID \(process.pid)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)

                    if process.memoryBytes > 0 {
                        Text(process.formattedMemory)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                    }

                    Text(process.formattedIdleTime)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Color(nsColor: Constants.warningColor))
                }

                if autoKillTimeout > 0 {
                    let _ = tick // force re-evaluation
                    Text(process.formattedAutoKillCountdown(timeout: autoKillTimeout))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(countdownColor)
                }
            }

            Spacer()

            // Kill button
            Button(action: onKill) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.red.opacity(0.7))
            }
            .buttonStyle(.plain)
            .cursor(.pointingHand)
            .help("Kill this process")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var countdownColor: Color {
        let remaining = process.autoKillCountdown(timeout: autoKillTimeout)
        if remaining < 30 { return .red }
        if remaining < 60 { return .orange }
        return .secondary
    }

    private var iconName: String {
        let desc = process.processDescription.lowercased()
        if desc.contains("typescript") || desc.contains("tsserver") { return "chevron.left.forwardslash.chevron.right" }
        if desc.contains("diagnostics") { return "stethoscope" }
        if desc.contains("npm") { return "shippingbox" }
        if desc.contains("node") { return "circle.hexagongrid" }
        return "gearshape"
    }

    private var iconColor: Color {
        let desc = process.processDescription.lowercased()
        if desc.contains("typescript") { return .blue }
        if desc.contains("diagnostics") { return .orange }
        return .gray
    }
}

// MARK: - Cursor modifier

extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        onHover { inside in
            if inside { cursor.push() } else { NSCursor.pop() }
        }
    }
}
