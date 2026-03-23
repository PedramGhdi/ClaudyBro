import AppKit
import Foundation

/// Checks GitHub Releases for new versions of ClaudyBro.
final class UpdateChecker {
    static let shared = UpdateChecker()

    /// Set this to your GitHub repo (e.g., "username/ClaudyBro")
    var githubRepo: String = "PedramGhdi/ClaudyBro"

    private let currentVersion: String = {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }()

    /// Check GitHub releases for a newer version.
    func checkForUpdates(silent: Bool = false) {
        let urlString = "https://api.github.com/repos/\(githubRepo)/releases/latest"
        guard let url = URL(string: urlString) else { return }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self, let data,
                  let http = response as? HTTPURLResponse
            else {
                if !silent { self?.showError("Could not reach GitHub. Check your connection.") }
                return
            }

            if http.statusCode == 404 {
                if !silent { self.showError("No releases found yet on GitHub.") }
                return
            }

            guard http.statusCode == 200 else {
                if !silent { self.showError("GitHub returned status \(http.statusCode).") }
                return
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String,
                  let htmlURL = json["html_url"] as? String
            else {
                if !silent { self.showError("Could not parse release info.") }
                return
            }

            let latestVersion = tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))

            DispatchQueue.main.async {
                if self.isNewer(latestVersion, than: self.currentVersion) {
                    self.showUpdateAvailable(
                        current: self.currentVersion,
                        latest: latestVersion,
                        url: htmlURL
                    )
                } else if !silent {
                    self.showUpToDate()
                }
            }
        }.resume()
    }

    // MARK: - Private

    private func isNewer(_ latest: String, than current: String) -> Bool {
        latest.compare(current, options: .numeric) == .orderedDescending
    }

    private func showUpdateAvailable(current: String, latest: String, url: String) {
        let alert = NSAlert()
        alert.messageText = "Update Available"
        alert.informativeText = "ClaudyBro v\(latest) is available (you have v\(current))."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")

        if alert.runModal() == .alertFirstButtonReturn {
            if let downloadURL = URL(string: url) {
                NSWorkspace.shared.open(downloadURL)
            }
        }
    }

    private func showUpToDate() {
        let alert = NSAlert()
        alert.messageText = "You're Up to Date"
        alert.informativeText = "ClaudyBro v\(currentVersion) is the latest version."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showError(_ message: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Update Check Failed"
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}
