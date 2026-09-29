// Read-only inventory of agent configuration across coding-agent harnesses (Claude Code and Codex today).
// Never returns secret values: env/header values are dropped, only names kept.
import { existsSync, lstatSync, readdirSync, readFileSync, readlinkSync, realpathSync, statSync } from "node:fs";
import { basename, dirname, join, relative } from "node:path";
import { agentsHome, claudeHome, claudeJsonPath, codexHome, config, HOME, tilde } from "./config";
import { claudePluginMcp, codexPluginMeta, type McpDecl } from "./plugins";
import { planAll } from "./skills-sync";
import { frontmatter, hasPathsFrontmatter, ls, readJson, readToml, run } from "./util";

export type Severity = "error" | "warn" | "info";
export type Finding = { severity: Severity; area: string; title: string; detail: string; fix?: string; items?: string[] };

// ---------- repositories ----------

export type Repo = { name: string; path: string; kind: "repo" | "workspace"; branch?: string; remote?: string };

function gitMainCheckout(p: string): boolean {
  // A .git *file* marks a linked worktree; those mirror their main repo, so only directories count.
  try {
    return lstatSync(join(p, ".git")).isDirectory();
  } catch {
    return false;
  }
}

/** Projects the harnesses themselves know about: Claude's project history and Codex's trusted projects. */
function harnessProjects(codexCfg: any): string[] {
  const claudeProjects = Object.keys(readJson(claudeJsonPath)?.projects ?? {});
  const codexProjects = Object.keys(codexCfg?.projects ?? {});
  return [...claudeProjects, ...codexProjects];
}

function discoverRepos(codexCfg: any): Repo[] {
  const found = new Map<string, Repo>();
  const addRepo = (p: string) => {
    if (found.has(p)) return;
    const branch = run(["git", "-C", p, "branch", "--show-current"]).out.trim();
    const remote = run(["git", "-C", p, "remote", "get-url", "origin"]);
    found.set(p, { name: basename(p), path: p, kind: "repo", branch, remote: remote.ok ? remote.out.trim() : undefined });
  };
  const walk = (dir: string, depth: number) => {
    if (depth > config.scan.maxDepth) return;
    for (const n of ls(dir)) {
      const p = join(dir, n);
      let st;
      try {
        st = statSync(p);
      } catch {
        continue;
      }
      if (!st.isDirectory() || n === "node_modules") continue;
      if (gitMainCheckout(p)) addRepo(p);
      else if (!existsSync(join(p, ".git"))) walk(p, depth + 1);
    }
  };
  for (const root of config.scan.roots) walk(root, 0);
  // Repos used with an agent count wherever they live, as long as they still exist as main checkouts.
  for (const p of harnessProjects(codexCfg)) {
    if (p !== HOME && existsSync(p) && gitMainCheckout(p)) addRepo(p);
  }
  for (const root of config.scan.workspaces)
    for (const n of ls(root)) {
      const p = join(root, n);
      if (!found.has(p) && (existsSync(join(p, "AGENTS.md")) || existsSync(join(p, "CLAUDE.md")))) found.set(p, { name: n, path: p, kind: "workspace" });
    }
  return [...found.values()].sort((a, b) => a.path.localeCompare(b.path));
}

// ---------- harnesses ----------

export type Harness = { id: string; name: string; supported: boolean; installed: boolean; version?: string; home?: string };

/** Claude Code and Codex are managed; other coding agents are detected so the gap is visible. */
function detectHarnesses(): Harness[] {
  const version = (bin: string) => {
    const r = run([bin, "--version"], HOME, 15_000);
    return r.ok ? r.out.trim().split("\n")[0] : undefined;
  };
  const onPath = (bin: string) => run(["/bin/sh", "-c", `command -v ${bin}`], HOME, 5_000).ok;
  const claudeV = version("claude");
  const codexV = version("codex");
  const detectOnly: [string, string, string, string][] = [
    ["cursor", "Cursor", "cursor-agent", join(HOME, ".cursor")],
    ["gemini", "Gemini CLI", "gemini", join(HOME, ".gemini")],
    ["opencode", "OpenCode", "opencode", join(HOME, ".config", "opencode")],
    ["copilot", "GitHub Copilot CLI", "copilot", join(HOME, ".copilot")],
  ];
  return [
    { id: "claude", name: "Claude Code", supported: true, installed: !!claudeV, version: claudeV, home: tilde(claudeHome()) },
    { id: "codex", name: "Codex", supported: true, installed: !!codexV, version: codexV, home: tilde(codexHome()) },
    ...detectOnly.map(([id, name, bin, home]) => ({ id, name, supported: false, installed: onPath(bin) || existsSync(home), home: existsSync(home) ? tilde(home) : undefined })),
  ];
}

