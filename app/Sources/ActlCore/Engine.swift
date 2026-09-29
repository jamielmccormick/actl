// The engine client: runs the bundled `actl` binary (or `ACTL_ENGINE`) via Process,
// decodes envelopes, and streams JSON Lines for long-running commands.

import Foundation

public enum EngineError: Error, LocalizedError, Sendable, Equatable {
    case notFound(searched: [String])
    case failed(command: String, exitCode: Int32, stderr: String)
    case decoding(command: String, message: String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .notFound(let searched):
            return "The actl engine could not be found. Looked in: \(searched.joined(separator: ", "))."
        case .failed(let command, let code, let stderr):
            let msg = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let clean = msg.hasPrefix("actl: ") ? String(msg.dropFirst(6)) : msg
            return clean.isEmpty ? "actl \(command) exited with code \(code)." : clean
        case .decoding(let command, let message):
            return "actl \(command) returned something the app could not read: \(message)"
        case .cancelled:
            return "Cancelled."
        }
    }
}

/// Anything that can answer engine commands. `ProcessEngine` runs the binary; `FixtureEngine` replays demo data.
public protocol Engine: Sendable {
    /// Runs a state command and returns stdout.
    func run(_ args: [String]) async throws -> Data
    /// Runs a long command and yields one stdout line at a time (JSON Lines).
    func stream(_ args: [String]) -> AsyncThrowingStream<String, Error>
}

public extension Engine {
    func envelope<T: Decodable & Sendable>(_ type: T.Type, _ args: [String]) async throws -> Envelope<T> {
        let data = try await run(args)
        do {
            return try JSONDecoder().decode(Envelope<T>.self, from: data)
        } catch {
            throw EngineError.decoding(command: args.joined(separator: " "), message: String(describing: error))
        }
    }

    func events<E: Decodable & Sendable>(_ type: E.Type, _ args: [String]) -> AsyncThrowingStream<E, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in stream(args) {
                        guard let event = JSONLParser.decode(E.self, line: line) else { continue }
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - JSON Lines

/// Incremental splitter for JSON Lines arriving in arbitrary chunks. Keeps a partial trailing line.
public struct JSONLParser: Sendable {
    private var buffer = Data()

    public init() {}

    /// Feed a chunk and get back every complete line it closed (trimmed, non-empty).
    public mutating func feed(_ chunk: Data) -> [String] {
        buffer.append(chunk)
        var lines: [String] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            if let s = String(data: lineData, encoding: .utf8) {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { lines.append(t) }
            }
        }
        return lines
    }

    /// Flush a final line without a trailing newline.
    public mutating func finish() -> [String] {
        defer { buffer.removeAll() }
        guard let s = String(data: buffer, encoding: .utf8) else { return [] }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? [] : [t]
    }

    /// Decode one line, ignoring lines that are not JSON objects (progress noise from CLIs).
    public static func decode<E: Decodable>(_ type: E.Type, line: String) -> E? {
        guard line.hasPrefix("{") else { return nil }
        return try? JSONDecoder().decode(E.self, from: Data(line.utf8))
    }
}

// MARK: - Process engine

public struct EngineLocation: Sendable {
    public var executable: URL
    public var prefixArgs: [String]
    public init(executable: URL, prefixArgs: [String] = []) { self.executable = executable; self.prefixArgs = prefixArgs }
}

public final class ProcessEngine: Engine {
    public let location: EngineLocation
    public let environment: [String: String]

    public init(location: EngineLocation, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.location = location
        self.environment = environment
    }

