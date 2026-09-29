// Reads and writes the `[scan]` table of ~/.config/actl/config.toml without disturbing anything else.
// Deliberately narrow: only `roots` and `workspaces` string arrays are edited, and the rest of the file is preserved.

import Foundation

public struct ScanConfig: Sendable, Hashable {
    public var roots: [String]
    public var workspaces: [String]
    public init(roots: [String] = [], workspaces: [String] = []) { self.roots = roots; self.workspaces = workspaces }
}

public enum ConfigFile {
    public static var defaultPath: URL {
        let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
        let base = xdg.map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return base.appendingPathComponent("actl/config.toml")
    }

    public static func readScan(from text: String) -> ScanConfig {
        var cfg = ScanConfig()
        var inScan = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inScan = line == "[scan]"; continue }
            guard inScan, !line.hasPrefix("#") else { continue }
            if let eq = line.firstIndex(of: "=") {
                let key = line[..<eq].trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                let list = parseArray(value)
                if key == "roots" { cfg.roots = list } else if key == "workspaces" { cfg.workspaces = list }
            }
        }
        return cfg
    }

    public static func load(at url: URL = defaultPath) -> ScanConfig {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return ScanConfig() }
        return readScan(from: text)
    }

    /// Rewrites the `[scan]` table in `text`, keeping every other table intact.
    public static func writeScan(_ cfg: ScanConfig, into text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        let block = renderScan(cfg)
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "[scan]" }) else {
            let sep = lines.isEmpty ? [] : [""]
            return (lines + sep + block).joined(separator: "\n") + "\n"
        }
        var end = start + 1
        while end < lines.count, !lines[end].trimmingCharacters(in: .whitespaces).hasPrefix("[") { end += 1 }
        // Keep comments and unknown keys inside [scan].
        let kept = lines[(start + 1)..<end].filter { l in
            let t = l.trimmingCharacters(in: .whitespaces)
            return !(t.hasPrefix("roots") || t.hasPrefix("workspaces")) && !t.isEmpty
        }
        lines.replaceSubrange(start..<end, with: ["[scan]"] + block.dropFirst() + kept + [""])
        return lines.joined(separator: "\n") + "\n"
    }

    public static func save(_ cfg: ScanConfig, at url: URL = defaultPath) throws {
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let out = writeScan(cfg, into: existing)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try out.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func renderScan(_ cfg: ScanConfig) -> [String] {
        var out = ["[scan]"]
        if !cfg.roots.isEmpty { out.append("roots = [" + cfg.roots.map { "\"\($0)\"" }.joined(separator: ", ") + "]") }
        if !cfg.workspaces.isEmpty { out.append("workspaces = [" + cfg.workspaces.map { "\"\($0)\"" }.joined(separator: ", ") + "]") }
        return out
    }

    private static func parseArray(_ v: String) -> [String] {
        guard v.hasPrefix("["), let close = v.lastIndex(of: "]") else { return [] }
        let inner = v[v.index(after: v.startIndex)..<close]
        return inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }.filter { !$0.isEmpty }
    }
}