// ---------- instruction files ----------

const INSTRUCTION_NAMES = ["AGENTS.md", "AGENTS.override.md", "CLAUDE.md", "CLAUDE.local.md"];

export type InstructionFile = {
  scope: "global" | "repo" | "workspace";
  owner: string;
  path: string;
  rel: string;
  name: string;
  bytes: number;
  lines: number;
  tracked: boolean;
  shimOnlyImportsAgents: boolean;
  pathScoped: boolean;
  imports: string[];
  loadedBy: ("claude" | "codex")[];
  preview: string;
};

function describeInstruction(path: string, scope: InstructionFile["scope"], owner: string, root: string, tracked: boolean): InstructionFile {
  const text = readFileSync(path, "utf8");
  const name = basename(path);
  const imports = [...text.matchAll(/^@(\S+)\s*$/gm)].map((m) => m[1]);
  const meaningful = text
    .split("\n")
    .filter((l) => l.trim() && !/^@\S+\s*$/.test(l.trim()))
    .join("\n");
  const loadedBy: InstructionFile["loadedBy"] = [];
  if (name.startsWith("CLAUDE") || name === "AGENTS.md") loadedBy.push("claude");
  if (name.startsWith("AGENTS")) loadedBy.push("codex");
  return {
    scope,
    owner,
    path,
    rel: tilde(root === HOME ? path : relative(root, path) || name),
    name,
    bytes: Buffer.byteLength(text),
    lines: text.split("\n").length,
    tracked,
    shimOnlyImportsAgents: imports.includes("AGENTS.md") && meaningful.length < 200,
    // Claude rules with `paths:` frontmatter load only when a matching file is read.
    pathScoped: hasPathsFrontmatter(text),
    imports,
    loadedBy,
    preview: text.slice(0, 4000),
  };
}

function collectInstructions(repos: Repo[]): InstructionFile[] {
  const files: InstructionFile[] = [];
  for (const p of [claudeHome("CLAUDE.md"), claudeHome("AGENTS.md"), codexHome("AGENTS.md"), codexHome("AGENTS.override.md")]) {
    if (existsSync(p)) files.push(describeInstruction(p, "global", "user", HOME, false));
  }
  for (const f of ls(claudeHome("rules"))) {
    const d = describeInstruction(claudeHome("rules", f), "global", "user", HOME, false);
    d.loadedBy = ["claude"];
    files.push(d);
  }
  for (const r of repos) {
    const tracked = new Set(
      run(["git", "-C", r.path, "ls-files"])
        .out.split("\n")
        .filter(Boolean),
    );
    // Workspaces hold copied source snapshots under work/; only their top levels are live instructions.
    const found = run([
      "find", r.path, ...(r.kind === "workspace" ? ["-maxdepth", "3"] : []), "(", "-name", "node_modules", "-o", "-name", ".git", "-o", "-path", "*/.claude/worktrees", "-o", "-name", ".next", "-o", "-name", "dist", ")", "-prune", "-o",
      "(", ...INSTRUCTION_NAMES.flatMap((n, i) => (i ? ["-o", "-name", n] : ["-name", n])), ")", "-type", "f", "-print",
    ]).out.split("\n").filter(Boolean);
    for (const p of found) {
      const d = describeInstruction(p, r.kind === "repo" ? "repo" : "workspace", r.name, r.path, tracked.has(relative(r.path, p)));
      d.rel = relative(r.path, p);
      files.push(d);
    }
    for (const f of ls(join(r.path, ".claude", "rules"))) {
      const d = describeInstruction(join(r.path, ".claude", "rules", f), "repo", r.name, r.path, tracked.has(`.claude/rules/${f}`));
      d.loadedBy = ["claude"];
      files.push(d);
    }
  }
  return files;
}

// ---------- skills ----------

export type SkillSource = "claude-user" | "codex-user" | "agents-user" | "claude-project" | "agents-project" | "claude-plugin" | "codex-plugin";
export type Skill = {
  name: string;
  dirName: string;
  description: string;
  source: SkillSource;
  owner: string;
  path: string;
  linkTarget?: string;
  broken: boolean;
  pinnedToCodexPluginVersion: boolean;
  codexDisabled: boolean;
  visibleIn: { claude: boolean; codex: boolean };
};

