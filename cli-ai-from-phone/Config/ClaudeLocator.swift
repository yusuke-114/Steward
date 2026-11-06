import Foundation

enum ClaudeInstallation: Equatable, Sendable {
    case ready(path: String, version: String)
    case missing
}

/// Locates Claude Code from the same locations a user expects in a terminal,
/// then verifies the candidate before the app is allowed to launch it.
enum ClaudeLocator {
    static func detect(preferredPath: String?) -> ClaudeInstallation {
        detect(
            preferredPath: preferredPath,
            shellOutput: shellClaudePath(),
            fallbackPaths: defaultCandidatePaths(),
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0) },
            version: installedVersion(at:)
        )
    }

    static func detect(
        preferredPath: String?,
        shellOutput: String?,
        fallbackPaths: [String],
        isExecutable: (String) -> Bool,
        version: (String) -> String?
    ) -> ClaudeInstallation {
        let shellPath = shellOutput?
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)

        var seen = Set<String>()
        // A path found through the user's login shell reflects the Claude
        // executable they run in Terminal. Prefer it over a previously stored
        // path, which can be an outdated version-manager shim after an update.
        let candidates = [shellPath, preferredPath] + fallbackPaths.map(Optional.some)

        for rawPath in candidates {
            guard let rawPath else { continue }
            let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty, seen.insert(path).inserted, isExecutable(path),
                  let detectedVersion = version(path), !detectedVersion.isEmpty else {
                continue
            }
            return .ready(path: path, version: detectedVersion)
        }
        return .missing
    }

    static func defaultCandidatePaths(homeDirectory: String = NSHomeDirectory()) -> [String] {
        [
            homeDirectory + "/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
    }

    private static func shellClaudePath() -> String? {
        shellClaudePath { executable, arguments in
            run(executable: executable, arguments: arguments)
        }
    }

    /// Resolves `claude` from the same interactive zsh environment used by
    /// Terminal. A login-only shell can put an old version-manager shim ahead
    /// of the executable the user actually runs.
    static func shellClaudePath(run: (String, [String]) -> String?) -> String? {
        run("/bin/zsh", ["-ic", "command -v claude"])
    }

    private static func installedVersion(at path: String) -> String? {
        run(executable: path, arguments: ["--version"])
    }

    private static func run(executable: String, arguments: [String]) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let value = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
