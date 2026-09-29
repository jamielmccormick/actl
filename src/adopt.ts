// `actl manifest adopt`: write a manifest that matches what is on this Mac right now, with comments that
// say where each line came from and what actl could not decide for you.
import { existsSync } from "node:fs";
import { basename, join } from "node:path";
import { agentsHome, claudeHome, claudeJsonPath, codexHome, expand, paths, tilde } from "./config";
import type { FullInventory } from "./inventory";
import { loadManifest, type Manifest, tomlKey, tomlValue, validate } from "./manifest";
import { cleanUrl } from "./plugins";
import type { Service } from "./services";
import { planAll } from "./skills-sync";
import { hasPathsFrontmatter, readJson, readText, readToml, estTokens, writeFileAtomic } from "./util";

/** The `paths:` globs of a rule's frontmatter, in block-list or inline-list form. */
export function rulePaths(md: string): string[] {
  const fm = md.match(/^---\n([\s\S]*?)\n---/)?.[1] ?? "";
  const inline = fm.match(/^paths:\s*\[(.*)\]\s*$/m);
  if (inline) return inline[1].split(",").map((s) => s.trim().replace(/^["']|["']$/g, "")).filter(Boolean);
  const block = fm.match(/^paths:\s*\n((?:[ \t]+-.*\n?)+)/m);
  if (block) return block[1].split("\n").map((l) => l.replace(/^\s*-\s*/, "").trim().replace(/^["']|["']$/g, "")).filter(Boolean);
  const single = fm.match(/^paths:\s*(\S.*)$/m);
  return single ? single[1].split(",").map((s) => s.trim().replace(/^["']|["']$/g, "")).filter(Boolean) : [];
}

function providerLine(s: Service, h: string, claudeServers: any, codexServers: any): string {
  const p = s.providers[h];
  const missing = `# ${h}: not configured. Add a provider, or record why with: ${h} = { gap = "…" }`;
  if (!p) return missing;
  if (p.kind === "plugin") return `${h} = ${tomlValue(p.health === "absent" ? { plugin: p.ref, enabled: false } : { plugin: p.ref })}`;
  if (p.kind === "connector") return p.health === "absent" ? `# ${h}: connector ${p.ref} is disabled` : `${h} = ${tomlValue({ connector: p.ref })}`;
  if (p.kind === "claude.ai") {
    const note = p.health === "blocked" ? "  # blocked while proxy or API-key auth is active" : "";
    return `${h} = ${tomlValue({ claudeai: p.ref })}${note}`;
  }
  const conf = p.serverName ? (h === "claude" ? claudeServers : codexServers)[p.serverName] : undefined;
  if (!conf) return `# ${h}: server "${p.serverName ?? p.ref}" is project- or locally scoped; actl manages user scope only`;
  const mcp = conf.url ? { name: p.serverName, url: cleanUrl(conf.url) } : { name: p.serverName, command: conf.command, args: conf.args?.length ? conf.args : undefined };
  const secrets = conf.headers || conf.env || conf.http_headers || conf.env_http_headers || conf.bearer_token_env_var;
  return `${h} = ${tomlValue({ mcp })}${secrets ? "  # its headers/env are not recorded here" : ""}`;
}

export function adoptText(inv: FullInventory): string {
  const out: string[] = [];
  const today = new Date().toISOString().slice(0, 10);
  out.push(
    `# actl manifest: what you intend each harness to have.`,
    `# Written by \`actl manifest adopt\` on ${today} from the state actl observed, so it starts with no drift.`,
    `# Edit freely: \`actl plan\` shows how the Mac differs, and \`actl apply\` makes the changes you pick.`,
    "",
    "version = 1",
    "",
    "[policy.claude]",
    "# Which instruction files Claude loads in a project: claude-md | claude-md-or-agents-md | claude-md-and-agents-md | managed-only",
  );
  const mode = readJson(claudeHome("settings.json"))?.pluginConfigs?.["agents-md@builtin"]?.options?.instructionFiles;
  out.push(mode ? `instruction_files = ${tomlValue(mode)}` : `# instruction_files = "claude-md-or-agents-md"   # Claude's default today; uncomment to pin it`);

  const rulesDir = claudeHome("rules");
  const rules = existsSync(rulesDir) ? [...new Bun.Glob("**/*.md").scanSync({ cwd: rulesDir })].sort() : [];
  for (const rel of rules) {
    const file = join(rulesDir, rel);
    const text = readText(file) ?? "";
    const id = basename(rel, ".md").toLowerCase().replace(/[^a-z0-9-]+/g, "-");
    out.push("");
    if (hasPathsFrontmatter(text)) {
      out.push(`# Path-scoped today. actl reports it if an update makes it always-on again.`, `[policy.rules.${tomlKey(id)}]`, `file = ${tomlValue(tilde(file))}`, `paths = ${tomlValue(rulePaths(text))}`);
    } else {
      out.push(`# ${tilde(file)} loads in every Claude session (~${estTokens(text)} tokens). To scope it, uncomment and set its paths:`, `# [policy.rules.${tomlKey(id)}]`, `# file = ${tomlValue(tilde(file))}`, `# paths = ["**/*.ext"]`);
    }
  }

  out.push("", "[skills]", "# Skills are written here once and copied into each harness.", `canonical = ${tomlValue(tilde(agentsHome("skills")))}`);
  const lock = readJson(agentsHome(".skill-lock.json"))?.skills ?? {};
  const bySource = new Map<string, string[]>();
  for (const [name, e] of Object.entries<any>(lock)) if (typeof e?.source === "string" && existsSync(agentsHome("skills", name))) bySource.set(e.source, [...(bySource.get(e.source) ?? []), name]);
  if (bySource.size) {
    out.push("# From ~/.agents/.skill-lock.json. Recorded for reference; actl does not install packages yet.", "packages = [");
    for (const [source, skills] of [...bySource].sort()) out.push(`  ${tomlValue({ source, skills: skills.sort() })},`);
    out.push("]");
  }
  const repoPaths = inv.repos.filter((r) => r.kind === "repo" && existsSync(join(expand(r.path), ".agents", "skills"))).map((r) => expand(r.path));
  const { skippedRepos } = planAll(repoPaths);
  const skipped = new Set(skippedRepos.map((s) => s.repo));
  const synced = repoPaths.filter((r) => !skipped.has(r));
  out.push(synced.length ? `repos = ${tomlValue(Object.fromEntries(synced.map((r) => [tilde(r), "sync"])))}` : "repos = {}");
  for (const r of skipped) out.push(`# ${tilde(r)} keeps .agents/skills, but .claude/skills isn't gitignored there, so it isn't synced.`);

  const claudeServers = readJson(claudeJsonPath)?.mcpServers ?? {};
  const codexServers = readToml(codexHome("config.toml"))?.mcp_servers ?? {};
  out.push("", "# Services: one table per outside system. Each harness says how it provides it, or why it can't.");
  for (const s of [...inv.services].sort((a, b) => a.id.localeCompare(b.id))) {
    out.push("", `[service.${tomlKey(s.id)}]`, `name = ${tomlValue(s.name)}`);
    out.push(providerLine(s, "claude", claudeServers, codexServers), providerLine(s, "codex", claudeServers, codexServers));
  }

  const proxy = readJson(paths.proxyCache);
  if (proxy?.listening) out.push("", "[proxy]", `endpoint = ${tomlValue(`http://${proxy.endpoint}`)}`);
  return `${out.join("\n")}\n`;
}

export function adopt(inv: FullInventory, force: boolean): { path: string; created: boolean; manifest: Manifest } {
  const text = adoptText(inv);
  const parsed = Bun.TOML.parse(text) as Manifest;
  const errors = validate(parsed);
  if (errors.length) throw new Error(`generated manifest failed validation: ${errors.join("; ")}`);
  if (existsSync(paths.manifest) && !force) return { path: tilde(paths.manifest), created: false, manifest: loadManifest().manifest ?? ({} as Manifest) };
  writeFileAtomic(paths.manifest, text);
  return { path: tilde(paths.manifest), created: true, manifest: parsed };
}