function codexDisabledSkillPaths(codexCfg: any): Set<string> {
  const out = new Set<string>();
  for (const s of codexCfg?.skills?.config ?? []) if (s.enabled === false && s.path) out.add(dirname(s.path));
  return out;
}

function scanSkillDir(dir: string, source: SkillSource, owner: string, disabled: Set<string>): Skill[] {
  const out: Skill[] = [];
  let entries: string[] = [];
  try {
    entries = readdirSync(dir);
  } catch {
    return out;
  }
  for (const n of entries) {
    if (n.startsWith(".")) continue;
    const p = join(dir, n);
    let linkTarget: string | undefined;
    let broken = false;
    try {
      if (lstatSync(p).isSymbolicLink()) {
        linkTarget = readlinkSync(p);
        broken = !existsSync(p);
      }
    } catch {
      continue;
    }
    let fm: Record<string, string> = {};
    if (!broken) {
      const md = join(p, "SKILL.md");
      if (!existsSync(md)) continue;
      fm = frontmatter(readFileSync(md, "utf8"));
    }
    let real = p;
    try {
      real = realpathSync(p);
    } catch {}
    const codexSide = source === "codex-user" || source === "agents-user" || source === "agents-project" || source === "codex-plugin";
    const codexDisabled = disabled.has(real) || disabled.has(p);
    out.push({
      name: fm.name || n,
      dirName: n,
      description: fm.description ?? "",
      source,
      owner,
      path: p,
      linkTarget,
      broken,
      pinnedToCodexPluginVersion: !!linkTarget && linkTarget.includes("/.codex/plugins/cache/"),
      codexDisabled,
      visibleIn: {
        claude: !broken && (source === "claude-user" || source === "claude-project" || source === "claude-plugin"),
        codex: !broken && codexSide && !codexDisabled,
      },
    });
  }
  return out;
}

function latestVersionDirs(root: string): string[] {
  // plugin cache layout: <marketplace>/<plugin>/<version>/
  const out: string[] = [];
  for (const mkt of ls(root))
    for (const plugin of ls(join(root, mkt))) {
      const versions = ls(join(root, mkt, plugin))
        .map((v) => ({ v, t: statSync(join(root, mkt, plugin, v)).mtimeMs }))
        .sort((a, b) => b.t - a.t);
      if (versions[0]) out.push(join(root, mkt, plugin, versions[0].v));
    }
  return out;
}

function collectSkills(repos: Repo[], codexCfg: any, claudePlugins: ClaudePlugin[], codexPlugins: CodexPlugin[]): Skill[] {
  const disabled = codexDisabledSkillPaths(codexCfg);
  const skills: Skill[] = [
    ...scanSkillDir(claudeHome("skills"), "claude-user", "user", disabled),
    ...scanSkillDir(codexHome("skills"), "codex-user", "user", disabled),
    ...scanSkillDir(agentsHome("skills"), "agents-user", "user", disabled),
  ];
  for (const r of repos) {
    skills.push(...scanSkillDir(join(r.path, ".claude", "skills"), "claude-project", r.name, disabled));
    skills.push(...scanSkillDir(join(r.path, ".agents", "skills"), "agents-project", r.name, disabled));
  }
  for (const p of claudePlugins.filter((p) => p.enabled && p.installPath))
    skills.push(...scanSkillDir(join(p.installPath!, "skills"), "claude-plugin", p.id, disabled));
  const enabledCodex = new Set(codexPlugins.filter((p) => p.enabled).map((p) => p.id.split("@")[0]));
  for (const dir of latestVersionDirs(codexHome("plugins", "cache"))) {
    const plugin = basename(dirname(dir));
    const s = scanSkillDir(join(dir, "skills"), "codex-plugin", `${plugin}@${basename(dirname(dirname(dir)))}`, disabled);
    // Curated remote plugins are cached even when not enabled; mark visibility by enablement when we know it.
    if (!enabledCodex.has(plugin) && basename(dirname(dirname(dir))) !== "openai-curated-remote") s.forEach((x) => (x.visibleIn.codex = false));
    skills.push(...s);
  }
  return skills;
}

// ---------- plugins ----------

