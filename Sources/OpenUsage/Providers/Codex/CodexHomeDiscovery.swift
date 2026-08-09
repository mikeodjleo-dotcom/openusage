import Foundation

/// Finds extra file-backed Codex homes kept beside the default login (for example
/// `~/.codex-cli2`). Discovery only reads account metadata already present in `auth.json`; it never
/// copies credentials or opens the macOS keychain.
struct CodexHomeDiscovery {
    struct Finding: Equatable, Sendable {
        var identityKey: String
        var label: String?
        var anchorPath: String
    }

    struct Result: Sendable {
        var findings: [Finding] = []
        var notes: [String] = []
    }

    var environment: EnvironmentReading
    var files: TextFileAccessing
    var homeDirectory: @Sendable () -> URL
    var listSubdirectories: @Sendable (URL) -> [URL]
    var timeBudget: TimeInterval
    var now: @Sendable () -> Date

    init(
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        files: TextFileAccessing = LocalTextFileAccessor(),
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser },
        listSubdirectories: @escaping @Sendable (URL) -> [URL] = Self.filesystemSubdirectories,
        timeBudget: TimeInterval = 0.4,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.environment = environment
        self.files = files
        self.homeDirectory = homeDirectory
        self.listSubdirectories = listSubdirectories
        self.timeBudget = timeBudget
        self.now = now
    }

    func run() -> Result {
        let started = now()
        var result = Result()
        let excluded = Set(defaultHomes().map(canonical))

        for candidate in candidateDirectories() {
            if now().timeIntervalSince(started) > timeBudget {
                result.notes.append("codex home scan hit its \(Int(timeBudget * 1000))ms budget; finishing with partial results")
                break
            }
            guard !excluded.contains(canonical(candidate.path)) else { continue }
            guard files.exists(candidate.path + "/auth.json") else { continue }
            if let finding = finding(at: candidate, notes: &result.notes) {
                result.findings.append(finding)
            }
        }
        return result
    }

    private func finding(at url: URL, notes: inout [String]) -> Finding? {
        let authPath = url.path + "/auth.json"
        guard let text = try? files.readText(authPath),
              let auth = CodexAuthStore.parseAuth(text),
              auth.tokens?.accessToken?.nilIfEmpty != nil
        else {
            notes.append("codex candidate \(logPath(url.path)): auth present but no usable OAuth credential → skipped")
            return nil
        }

        let payload = auth.tokens?.idToken.flatMap { ProviderParse.jwtPayload($0) }
        let rawIdentity = auth.tokens?.accountID?.nilIfEmpty
            ?? DefaultAccountObserver.chatGPTAccountID(inIDTokenPayload: payload)
        guard let identityKey = rawIdentity?.lowercased() else {
            notes.append("codex candidate \(logPath(url.path)): credential names no account → skipped")
            return nil
        }
        let email = (payload?["email"] as? String)?.nilIfEmpty
        notes.append("codex candidate \(logPath(url.path)): accepted (\(hash8(identityKey)))")
        return Finding(identityKey: identityKey, label: email, anchorPath: url.path)
    }

    /// Bounded scan: dot-directories in the user's home and direct children of `~/.config`.
    private func candidateDirectories() -> [URL] {
        let home = homeDirectory()
        var candidates = listSubdirectories(home).filter { $0.lastPathComponent.hasPrefix(".") }
        candidates += listSubdirectories(home.appendingPathComponent(".config"))
        return candidates.sorted { $0.path < $1.path }
    }

    private static func filesystemSubdirectories(of url: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )) ?? []
        return contents.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
    }

    private func defaultHomes() -> [String] {
        if let configured = environment.value(for: "CODEX_HOME")?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            return [expandTilde(configured)]
        }
        let home = homeDirectory().path
        return [home + "/.config/codex", home + "/.codex"]
    }

    private func expandTilde(_ path: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        return homeDirectory().path + String(path.dropFirst(1))
    }

    private func canonical(_ path: String) -> String {
        URL(fileURLWithPath: expandTilde(path)).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func logPath(_ path: String) -> String {
        let home = homeDirectory().path
        guard path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    private func hash8(_ identityKey: String) -> String {
        String(ProviderAccountID.make(family: "codex", identityKey: identityKey).dropFirst("codex@".count))
    }
}
