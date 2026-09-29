// A fictional home directory with Claude Code and Codex configured, plus stub `claude`, `codex` and `brew`
// binaries that log their argv and print canned output. The CLI runs as a subprocess pointed at it.
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";

const ROOT = join(import.meta.dir, "..");

const STUB = `#!/bin/bash
tool=$(basename "$0")
printf '%s\\n' "$tool $*" >> "$STUB_LOG"
key=$(printf '%s' "$*" | tr ' /' '__')
dir="$STUB_DIR/$tool"
code=0
[ -f "$dir/$key.exit" ] && code=$(cat "$dir/$key.exit")
[ -f "$dir/$key" ] && cat "$dir/$key"
exit $code
`;

const CLAUDE_MCP_LIST = `Checking MCP server health…

acme-docs: https://mcp.acme.dev/mcp (HTTP) - ✔ Connected
old-wiki: https://wiki.example.com/mcp (HTTP) - ✔ Connected
plugin:sentry:sentry: https://mcp.sentry.dev/mcp?utm_source=plugin (HTTP) - ! Needs authentication
plugin:meet:meet-a: https://a.meet.example.com/mcp (HTTP) - ✘ Failed to connect
plugin:meet:meet-b: https://b.meet.example.com/mcp (HTTP) - ✔ Connected

claude.ai connectors are disabled because ANTHROPIC_BASE_URL is set.
`;

const CODEX_MCP_LIST = JSON.stringify([
  { name: "sentry", enabled: true, auth_status: "o_auth", transport: { type: "streamable_http", url: "https://mcp.sentry.dev/mcp" } },
  { name: "linear", enabled: true, auth_status: "not_logged_in", transport: { type: "streamable_http", url: "https://mcp.linear.app/mcp" } },
]);

const CODEX_PLUGIN_LIST = `Marketplace \`openai-curated-remote\`
Remote catalog

PLUGIN                               STATUS              VERSION  SOURCE
gmail@openai-curated-remote          installed, enabled  0.1.0    plugin_connector_1p_aaaa
templates@openai-curated-remote      installed, enabled  1.0.0    plugin_connector_1p_bbbb
`;

const skill = (name: string, description: string, body = "") => `---\nname: ${name}\ndescription: ${description}\n---\n${body}`;

export type Fixture = ReturnType<typeof makeFixture>;