export type ClaudePlugin = { id: string; name: string; enabled: boolean; version?: string; installPath?: string; hasMcp: boolean; hasSkills: boolean; mcpServers: McpDecl[] };
export type CodexPlugin = { id: string; enabled: boolean; cached: boolean; version?: string; connector: boolean; displayName?: string };

function collectClaudePlugins(): ClaudePlugin[] {
  const settings = readJson(claudeHome("settings.json")) ?? {};
  const installed = readJson(claudeHome("plugins", "installed_plugins.json"))?.plugins ?? {};
  const ids = new Set([...Object.keys(settings.enabledPlugins ?? {}), ...Object.keys(installed)]);
  return [...ids].map((id) => {
    const inst = installed[id]?.[0];
    const p = inst?.installPath;
    const mcpServers = claudePluginMcp(p);
    return {
      id,
      name: readJson(join(p ?? "", ".claude-plugin", "plugin.json"))?.name ?? id.split("@")[0],
      enabled: settings.enabledPlugins?.[id] === true,
      version: inst?.version,
      installPath: p,
      hasMcp: mcpServers.length > 0,
      hasSkills: !!p && existsSync(join(p, "skills")),
      mcpServers,
    };
  });
}

function collectCodexPlugins(codexCfg: any): CodexPlugin[] {
  // `codex plugin list` includes ChatGPT connector plugins that never appear in config.toml.
  // Row format: "<name>@<marketplace>  installed, enabled  <version>  <source>".
  const out = new Map<string, CodexPlugin>();
  const meta = codexPluginMeta();
  for (const line of run(["codex", "plugin", "list"], HOME, 120_000).out.split("\n")) {
    const m = line.match(/^(\S+@\S+)\s+installed, (enabled|disabled)\s+(\S+)?\s*(\S+)?/);
    if (!m) continue;
    const [name, mkt] = m[1].split("@");
    out.set(m[1], {
      id: m[1],
      enabled: m[2] === "enabled",
      version: m[3],
      cached: existsSync(codexHome("plugins", "cache", mkt, name)),
      // Connector plugins ship a ChatGPT app (.app.json); the remote source id says so too.
      connector: meta.get(m[1]) ? meta.get(m[1])!.app : /^plugin_(connector|asdk_app)_/.test(m[4] ?? ""),
      displayName: meta.get(m[1])?.displayName,
    });
  }
  for (const [id, v] of Object.entries(codexCfg?.plugins ?? {}) as [string, any][]) {
    if (out.has(id)) continue;
    const [name, mkt] = id.split("@");
    out.set(id, { id, enabled: v?.enabled !== false, cached: existsSync(codexHome("plugins", "cache", mkt ?? "", name)), connector: !!meta.get(id)?.app, displayName: meta.get(id)?.displayName });
  }
  return [...out.values()];
}

// ---------- MCP ----------

export type McpRow = {
  name: string;
  target: string;
  claude?: { scope: string; status: "connected" | "failed" | "needs-auth" | "blocked" | "pending" | "unknown"; detail: string; serverName?: string };
  codex?: { enabled: boolean; auth: string; transport: string; serverName?: string; pluginId?: string };
  notes: string[];
};

// One row per service: plugin servers key on the plugin name (so zoom-plugin's seven servers are one row),
// and vendor suffixes are dropped so "monday-crm" (Claude) and "monday-com" (Codex) line up.
export const serviceKey = (s: string) => {
  let k = s.toLowerCase().replace(/^claude\.ai\s+/, "").replace(/@.*$/, "").replace(/\.(com|io|ai|dev|app|so)$/, "");
  const plugin = k.match(/^plugin:([^:]+):/);
  if (plugin) k = plugin[1];
  const key = k.replace(/[-_](plugin|sales|crm|com|mcp|ai-companion)$/, "").replace(/[^a-z0-9]/g, "");
  return SERVICE_ALIASES[key] ?? key;
};
const SERVICE_ALIASES: Record<string, string> = { paperdesktop: "paper" };
const STATUS_RANK = ["failed", "needs-auth", "blocked", "pending", "unknown", "connected"];