    /// Resolution order: `ACTL_ENGINE` (may include arguments, e.g. `bun /path/src/actl.ts`),
    /// the bundled `Contents/Resources/actl`, `build/actl` beside a dev checkout, then `~/.local/bin/actl`.
    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment, bundleResources: URL? = Bundle.main.resourceURL) -> Result<EngineLocation, EngineError> {
        var searched: [String] = []
        if let override = environment["ACTL_ENGINE"], !override.trimmingCharacters(in: .whitespaces).isEmpty {
            let parts = override.split(separator: " ").map(String.init)
            let exe = resolveOnPath(parts[0], environment: environment)
            searched.append(override)
            if let exe { return .success(EngineLocation(executable: exe, prefixArgs: Array(parts.dropFirst()))) }
        }
        let fm = FileManager.default
        var candidates: [URL] = []
        if let bundleResources { candidates.append(bundleResources.appendingPathComponent("actl")) }
        let exeDir = Bundle.main.executableURL?.deletingLastPathComponent()
        if let exeDir {
            // `swift run` from app/: .build/<config>/actl-app -> ../../build/actl
            candidates.append(exeDir.appendingPathComponent("../../../build/actl").standardizedFileURL)
            candidates.append(exeDir.appendingPathComponent("../../build/actl").standardizedFileURL)
        }
        candidates.append(fm.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/actl"))
        for c in candidates {
            searched.append(c.path)
            if fm.isExecutableFile(atPath: c.path) { return .success(EngineLocation(executable: c)) }
        }
        return .failure(.notFound(searched: searched))
    }

    private static func resolveOnPath(_ name: String, environment: [String: String]) -> URL? {
        let fm = FileManager.default
        if name.contains("/") {
            let expanded = (name as NSString).expandingTildeInPath
            return fm.isExecutableFile(atPath: expanded) ? URL(fileURLWithPath: expanded) : nil
        }
        let path = enginePath(environment: environment)
        for dir in path.split(separator: ":").map(String.init) {
            let p = (dir as NSString).appendingPathComponent(name)
            if fm.isExecutableFile(atPath: p) { return URL(fileURLWithPath: p) }
        }
        return nil
    }

    /// The PATH the engine runs with. Launched from a terminal, it is the terminal's PATH untouched (so the
    /// user's own tool order wins). Launched from Finder or launchd, the PATH is minimal, so the login shell's
    /// PATH is read once and used instead. Common tool dirs are appended, never prepended.
    public static func enginePath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let cached = cachedPath { return cached }
        let home = NSHomeDirectory()
        var path = environment["PATH"] ?? "/usr/bin:/bin"
        let minimal = !path.contains("/opt/homebrew/bin") && !path.contains("\(home)/.local/bin") && !path.contains("/usr/local/bin")
        if minimal, let login = loginShellPath(), !login.isEmpty { path = login }
        var parts = path.split(separator: ":").map(String.init)
        for extra in ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.bun/bin"] where !parts.contains(extra) { parts.append(extra) }
        let result = parts.joined(separator: ":")
        cachedPath = result
        return result
    }

    nonisolated(unsafe) private static var cachedPath: String?

    private static func loginShellPath() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-lic", "echo -n \"$PATH\""]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)?.split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func makeProcess(_ args: [String]) -> (Process, Pipe, Pipe) {
        let p = Process()
        p.executableURL = location.executable
        p.arguments = location.prefixArgs + args
        var env = environment
        env["PATH"] = ProcessEngine.enginePath(environment: environment)
        env["NO_COLOR"] = "1"
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        return (p, out, err)
    }

    public func run(_ args: [String]) async throws -> Data {
        let (process, out, err) = makeProcess(args)
        let command = args.joined(separator: " ")
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                let outHandle = out.fileHandleForReading
                let errHandle = err.fileHandleForReading
                process.terminationHandler = { proc in
                    let stdout = outHandle.readDataToEndOfFile()
                    let stderr = String(data: errHandle.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    if proc.terminationStatus == 0 {
                        cont.resume(returning: stdout)
                    } else {
                        cont.resume(throwing: EngineError.failed(command: command, exitCode: proc.terminationStatus, stderr: stderr))
                    }
                }
                do {
                    try process.run()
                } catch {
                    cont.resume(throwing: EngineError.failed(command: command, exitCode: -1, stderr: error.localizedDescription))
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    public func stream(_ args: [String]) -> AsyncThrowingStream<String, Error> {
        let (process, out, err) = makeProcess(args)
        let command = args.joined(separator: " ")
        return AsyncThrowingStream { continuation in
            let state = StreamState()
            out.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    return
                }
                for line in state.feed(chunk) { continuation.yield(line) }
            }
            process.terminationHandler = { proc in
                out.fileHandleForReading.readabilityHandler = nil
                let rest = out.fileHandleForReading.readDataToEndOfFile()
                for line in state.feed(rest) + state.finish() { continuation.yield(line) }
                let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if proc.terminationStatus == 0 || proc.terminationReason == .uncaughtSignal {
                    continuation.finish()
                } else {
                    continuation.finish(throwing: EngineError.failed(command: command, exitCode: proc.terminationStatus, stderr: stderr))
                }
            }
            continuation.onTermination = { _ in
                if process.isRunning { process.terminate() }
            }
            do {
                try process.run()
            } catch {
                continuation.finish(throwing: EngineError.failed(command: command, exitCode: -1, stderr: error.localizedDescription))
            }
        }
    }
}

/// Serialises the line parser across the readability handler and the termination handler.
private final class StreamState: @unchecked Sendable {
    private let lock = NSLock()
    private var parser = JSONLParser()
    func feed(_ d: Data) -> [String] { lock.lock(); defer { lock.unlock() }; return parser.feed(d) }
    func finish() -> [String] { lock.lock(); defer { lock.unlock() }; return parser.finish() }
}
