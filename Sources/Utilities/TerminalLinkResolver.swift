import Foundation

/// What a clicked terminal link actually points at.
enum TerminalLink: Equatable {
    case file(URL, isDirectory: Bool)
    case web(URL)
    case unresolved
}

/// Classifies the strings SwiftTerm hands to `requestOpenLink`.
///
/// SwiftTerm's implicit detector matches filesystem paths as readily as URLs —
/// `/abs/x`, `~/x`, `./x` and `src/file.swift` all arrive as bare strings with
/// no scheme. Anything that resolves to a real file or directory is a `.file`;
/// only what is left over is considered for the browser.
enum TerminalLinkResolver {
    static func resolve(_ raw: String, workingDirectory: String) -> TerminalLink {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unresolved }

        // A `file:` URL is a filesystem reference, so reveal it rather than
        // handing it to the default app. It never falls through to the browser.
        if let path = filePath(fromFileURL: trimmed) {
            return resolvePath(path, workingDirectory: workingDirectory) ?? .unresolved
        }

        if trimmed.contains("://") || trimmed.hasPrefix("mailto:") || trimmed.hasPrefix("tel:") {
            guard let url = URL(string: trimmed) else { return .unresolved }
            return .web(url)
        }

        if let file = resolvePath(trimmed, workingDirectory: workingDirectory) {
            return file
        }

        // Something that names itself a path has no business becoming a URL:
        // if it does not exist there is nothing to open.
        if isExplicitPath(trimmed) { return .unresolved }

        if looksLikeHostname(trimmed), let url = URL(string: "https://" + trimmed) {
            return .web(url)
        }

        return .unresolved
    }

    // MARK: - Filesystem

    private static func resolvePath(_ candidate: String, workingDirectory: String) -> TerminalLink? {
        for variant in pathVariants(of: candidate) {
            guard let absolute = absolutePath(variant, workingDirectory: workingDirectory) else { continue }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: absolute, isDirectory: &isDirectory) else { continue }
            return .file(URL(fileURLWithPath: absolute), isDirectory: isDirectory.boolValue)
        }
        return nil
    }

    /// Candidate spellings of a clicked path, most literal first.
    ///
    /// SwiftTerm's path pattern admits `:` and digits mid-match and only forbids
    /// a match *ending* on a colon, so compiler output like `Sources/Foo.swift:42:10`
    /// arrives with its location suffix attached. Prose likewise pulls in a
    /// trailing period: `see ~/foo/bar.txt.`
    private static func pathVariants(of candidate: String) -> [String] {
        var variants = [candidate]

        if let suffix = candidate.range(of: #":[0-9]+(:[0-9]+)?$"#, options: .regularExpression) {
            variants.append(String(candidate[..<suffix.lowerBound]))
        }

        var stripped = Substring(candidate)
        while let last = stripped.last, ".,;:)]}".contains(last) {
            stripped = stripped.dropLast()
        }
        if stripped.count != candidate.count { variants.append(String(stripped)) }

        var seen = Set<String>()
        return variants.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Absolute, `..`-free form of a path, or nil when a relative path cannot be
    /// anchored because the shell's working directory is not yet known.
    private static func absolutePath(_ path: String, workingDirectory: String) -> String? {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded).standardized.path
        }
        guard workingDirectory.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: workingDirectory)
            .appendingPathComponent(expanded).standardized.path
    }

    private static func isExplicitPath(_ candidate: String) -> Bool {
        candidate.hasPrefix("/") || candidate.hasPrefix("~/") || candidate == "~"
            || candidate.hasPrefix("./") || candidate.hasPrefix("../")
    }

    /// Path behind a `file:` link, or nil if this is not one. SwiftTerm's scheme
    /// list carries the bare `file:` form alongside `file://`, and the manual
    /// fallback covers spellings `URL` rejects, such as an unencoded space.
    private static func filePath(fromFileURL link: String) -> String? {
        guard link.lowercased().hasPrefix("file:") else { return nil }

        if let url = URL(string: link), url.isFileURL, !url.path.isEmpty {
            return url.path
        }

        var rest = Substring(link.dropFirst("file:".count))
        if rest.hasPrefix("//") {
            rest = rest.dropFirst(2)
            if rest.hasPrefix("localhost/") { rest = rest.dropFirst("localhost".count) }
        }
        guard !rest.isEmpty else { return nil }
        return rest.removingPercentEncoding ?? String(rest)
    }

    // MARK: - Web

    /// Whether the first segment reads as a host — `github.com/user/repo` qualifies,
    /// `src/main.swift` does not. Without this test every unresolvable string became
    /// a URL, which is how clicking a backup file opened it in a browser.
    private static func looksLikeHostname(_ candidate: String) -> Bool {
        var host = candidate.prefix { $0 != "/" && $0 != "?" && $0 != "#" }

        if let colon = host.lastIndex(of: ":") {
            let port = host[host.index(after: colon)...]
            if !port.isEmpty, port.allSatisfy(\.isNumber) { host = host[..<colon] }
        }

        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }) else { return false }

        // Dotted-quad address, e.g. 127.0.0.1
        if labels.count == 4, labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) { return true }

        guard let tld = labels.last, tld.count >= 2, tld.allSatisfy(\.isLetter) else { return false }
        return labels.dropLast().allSatisfy { label in
            label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }
    }
}
