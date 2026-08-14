import Combine
import Foundation

/// What one terminal pane is currently running, condensed to what a status bar
/// can show: how many jobs, what the busiest one is, and what they cost.
struct PaneActivity: Equatable, Identifiable {
    let paneID: UUID
    let paneTitle: String
    let jobCount: Int
    /// Description of the busiest job, or nil if none could be named.
    let topJob: String?
    let cpuPercent: Double
    let memoryBytes: UInt64

    var id: UUID { paneID }

    /// Something is actively burning CPU, rather than a watcher parked at zero
    /// holding memory. Both are worth listing; only one is worth colouring.
    var isBusy: Bool { cpuPercent >= 5 }

    var formattedCPU: String { "\(Int(cpuPercent.rounded()))%" }

    var formattedMemory: String {
        ByteCountFormatter.string(fromByteCount: Int64(memoryBytes), countStyle: .memory)
    }

    /// "npm run dev", or "npm run dev +2" when other jobs run alongside it.
    /// Falls back to a bare count when nothing could be named — which already
    /// states how many there are, so no "+n" is appended to it.
    var summary: String {
        guard let topJob else { return "\(jobCount) job\(jobCount == 1 ? "" : "s")" }
        return jobCount > 1 ? "\(topJob) +\(jobCount - 1)" : topJob
    }
}

/// Every pane's running work, in one place.
///
/// A pane's `ProcessMonitor` knows what that pane is running, but the status
/// bar renders only the *active* pane's monitor — so a deploy in another tab
/// used to be completely invisible, which is exactly the job you most want a
/// warning about. Rather than wiring every view to every pane's monitor, each
/// monitor pushes a small snapshot here after it polls, and the views that
/// care observe this one object.
///
/// Main thread only; the mutators bounce there themselves, since monitors poll
/// on a utility queue and tear down from `deinit`.
final class ActivityRegistry: ObservableObject {
    static let shared = ActivityRegistry()

    /// Keyed by `ProcessMonitor.id`. Panes with nothing running are absent
    /// rather than present-and-empty, so an idle app publishes nothing at all
    /// and never re-renders the status bar.
    @Published private(set) var panes: [UUID: PaneActivity] = [:]

    private init() {}

    func update(_ activity: PaneActivity) {
        onMain { [weak self] in
            guard let self, self.panes[activity.paneID] != activity else { return }
            self.panes[activity.paneID] = activity
        }
    }

    func clear(paneID: UUID) {
        onMain { [weak self] in
            guard let self, self.panes[paneID] != nil else { return }
            self.panes.removeValue(forKey: paneID)
        }
    }

    /// Work running in panes other than the given one, busiest first.
    func elsewhere(than paneID: UUID) -> [PaneActivity] {
        panes.values
            .filter { $0.paneID != paneID }
            .sorted { $0.cpuPercent > $1.cpuPercent }
    }

    /// Whether any of these panes has work running — drives the tab-strip dot.
    func hasWork(in paneIDs: [UUID]) -> Bool {
        paneIDs.contains { panes[$0] != nil }
    }

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }
}
