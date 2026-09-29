// Fictional demo data that follows docs/engine-contract.md. Never real data.
// `FixtureEngine` answers every engine command from the JSON files in `json/` and
// simulates the JSONL streams for `apply`, `undo` and `login --json`.

import ActlCore
import Foundation

public final class FixtureEngine: Engine {
    public let delay: Duration
    /// Optional variant: `status-<variant>.json` / `proxy-<variant>.json` override the defaults when present.
    public let variant: String?

    public init(delay: Duration = .milliseconds(120), variant: String? = nil) {
        self.delay = delay
        self.variant = variant
    }

    public static func data(_ name: String) -> Data? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "json") else { return nil }
        return try? Data(contentsOf: url)
    }

    public static func envelope(_ command: String, _ name: String) -> Data? {
        guard let inner = data(name) else { return nil }
        var s = "{\"schema\":2,\"command\":\"\(command)\",\"generatedAt\":\"\(ISO8601.string(Date()))\",\"data\":"
        s += String(decoding: inner, as: UTF8.self)
        s += "}"
        return Data(s.utf8)
    }

    public func run(_ args: [String]) async throws -> Data {
        try await Task.sleep(for: delay)
        let command = args.first ?? ""
        let name: String
        switch command {
        case "status": name = "status"
        case "inventory": name = "inventory"
        case "services": name = "services"
        case "budget": name = "budget"
        case "proxy": name = "proxy"
        case "plan": name = "plan"
        case "activity": name = "activity"
        case "manifest": name = args.dropFirst().first == "adopt" ? "manifest-adopt" : "manifest-show"
        default:
            throw EngineError.failed(command: args.joined(separator: " "), exitCode: 2, stderr: "actl: unknown command \"\(command)\"")
        }
        if let variant, let d = Self.envelope(args.joined(separator: " "), "\(name)-\(variant)") { return d }
        guard let d = Self.envelope(args.joined(separator: " "), name) else {
            throw EngineError.failed(command: args.joined(separator: " "), exitCode: 2, stderr: "actl: fixture \(name).json is missing")
        }
        return d
    }

    public func stream(_ args: [String]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    switch args.first {
                    case "apply": try await self.simulateApply(Array(args.dropFirst()), continuation: continuation)
                    case "undo": try await self.simulateUndo(continuation: continuation)
                    case "login": try await self.simulateLogin(Array(args.dropFirst()), continuation: continuation)
                    default: continuation.yield(#"{"type":"error","message":"unknown command"}"#)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func simulateApply(_ ids: [String], continuation: AsyncThrowingStream<String, Error>.Continuation) async throws {
        let runId = "2026-09-28T2153-\(Int.random(in: 100...999))"
        let actionIds = ids == ["--all"] ? ["instructions.rescope:argent", "skills.sync:user", "services.disable-mcp:hubspot", "mcp.add:codex:creative-production", "proxy.update"] : ids
        continuation.yield(#"{"type":"start","runId":"\#(runId)","actions":\#(json(actionIds))}"#)
        try await Task.sleep(for: .milliseconds(500))
        continuation.yield(#"{"type":"backup","runId":"\#(runId)","files":["~/.claude/rules/argent.md","~/.claude.json","~/.codex/config.toml","~/.claude/skills/.actl-sync.json"],"dir":"~/.config/actl/backups/\#(runId)"}"#)
        for (i, id) in actionIds.enumerated() {
            try await Task.sleep(for: .milliseconds(400))
            continuation.yield(#"{"type":"step","runId":"\#(runId)","actionId":"\#(id)","state":"running"}"#)
            try await Task.sleep(for: .milliseconds(i == 2 ? 1400 : 900))
            let msg = id.hasPrefix("proxy") ? "Restarted the proxy in 2.8 s" : "Done"
            continuation.yield(#"{"type":"step","runId":"\#(runId)","actionId":"\#(id)","state":"ok","message":"\#(msg)"}"#)
        }
        try await Task.sleep(for: .milliseconds(300))
        continuation.yield(#"{"type":"done","runId":"\#(runId)","ok":\#(actionIds.count),"failed":0,"tookMs":6200}"#)
    }

    private func simulateUndo(continuation: AsyncThrowingStream<String, Error>.Continuation) async throws {
        let runId = "undo-\(Int.random(in: 100...999))"
        continuation.yield(#"{"type":"start","runId":"\#(runId)","actions":["restore"]}"#)
        try await Task.sleep(for: .milliseconds(600))
        continuation.yield(#"{"type":"step","runId":"\#(runId)","actionId":"restore","state":"running"}"#)
        try await Task.sleep(for: .milliseconds(900))
        continuation.yield(#"{"type":"step","runId":"\#(runId)","actionId":"restore","state":"ok","message":"Restored 4 files from the backup"}"#)
        continuation.yield(#"{"type":"done","runId":"\#(runId)","ok":1,"failed":0,"tookMs":1500}"#)
    }

    private func simulateLogin(_ args: [String], continuation: AsyncThrowingStream<String, Error>.Continuation) async throws {
        let harness = args.first ?? "claude"
        let server = args.dropFirst().first ?? "server"
        continuation.yield(#"{"type":"opening","harness":"\#(harness)","server":"\#(server)"}"#)
        try await Task.sleep(for: .milliseconds(700))
        continuation.yield(#"{"type":"waiting","harness":"\#(harness)","server":"\#(server)"}"#)
        try await Task.sleep(for: .seconds(server.contains("zoom") ? 1 : 3))
        if server.contains("zoom") {
            continuation.yield(#"{"type":"done","harness":"\#(harness)","server":"\#(server)","ok":false,"message":"Zoom needs an API token, not a browser sign-in"}"#)
        } else {
            continuation.yield(#"{"type":"done","harness":"\#(harness)","server":"\#(server)","ok":true,"message":"14 tools · 3 skills · parity with Codex"}"#)
        }
    }

    private func json(_ list: [String]) -> String {
        "[" + list.map { "\"\($0)\"" }.joined(separator: ",") + "]"
    }
}