function parseClaudeMcpList(text: string) {
  const rows: { name: string; target: string; status: NonNullable<McpRow["claude"]>["status"]; detail: string }[] = [];
  for (const line of text.split("\n")) {
    const m = line.match(/^(.+?): (.+?) - (✔|✘|!|⚠|⏸)?\s*(.*)$/);
    if (!m) continue;
    const [, name, target, icon, detail] = m;
    const status = icon === "✔" ? "connected" : icon === "✘" ? "failed" : icon === "⏸" ? "pending" : /auth/i.test(detail) ? "needs-auth" : "unknown";
    rows.push({ name: name.trim(), target: target.replace(/\s*\((HTTP|SSE)\)$/, "").trim(), status, detail: detail.trim() });
  }
  return { rows, connectorsBlocked: /claude\.ai connectors are disabled/.test(text) };
}

function collectMcp(repos: Repo[], codexPlugins: CodexPlugin[]) {
  const claudeText = run(["claude", "mcp", "list"], HOME, 120_000).out;
  const { rows: claudeRows, connectorsBlocked } = parseClaudeMcpList(claudeText);
  const claudeJson = readJson(claudeJsonPath) ?? {};
  const userServers = claudeJson.mcpServers ?? {};
  const needsAuthCache = readJson(claudeHome("mcp-needs-auth-cache.json")) ?? {};
  const codexList: any[] = (() => {
    try {
      return JSON.parse(run(["codex", "mcp", "list", "--json"]).out);
    } catch {
      return [];
    }
  })();

  const rows = new Map<string, McpRow>();
  const get = (name: string, target: string) => {
    const k = serviceKey(name);
    if (!rows.has(k)) rows.set(k, { name, target, notes: [] });
    return rows.get(k)!;
  };
  for (const r of claudeRows) {
    const row = get(r.name, r.target);
    const next = { scope: r.name.startsWith("plugin:") ? "plugin" : userServers[r.name] ? "user" : "project/local", status: r.status, detail: r.detail, serverName: r.name };
    if (!row.claude) row.claude = next;
    else {
      // Several servers for one service: keep the worst status and say how many there are.
      if (STATUS_RANK.indexOf(next.status) < STATUS_RANK.indexOf(row.claude.status)) row.claude = { ...next, detail: next.detail };
      const n = claudeRows.filter((x) => serviceKey(x.name) === serviceKey(r.name)).length;
      row.claude.detail = `${n} servers; worst: ${row.claude.detail.replace(/^\d+ servers; worst: /, "")}`;
    }
  }
  for (const name of Object.keys(needsAuthCache)) {
    if (!name.startsWith("claude.ai ")) continue;
    const row = get(name, "claude.ai connector");
    row.claude ??= { scope: "claude.ai", status: connectorsBlocked ? "blocked" : "needs-auth", detail: connectorsBlocked ? "claude.ai connectors disabled: proxy/API auth takes precedence" : "needs authentication" };
  }
  for (const s of codexList) {
    const t = s.transport ?? {};
    const row = get(s.name, t.url ?? [t.command, ...(t.args ?? [])].join(" "));
    row.codex = { enabled: !!s.enabled, auth: s.auth_status, transport: t.type, serverName: s.name };
  }
  // ChatGPT connector plugins give Codex the same service without an MCP entry in config.toml.
  for (const p of codexPlugins.filter((p) => p.connector && p.enabled)) {
    // Some connector ids are opaque ("app-69d9…"); the manifest's display name lines them up with Claude.
    const id = p.id.split("@")[0];
    const name = /^app-[0-9a-f]{12,}$/.test(id) && p.displayName ? p.displayName : id;
    const row = get(name, `ChatGPT connector (${p.id})`);
    row.codex ??= { enabled: true, auth: "chatgpt-connector", transport: "connector", pluginId: p.id };
  }
  for (const row of rows.values()) {
    // Codex manages its own plugin-cache paths; only hand-configured Claude servers are fragile here.
    if (row.claude && /\/(\.codex\/plugins\/cache|node_modules)\//.test(row.target)) row.notes.push("path pinned to a versioned cache or repo node_modules");
  }
  const projectMcp = repos
    .map((r) => ({ repo: r.name, servers: Object.keys(readJson(join(r.path, ".mcp.json"))?.mcpServers ?? {}), codex: Object.keys(readToml(join(r.path, ".codex", "config.toml"))?.mcp_servers ?? {}) }))
    .filter((p) => p.servers.length || p.codex.length);
  return { rows: [...rows.values()].sort((a, b) => a.name.localeCompare(b.name)), connectorsBlocked, projectMcp, claudeRaw: claudeText.split("\n").slice(0, 3).join("\n") };
}

// ---------- findings ----------

function computeFindings(inst: InstructionFile[], skills: Skill[], mcp: ReturnType<typeof collectMcp>): Finding[] {
  const f: Finding[] = [];
  const broken = skills.filter((s) => s.broken);
  if (broken.length)
    f.push({
      severity: "error", area: "skills", title: `${broken.length} broken skill links`,
      detail: "Symlinks whose target no longer exists, usually a Codex plugin version that was upgraded or removed.",
      fix: "Remove the dead links; stop linking into ~/.codex/plugins/cache/<version> paths.",
      items: broken.map((s) => `${tilde(s.path)} → ${s.linkTarget}`),
    });
  const pinned = skills.filter((s) => s.pinnedToCodexPluginVersion && !s.broken);
  if (pinned.length)
    f.push({
      severity: "warn", area: "skills", title: `${pinned.length} Claude skills pinned to a Codex plugin version`,
      detail: "These links break on the next Codex plugin update, and they expose Codex-only plugin workflows to Claude.",
      items: pinned.map((s) => s.dirName),
    });
  const disabledButClaude = skills.filter((s) => s.source === "claude-user" && s.linkTarget && skills.some((c) => c.codexDisabled && c.dirName === s.dirName));
  if (disabledButClaude.length)
    f.push({
      severity: "warn", area: "skills", title: `${disabledButClaude.length} skills disabled in Codex but active in Claude`,
      detail: "Codex config disables these; Claude still loads them through ~/.claude/skills symlinks.",
      items: disabledButClaude.map((s) => s.dirName),
    });
  if (mcp.connectorsBlocked)
    f.push({
      severity: "warn", area: "mcp", title: "claude.ai connectors disabled in Claude Code",
      detail: "ANTHROPIC_AUTH_TOKEN/BASE_URL (CLIProxyAPI) take precedence over the claude.ai login, so claude.ai connectors never load.",
      fix: "Add the connectors you need as direct MCP servers in ~/.claude.json (they do their own OAuth).",
      items: mcp.rows.filter((r) => r.claude?.status === "blocked").map((r) => r.name),
    });
  for (const r of mcp.rows) {
    if (r.claude?.status === "failed") f.push({ severity: "error", area: "mcp", title: `Claude MCP "${r.name}" failed to connect`, detail: r.claude.detail, items: [r.target] });
    if (r.notes.length) f.push({ severity: "warn", area: "mcp", title: `MCP "${r.name}" uses a fragile path`, detail: r.notes.join("; "), items: [r.target] });
  }
  const codexOnly = mcp.rows.filter((r) => r.codex?.enabled && !r.claude).map((r) => r.name);
  const claudeOnly = mcp.rows.filter((r) => r.claude && r.claude.scope !== "claude.ai" && !r.codex).map((r) => r.name);
  if (codexOnly.length) f.push({ severity: "info", area: "mcp", title: `${codexOnly.length} MCP servers only in Codex`, detail: "Configured and enabled in Codex, absent in Claude Code.", items: codexOnly });
  if (claudeOnly.length) f.push({ severity: "info", area: "mcp", title: `${claudeOnly.length} MCP servers only in Claude Code`, detail: "Configured in Claude Code, absent in Codex.", items: claudeOnly });

  const byDir = new Map<string, InstructionFile[]>();
  for (const i of inst) if (i.scope !== "global") byDir.set(dirname(i.path), [...(byDir.get(dirname(i.path)) ?? []), i]);
  for (const [dir, files] of byDir) {
    const agents = files.find((x) => x.name === "AGENTS.md");
    const claude = files.find((x) => x.name === "CLAUDE.md" && !x.shimOnlyImportsAgents);
    if (agents && claude)
      f.push({ severity: "warn", area: "instructions", title: `AGENTS.md and CLAUDE.md both carry content`, detail: "Claude Code loads both; content drifts or duplicates.", fix: "Keep content in AGENTS.md; delete CLAUDE.md or reduce it to Claude-only additions.", items: [tilde(dir)] });
  }
  const big = inst.filter((i) => i.bytes > 12_000 && !i.pathScoped);
  if (big.length) f.push({ severity: "warn", area: "instructions", title: "Large always-loaded instruction files", detail: "Every session pays for these tokens.", items: big.map((i) => `${tilde(i.path)} (${(i.bytes / 1024).toFixed(1)} KB)`) });
  return f.sort((a, b) => ["error", "warn", "info"].indexOf(a.severity) - ["error", "warn", "info"].indexOf(b.severity));
}

// ---------- drift from the agreed baseline ----------

function driftFindings(repos: Repo[], codexCfg: any): Finding[] {
  const f: Finding[] = [];
  const { plans, skippedRepos } = planAll(repos.filter((r) => r.kind === "repo").map((r) => r.path));
  const pending = plans.flatMap((p) => p.actions.filter((a) => a.kind !== "adopt" && a.kind !== "conflict").map((a) => `${p.scope}: ${a.kind} ${a.name}`));
  const conflicts = plans.flatMap((p) => p.actions.filter((a) => a.kind === "conflict").map((a) => `${p.scope}: ${a.name} (${"reason" in a ? a.reason : ""})`));
  if (pending.length)
    f.push({ severity: "warn", area: "skills", title: `${pending.length} skill changes not yet synced to Claude`, detail: "Canonical skills in ~/.agents/skills (or a repo's .agents/skills) changed since the last sync.", fix: "bun src/skills-sync.ts --apply", items: pending });
  if (conflicts.length)
    f.push({ severity: "error", area: "skills", title: `${conflicts.length} skill copies edited in place`, detail: "A Claude copy differs from its canonical source and from what sync last wrote. Move the edit into ~/.agents/skills, then re-sync.", items: conflicts });
  if (skippedRepos.length)
    f.push({ severity: "info", area: "skills", title: `${skippedRepos.length} repos keep .agents/skills that Claude can't see`, detail: "These repos don't gitignore .claude/skills, so sync won't write copies there.", items: skippedRepos.map((s) => tilde(s.repo)) });

  const argentRule = claudeHome("rules", "argent.md");
  if (existsSync(argentRule) && !hasPathsFrontmatter(readFileSync(argentRule, "utf8")))
    f.push({ severity: "warn", area: "instructions", title: "Argent rule is always-on again in Claude", detail: "`argent update` restored ~/.claude/rules/argent.md without path scoping (~4k tokens every session).", fix: "Re-apply the paths frontmatter (see backup argent.md in ~/.claude/backups/instruction-cleanup-*)." });
  if (typeof codexCfg.developer_instructions === "string" && codexCfg.developer_instructions.includes("argent rules"))
    f.push({ severity: "warn", area: "instructions", title: "Argent rules are always-on again in Codex", detail: "`argent update` re-injected its 17 KB block into developer_instructions in ~/.codex/config.toml.", fix: "Remove the block between the argent rules markers; the pointer in ~/.codex/AGENTS.md covers routing." });
  return f;
}

// ---------- entry ----------

export function collect() {
  const started = Date.now();
  const codexCfg = readToml(codexHome("config.toml")) ?? {};
  const harnesses = detectHarnesses();
  const repos = discoverRepos(codexCfg);
  const claudePlugins = collectClaudePlugins();
  const codexPlugins = collectCodexPlugins(codexCfg);
  const instructions = collectInstructions(repos);
  const skills = collectSkills(repos, codexCfg, claudePlugins, codexPlugins);
  const mcp = collectMcp(repos, codexPlugins);
  const findings = computeFindings(instructions, skills, mcp);
  findings.push(...driftFindings(repos, codexCfg));
  findings.sort((a, b) => ["error", "warn", "info"].indexOf(a.severity) - ["error", "warn", "info"].indexOf(b.severity));
  return {
    generatedAt: new Date().toISOString(),
    tookMs: Date.now() - started,
    versions: { claude: harnesses.find((x) => x.id === "claude")?.version ?? "", codex: harnesses.find((x) => x.id === "codex")?.version ?? "" },
    harnesses,
    config: { path: tilde(config.path), exists: config.exists, scanRoots: config.scan.roots.map(tilde), workspaces: config.scan.workspaces.map(tilde) },
    repos: repos.map((r) => ({ ...r, path: tilde(r.path) })),
    instructions: instructions.map((i) => ({ ...i, path: tilde(i.path) })),
    skills: skills.map((s) => ({ ...s, path: tilde(s.path), linkTarget: s.linkTarget && tilde(s.linkTarget) })),
    plugins: { claude: claudePlugins.map((p) => ({ ...p, installPath: p.installPath && tilde(p.installPath) })), codex: codexPlugins },
    mcp,
    findings,
  };
}

if (import.meta.main) console.log(JSON.stringify(collect(), null, 2));
