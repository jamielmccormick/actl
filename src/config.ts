// Where things live on this machine. Nothing here is specific to one user: tool homes follow each tool's
// own override variables, and scan roots and integrations come from an optional config file.
//
// Config: $XDG_CONFIG_HOME/actl/config.toml (default ~/.config/actl/config.toml)
//
//   [scan]
//   roots = ["~/Code", "~/Developer"]        # searched for git repos (default: common locations that exist)
//   workspaces = ["~/Documents/Notes"]       # children with an AGENTS.md/CLAUDE.md count as workspaces
//   max_depth = 3
//
//   [proxy]                                  # CLIProxyAPI (optional; off unless enabled or detected)
//   enabled = "auto"                         # "auto" | true | false
//   endpoint = "http://127.0.0.1:8317"
//   key_file = "~/.cli-proxy-api/management-key"
import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

export const HOME = homedir();
export const expand = (p: string) => (p === "~" ? HOME : p.startsWith("~/") ? join(HOME, p.slice(2)) : p);
export const tilde = (p: string) => (p.startsWith(HOME) ? `~${p.slice(HOME.length)}` : p);

// Claude Code keeps settings, skills and plugins in CLAUDE_CONFIG_DIR (default ~/.claude). Its user MCP
// config is ~/.claude.json by default, or .claude.json inside CLAUDE_CONFIG_DIR when that is set.
const claudeDir = process.env.CLAUDE_CONFIG_DIR ? expand(process.env.CLAUDE_CONFIG_DIR) : join(HOME, ".claude");
export const claudeHome = (...p: string[]) => join(claudeDir, ...p);
export const claudeJsonPath = process.env.CLAUDE_CONFIG_DIR ? join(claudeDir, ".claude.json") : join(HOME, ".claude.json");

const codexDir = process.env.CODEX_HOME ? expand(process.env.CODEX_HOME) : join(HOME, ".codex");
export const codexHome = (...p: string[]) => join(codexDir, ...p);

// The cross-tool Agent Skills location (agentskills.io), read natively by Codex.
export const agentsHome = (...p: string[]) => join(HOME, ".agents", ...p);

const configDir = join(process.env.XDG_CONFIG_HOME ? expand(process.env.XDG_CONFIG_HOME) : join(HOME, ".config"), "actl");
export const configPath = join(configDir, "config.toml");

const DEFAULT_ROOTS = ["~/Code", "~/Developer", "~/Projects", "~/src", "~/dev", "~/repos", "~/work", "~/GitHub"];

type RawConfig = {
  scan?: { roots?: string[]; workspaces?: string[]; max_depth?: number };
  proxy?: { enabled?: boolean | "auto"; endpoint?: string; key_file?: string };
};

function load(): RawConfig {
  if (!existsSync(configPath)) return {};
  try {
    return Bun.TOML.parse(readFileSync(configPath, "utf8")) as RawConfig;
  } catch (e) {
    process.stderr.write(`actl: ignoring unreadable ${tilde(configPath)}: ${String(e)}\n`);
    return {};
  }
}

const raw = load();

export const config = {
  path: configPath,
  exists: existsSync(configPath),
  scan: {
    roots: (raw.scan?.roots ?? DEFAULT_ROOTS).map(expand).filter((p) => existsSync(p)),
    workspaces: (raw.scan?.workspaces ?? []).map(expand).filter((p) => existsSync(p)),
    maxDepth: raw.scan?.max_depth ?? 3,
  },
  proxy: {
    enabled: raw.proxy?.enabled ?? ("auto" as const),
    endpoint: process.env.ACTL_CLIPROXY_ENDPOINT ?? raw.proxy?.endpoint ?? "http://127.0.0.1:8317",
    keyFile: expand(raw.proxy?.key_file ?? "~/.cli-proxy-api/management-key"),
  },
};
