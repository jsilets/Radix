import Foundation

/// Runs a command-line tool and captures its output. Cleanup providers use it for
/// git, xcrun simctl, docker, and worktrunk.
nonisolated struct CommandResult: Sendable {
    let status: Int32
    let stdout: String
    let stderr: String

    var succeeded: Bool { status == 0 }
}

nonisolated enum CommandRunnerError: Error, LocalizedError {
    case notFound(String)
    case timedOut(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let tool): "\(tool) is not installed."
        case .timedOut(let command): "\(command) did not finish in time."
        }
    }
}

nonisolated enum CommandRunner {
    /// Folders searched for tools, in order. A GUI app does not inherit the shell PATH.
    static let searchPaths = [
        "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin",
        NSHomeDirectory() + "/.local/bin",
        "/Applications/Docker.app/Contents/Resources/bin"
    ]

    static func resolve(_ tool: String) -> String? {
        if tool.hasPrefix("/") { return FileManager.default.isExecutableFile(atPath: tool) ? tool : nil }
        return searchPaths
            .map { ($0 as NSString).appendingPathComponent(tool) }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func isAvailable(_ tool: String) -> Bool { resolve(tool) != nil }

    @concurrent
    static func run(
        _ tool: String,
        _ arguments: [String],
        in directory: URL? = nil,
        timeout: TimeInterval = 120
    ) async throws -> CommandResult {
        guard let executable = resolve(tool) else { throw CommandRunnerError.notFound(tool) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = directory }
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = searchPaths.joined(separator: ":")
        environment["GIT_TERMINAL_PROMPT"] = "0"
        // `git status` would otherwise rewrite the index and make every checkout look just used.
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = environment
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        // Read both pipes while the process runs so a large output cannot block it.
        async let stdoutData = Self.readAll(out.fileHandleForReading)
        async let stderrData = Self.readAll(err.fileHandleForReading)
        try process.run()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() > deadline {
                process.terminate()
                throw CommandRunnerError.timedOut(([tool] + arguments).joined(separator: " "))
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let stdout = String(decoding: await stdoutData, as: UTF8.self)
        let stderr = String(decoding: await stderrData, as: UTF8.self)
        return CommandResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    @concurrent
    private static func readAll(_ handle: FileHandle) async -> Data {
        (try? handle.readToEnd()) ?? Data()
    }
}
