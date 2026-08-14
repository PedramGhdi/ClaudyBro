import SwiftUI

/// Bottom status strip with orphan detail popover.
struct StatusBarView: View {
    @ObservedObject var processMonitor: ProcessMonitor
    let shellPID: pid_t

    @ObservedObject private var activity = ActivityRegistry.shared
    @State private var showOrphanPanel = false
    @State private var showChildPanel = false
    @State private var showElsewherePanel = false
    @State private var tick = Date()

    private let textColor = Color(nsColor: Constants.statusTextColor)
    private let countdownTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// Work running in this pane, if any.
    private var localActivity: PaneActivity? { activity.panes[processMonitor.id] }

    /// Work running in every *other* pane and tab — the deploy you left in tab
    /// 3 and forgot about.
    private var elsewhere: [PaneActivity] { activity.elsewhere(than: processMonitor.id) }

    var body: some View {
        ZStack {
            // Left-aligned: PID + what this pane is running
            HStack(spacing: 12) {
                if shellPID > 0 {
                    label("PID \(shellPID)")
                }

                // A job the user can see the cost of outranks a bare count of
                // children: "3 child processes" never said what was running or
                // what it was costing, which is the whole question.
                let childCount = processMonitor.childProcesses.count
                if let local = localActivity {
                    activityChip(local)
                } else if childCount > 0 {
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

            // Right-aligned: other panes' work, then orphans
            HStack(spacing: 10) {
                Spacer()
                if !elsewhere.isEmpty {
                    elsewhereBadge
                }
                if !processMonitor.orphanedProcesses.isEmpty {
                    orphanBadge
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(height: 24)
        .background(Color(nsColor: AppConfiguration.shared.currentTheme.statusBarBackground))
        .onReceive(countdownTimer) { newTick in
            // Only update tick when orphans exist — avoids unnecessary re-renders
            if !processMonitor.orphanedProcesses.isEmpty { tick = newTick }
        }
    }

    // MARK: - Running Work (this pane)

    /// Names the busiest job in this pane and what it is costing. Green dot
    /// when it is actually burning CPU, dim when it is a watcher sitting idle
    /// holding memory — that still costs something, so it still shows.
    private func activityChip(_ local: PaneActivity) -> some View {
        Button(action: { showChildPanel.toggle() }) {
            HStack(spacing: 6) {
                Circle()
                    .fill(local.isBusy ? Color.green : textColor.opacity(0.55))
                    .frame(width: 6, height: 6)

                Text(local.summary)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(textColor)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text("\(local.formattedCPU) · \(local.formattedMemory)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(local.isBusy ? .green : textColor.opacity(0.7))
                    .fixedSize()
            }
            // Keep a long command from colliding with the centred context read-out.
            .frame(maxWidth: 320, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cursor(.pointingHand)
        .help("\(local.jobCount) running — \(local.formattedCPU) CPU, \(local.formattedMemory). Click for details.")
        .popover(isPresented: $showChildPanel, arrowEdge: .top) {
            ChildProcessPanel(processMonitor: processMonitor)
        }
    }

    // MARK: - Running Work (other panes and tabs)

    private var elsewhereBadge: some View {
        let others = elsewhere
        let jobs = others.reduce(0) { $0 + $1.jobCount }
        let cpu = others.reduce(0.0) { $0 + $1.cpuPercent }
        let busy = cpu >= 5
        let color = busy ? Color.green : textColor

        return Button(action: { showElsewherePanel.toggle() }) {
            HStack(spacing: 5) {
                Image(systemName: "rectangle.stack")
                    .font(.system(size: 10))
                Text("\(jobs) running elsewhere")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                if busy {
                    Text("\(Int(cpu.rounded()))%")
                        .font(.system(size: 11, design: .monospaced))
                }
            }
            .foregroundColor(color)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cursor(.pointingHand)
        .help("Work running in other panes and tabs. Click for details.")
        .popover(isPresented: $showElsewherePanel, arrowEdge: .top) {
            ElsewhereActivityPanel(activities: others)
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

// MARK: - Elsewhere Activity Panel (popover content)

/// Lists what the panes and tabs the user is *not* looking at are running.
struct ElsewhereActivityPanel: View {
    let activities: [PaneActivity]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Running in Other Panes")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(activities.reduce(0) { $0 + $1.jobCount }) total")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(activities) { pane in
                        HStack(spacing: 10) {
                            Circle()
                                .fill(pane.isBusy ? Color.green : Color.secondary.opacity(0.5))
                                .frame(width: 7, height: 7)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(pane.summary)
                                    .font(.system(size: 12, weight: .medium))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(pane.paneTitle.isEmpty ? "Shell" : pane.paneTitle)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                            }

                            Spacer()

                            Text("\(pane.formattedCPU) · \(pane.formattedMemory)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(pane.isBusy ? .green : .secondary)
                                .fixedSize()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)

                        Divider().padding(.leading, 33)
                    }
                }
            }
            .frame(maxHeight: 260)

            Text("Switch tabs with ⌘1–⌘9 or ⌘⇧] to reach these.")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
        .frame(width: 340)
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
                            ChildProcessRow(process: process, onPin: {
                                processMonitor.togglePin(for: process.pid)
                            }, onKill: {
                                processMonitor.killProcess(process.pid)
                            })
                            Divider().padding(.leading, 40)
                        }
                    }
                }
                .frame(maxHeight: 300)

                Divider()

                HStack {
                    Text(totalsText)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
        .frame(width: 380)
    }

    /// What this pane's whole process tree currently costs.
    private var totalsText: String {
        let procs = processMonitor.childProcesses
        let cpu = procs.reduce(0.0) { $0 + $1.cpuPercent }
        let bytes = procs.reduce(UInt64(0)) { $0 + $1.memoryBytes }
        let memory = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
        return "Total: \(Int(cpu.rounded()))% CPU · \(memory)"
    }
}

// MARK: - Child Process Row

struct ChildProcessRow: View {
    let process: TrackedProcess
    let onPin: () -> Void
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

                    if process.cpuPercent >= 0.1 {
                        Text(process.formattedCPU)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(process.cpuPercent >= 25 ? .orange : .secondary)
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

                    if process.isPinned {
                        Text("PINNED")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundColor(.yellow)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.yellow.opacity(0.15))
                            .cornerRadius(3)
                    }
                }
            }

            Spacer()

            Button(action: onPin) {
                Image(systemName: process.isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 14))
                    .foregroundColor(process.isPinned ? .yellow : .gray.opacity(0.5))
            }
            .buttonStyle(.plain)
            .cursor(.pointingHand)
            .help(process.isPinned ? "Unpin — allow auto-kill" : "Pin — prevent auto-kill")

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