export function makeFixture() {
  const root = mkdtempSync(join(tmpdir(), "actl-test-"));
  const home = join(root, "home");
  const bin = join(root, "bin");
  const stubs = join(root, "stubs");
  const log = join(root, "stub.log");
  const write = (rel: string, content: string) => {
    const p = rel.startsWith("/") ? rel : join(home, rel);
    mkdirSync(dirname(p), { recursive: true });
    writeFileSync(p, content);
    return p;
  };
  const read = (rel: string) => readFileSync(rel.startsWith("/") ? rel : join(home, rel), "utf8");
  const stub = (tool: string, args: string, out: string, exit?: number) => {
    const key = args.replace(/[ /]/g, "_");
    write(join(stubs, tool, key), out);
    if (exit !== undefined) write(join(stubs, tool, `${key}.exit`), String(exit));
  };

  for (const tool of ["claude", "codex", "brew"]) {
    write(join(bin, tool), STUB);
    chmodSync(join(bin, tool), 0o755);
  }
  writeFileSync(log, "");
  stub("claude", "--version", "2.1.283 (Claude Code)\n");
  stub("claude", "mcp list", CLAUDE_MCP_LIST);
  stub("claude", "plugin details sentry@claude-plugins-official", "sentry 1.4.0\n\nProjected token cost\n  Always-on:   ~1,234 tok   added to every session\n");
  stub("codex", "--version", "codex-cli 0.158.0\n");
  stub("codex", "mcp list --json", CODEX_MCP_LIST);
  stub("codex", "plugin list", CODEX_PLUGIN_LIST);

  // ----- Claude Code -----
  const cache = ".claude/plugins/cache";
  write(".claude/settings.json", JSON.stringify({
    enabledPlugins: { "sentry@claude-plugins-official": true, "writing-kit@acme-tools": true, "linear@claude-plugins-official": false, "meet@acme-tools": true },
    pluginConfigs: { "agents-md@builtin": { options: { instructionFiles: "claude-md-and-agents-md" } } },
  }, null, 2));
  const installed = (dir: string) => [{ scope: "user", installPath: join(home, dir), version: dir.split("/").pop() }];
  write(".claude/plugins/installed_plugins.json", JSON.stringify({ version: 2, plugins: {
    "sentry@claude-plugins-official": installed(`${cache}/claude-plugins-official/sentry/1.4.0`),
    "writing-kit@acme-tools": installed(`${cache}/acme-tools/writing-kit/2.0.0`),
    "linear@claude-plugins-official": installed(`${cache}/claude-plugins-official/linear/1.0.0`),
    "meet@acme-tools": installed(`${cache}/acme-tools/meet/0.3.0`),
  } }));
  write(`${cache}/claude-plugins-official/sentry/1.4.0/.claude-plugin/plugin.json`, JSON.stringify({ name: "sentry", version: "1.4.0", mcpServers: { sentry: { type: "http", url: "https://mcp.sentry.dev/mcp?utm_source=plugin" } } }));
  write(`${cache}/claude-plugins-official/sentry/1.4.0/skills/sentry-debug/SKILL.md`, skill("sentry-debug", "Debug a production error from its Sentry issue."));
  write(`${cache}/acme-tools/writing-kit/2.0.0/.claude-plugin/plugin.json`, JSON.stringify({ name: "writing-kit", version: "2.0.0" }));
  write(`${cache}/acme-tools/writing-kit/2.0.0/skills/tighten/SKILL.md`, skill("tighten", "Tighten prose without losing meaning."));
  write(`${cache}/claude-plugins-official/linear/1.0.0/.claude-plugin/plugin.json`, JSON.stringify({ name: "linear", version: "1.0.0" }));
  write(`${cache}/claude-plugins-official/linear/1.0.0/.mcp.json`, JSON.stringify({ mcpServers: { linear: { type: "http", url: "https://mcp.linear.app/mcp" } } }));
  write(`${cache}/acme-tools/meet/0.3.0/.claude-plugin/plugin.json`, JSON.stringify({ name: "meet", version: "0.3.0" }));
  write(`${cache}/acme-tools/meet/0.3.0/.mcp.json`, JSON.stringify({ mcpServers: {
    "meet-a": { type: "http", url: "https://a.meet.example.com/mcp", headers: { Authorization: "Bearer ${MEET_TOKEN}" } },
    "meet-b": { type: "http", url: "https://b.meet.example.com/mcp" },
  } }));
  write(".claude/plugins/marketplaces/claude-plugins-official/.claude-plugin/marketplace.json", JSON.stringify({ name: "claude-plugins-official", plugins: [
    { name: "sentry", homepage: "https://github.com/example/sentry-plugin" },
    { name: "linear", homepage: "https://linear.app" },
  ] }));
  write(".claude/.claude.json", JSON.stringify({ mcpServers: {
    "acme-docs": { type: "http", url: "https://mcp.acme.dev/mcp" },
    "old-wiki": { type: "http", url: "https://wiki.example.com/mcp" },
  }, projects: {} }));
  write(".claude/mcp-needs-auth-cache.json", JSON.stringify({ "claude.ai Gmail": { timestamp: 1 } }));

  write(".claude/CLAUDE.md", "# Global\n\nKeep changes small.\n\n@shared/extra.md\n\nIgnore `@not/an/import.md` in code.\n");
  write(".claude/shared/extra.md", "Extra guidance.\n@../deeper.md\n");
  write(".claude/deeper.md", "Deeper guidance.\n");
  write(".claude/rules/mobile.md", "# Mobile rule\nAlways check the simulator.\n".repeat(20));
  write(".claude/rules/scoped.md", "---\npaths:\n  - \"**/*.swift\"\n---\nSwift only.\n");

  // ----- skills -----
  write(".agents/skills/grill/SKILL.md", skill("grill", "Stress-test a plan with hard questions."));
  write(".agents/skills/tidy/SKILL.md", skill("tidy", "Tidy a module.", "canonical v2\n"));
  write(".claude/skills/tidy/SKILL.md", skill("tidy", "Tidy a module.", "edited by hand\n"));
  write(".claude/skills/.actl-sync.json", JSON.stringify({ version: 1, skills: { tidy: { source: join(home, ".agents/skills/tidy"), hash: "0000000000000000", syncedAt: "2026-01-01T00:00:00.000Z" } } }));

  // ----- Codex -----
  write(".codex/config.toml", `model = "gpt-5"\n\n[mcp_servers.sentry]\nurl = "https://mcp.sentry.dev/mcp"\n\n[mcp_servers.linear]\nurl = "https://mcp.linear.app/mcp"\n`);
  write(".codex/AGENTS.md", "# Codex global\nBe concise.\n");
  const gmail = ".codex/plugins/cache/openai-curated-remote/gmail/0.1.0";
  write(`${gmail}/.codex-plugin/plugin.json`, JSON.stringify({ name: "gmail", version: "0.1.0", homepage: "https://mail.example.com/", interface: { displayName: "Gmail", logo: "./assets/gmail.png", brandColor: "#EA4335" } }));
  write(`${gmail}/.app.json`, JSON.stringify({ apps: { gmail: { id: "connector_2128aebf" } } }));
  write(`${gmail}/assets/gmail.png`, "png");
  const templates = ".codex/plugins/cache/openai-curated-remote/templates/1.0.0";
  write(`${templates}/.codex-plugin/plugin.json`, JSON.stringify({ name: "templates", interface: { displayName: "Default templates" } }));
  write(`${templates}/.app.json`, JSON.stringify({ apps: { templates: { id: "connector_openai_templates" } } }));
  write(`${templates}/skills/starter/SKILL.md`, skill("starter", "Start from a template."));

  // ----- a repo -----
  const repo = join(home, "Code/acme/web");
  write(`${repo}/CLAUDE.md`, "# Web\nUse pnpm.\n");
  write(`${repo}/AGENTS.md`, "# Web agents\nRun tests before pushing.\n");
  write(`${repo}/.claude/rules/style.md`, "Prefer small components.\n");
  write(`${repo}/apps/site/AGENTS.md`, "# Site\nStatic pages only.\n");
  write(`${repo}/apps/site/CLAUDE.local.md`, "My local notes.\n");
  Bun.spawnSync(["git", "init", "-q", repo]);

  const env: Record<string, string> = {
    HOME: home,
    CLAUDE_CONFIG_DIR: join(home, ".claude"),
    CODEX_HOME: join(home, ".codex"),
    XDG_CONFIG_HOME: join(home, ".config"),
    XDG_CACHE_HOME: join(home, ".cache"),
    PATH: `${bin}:${dirname(process.execPath)}:/usr/bin:/bin:/usr/sbin:/sbin`,
    STUB_LOG: log,
    STUB_DIR: stubs,
    ACTL_NO_BACKGROUND: "1",
    ACTL_CLIPROXY_ENDPOINT: "http://127.0.0.1:9", // nothing listens there; never the real proxy
    TMPDIR: tmpdir(),
  };

  const cli = (...args: string[]) => {
    const p = Bun.spawnSync(["bun", join(ROOT, "src/actl.ts"), ...args], { env, cwd: home, stdout: "pipe", stderr: "pipe" });
    const stdout = p.stdout.toString();
    return { code: p.exitCode, stdout, stderr: p.stderr.toString(), json: () => JSON.parse(stdout), lines: () => stdout.trim().split("\n").filter(Boolean).map((l) => JSON.parse(l)) };
  };
  const data = (...args: string[]) => {
    const r = cli(...args);
    if (r.code !== 0) throw new Error(`actl ${args.join(" ")} exited ${r.code}: ${r.stderr}`);
    return r.json().data;
  };
  const calls = () => readFileSync(log, "utf8").split("\n").filter(Boolean);
  const clearCalls = () => writeFileSync(log, "");
  const exists = (rel: string) => existsSync(rel.startsWith("/") ? rel : join(home, rel));

  return { root, home, repo, env, write, read, stub, cli, data, calls, clearCalls, exists, cleanup: () => rmSync(root, { recursive: true, force: true }) };
}
