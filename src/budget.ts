// Context budget: what each harness spends before you type, and which instruction files it reads for a
// repo, following each harness's documented loading rules (see the README's Background table).
import { existsSync, statSync } from "node:fs";
import { dirname, isAbsolute, join, relative, resolve } from "node:path";
import { claudeHome, codexHome, expand, HOME, tilde } from "./config";
import type { Manifest } from "./manifest";
import { INSTRUCTION_MODES } from "./manifest";
import { type Inventory, pluginContext, pretty, type Service } from "./services";
import { byTokensDesc, estTokens, hasPathsFrontmatter, readJson, readText, readToml } from "./util";

export type LoadFile = { path: string; reason: string; tokens: number };
export type Lever = { id: string; label: string; tokens: number; kind: "plugin" | "rule" | "instructions" | "skills"; action?: "make-lazy" | "rescope" | "disable"; serviceId?: string; estimated: boolean };
export type HarnessBudget = { total: number; categories: { id: "plugins" | "skills-listing" | "instructions" | "rules" | "drift"; tokens: number }[]; levers: Lever[] };
export type Budget = {
  harnesses: Record<string, HarnessBudget>;
  loadPreview?: { repo: string; harnesses: Record<string, { files: LoadFile[]; total: number }> };
};

const MAX_IMPORT_HOPS = 4;
const CODEX_DEFAULT_CAP = 32 * 1024;

const isFile = (p: string) => {
  try {
    return statSync(p).isFile();
  } catch {
    return false;
  }
};

/** `@path` imports outside code fences and inline code. Only path-like tokens count, so `@mentions` don't. */
export function importsOf(text: string): string[] {
  const prose = text.replace(/```[\s\S]*?```/g, "").replace(/`[^`\n]*`/g, "");
  return [...prose.matchAll(/(?:^|\s)@((?:~\/|\/|\.{1,2}\/)?[\w.\-/]+)/g)].map((m) => m[1]).filter((p) => p.includes("/") || /\.md$/i.test(p));
}

const resolveImport = (p: string, from: string) => (p.startsWith("~/") ? join(HOME, p.slice(2)) : isAbsolute(p) ? p : resolve(dirname(from), p));

export function claudeInstructionMode(): string {
  const mode = readJson(claudeHome("settings.json"))?.pluginConfigs?.["agents-md@builtin"]?.options?.instructionFiles;
  return INSTRUCTION_MODES.includes(mode) ? mode : "claude-md-or-agents-md";
}

/** The git root above `dir` (a .git file or directory), or `dir` itself when it isn't in a repo. */
export function gitRoot(dir: string): string {
  for (let d = dir; ; d = dirname(d)) {
    if (existsSync(join(d, ".git"))) return d;
    if (dirname(d) === d) return dir;
  }
}

/** Directories from the repo root down to `cwd`, root first. */
const chain = (cwd: string) => {
  const root = gitRoot(cwd);
  const rel = relative(root, cwd);
  const dirs = [root];
  if (rel && !rel.startsWith("..")) for (const part of rel.split("/")) dirs.push(join(dirs[dirs.length - 1], part));
  return dirs;
};

function claudeLoad(repo: string | undefined): LoadFile[] {
  const files: LoadFile[] = [];
  const seen = new Set<string>();
  const add = (p: string, reason: string, hop = 0) => {
    if (seen.has(p) || !isFile(p)) return;
    seen.add(p);
    const text = readText(p) ?? "";
    files.push({ path: tilde(p), reason, tokens: estTokens(text) });
    if (hop < MAX_IMPORT_HOPS) for (const imp of importsOf(text)) add(resolveImport(imp, p), `imported by ${tilde(p)}`, hop + 1);
  };
  const mode = claudeInstructionMode();
  if (mode !== "managed-only") add(claudeHome("CLAUDE.md"), "user instructions");
  for (const p of rulesIn(claudeHome("rules"))) add(p, "user rule, always on (no paths: frontmatter)");
  if (!repo) return files;

  const dirs = chain(repo);
  if (mode === "managed-only") return files;
  const claudeFiles = (d: string) => [join(d, "CLAUDE.md"), join(d, ".claude", "CLAUDE.md")].filter(isFile);
  const projectHasClaude = dirs.some((d) => claudeFiles(d).length > 0);
  const agentsLoads = mode === "claude-md-and-agents-md" || (mode === "claude-md-or-agents-md" && !projectHasClaude);
  for (const d of dirs) {
    const where = d === dirs[0] ? "repo root" : tilde(d);
    for (const p of claudeFiles(d)) add(p, `project instructions (${where})`);
    if (agentsLoads) add(join(d, "AGENTS.md"), mode === "claude-md-and-agents-md" ? `AGENTS.md beside CLAUDE.md (${mode})` : `AGENTS.md in place of CLAUDE.md (${mode})`);
    add(join(d, "CLAUDE.local.md"), `local instructions (${where})`);
    for (const p of rulesIn(join(d, ".claude", "rules"))) add(p, "project rule, always on (no paths: frontmatter)");
  }
  return files;
}

function rulesIn(dir: string): string[] {
  if (!existsSync(dir)) return [];
  return [...new Bun.Glob("**/*.md").scanSync({ cwd: dir })].sort().map((f) => join(dir, f)).filter((p) => !hasPathsFrontmatter(readText(p) ?? ""));
}

function codexConfig() {
  return readToml(codexHome("config.toml")) ?? {};
}

function codexLoad(repo: string | undefined): LoadFile[] {
  const files: LoadFile[] = [];
  const cfg = codexConfig();
  const override = codexHome("AGENTS.override.md");
  const global = isFile(override) && (readText(override) ?? "").trim() ? override : codexHome("AGENTS.md");
  if (isFile(global)) files.push({ path: tilde(global), reason: global === override ? "global override (AGENTS.override.md)" : "global instructions", tokens: estTokens(readText(global) ?? "") });
  if (typeof cfg.developer_instructions === "string" && cfg.developer_instructions.trim())
    files.push({ path: `${tilde(codexHome("config.toml"))}#developer_instructions`, reason: "developer_instructions in config.toml", tokens: estTokens(cfg.developer_instructions) });
  if (!repo) return files;

  const cap = typeof cfg.project_doc_max_bytes === "number" ? cfg.project_doc_max_bytes : CODEX_DEFAULT_CAP;
  const fallbacks: string[] = Array.isArray(cfg.project_doc_fallback_filenames) ? cfg.project_doc_fallback_filenames : [];
  let used = 0;
  const dirs = chain(repo);
  for (const d of dirs) {
    // One file per directory: the override wins, then AGENTS.md, then configured fallbacks.
    const p = ["AGENTS.override.md", "AGENTS.md", ...fallbacks].map((n) => join(d, n)).find(isFile);
    if (!p) continue;
    const text = readText(p) ?? "";
    const bytes = Buffer.byteLength(text);
    const where = d === dirs[0] ? "git root" : tilde(d);
    if (used >= cap) files.push({ path: tilde(p), reason: `skipped: over the ${Math.round(cap / 1024)} KiB project-doc cap`, tokens: 0 });
    else if (used + bytes > cap) {
      files.push({ path: tilde(p), reason: `project instructions (${where}), truncated at the ${Math.round(cap / 1024)} KiB cap`, tokens: Math.ceil((cap - used) / 4) });
      used = cap;
    } else {
      files.push({ path: tilde(p), reason: `project instructions (${where})`, tokens: estTokens(text) });
      used += bytes;
    }
  }
  return files;
}

export function loadPreview(repo: string): NonNullable<Budget["loadPreview"]> {
  const abs = resolve(expand(repo));
  const out: Record<string, { files: LoadFile[]; total: number }> = {};
  for (const [id, files] of [["claude", claudeLoad(abs)], ["codex", codexLoad(abs)]] as const) out[id] = { files, total: files.reduce((n, f) => n + f.tokens, 0) };
  return { repo: tilde(abs), harnesses: out };
}

const skillListing = (skills: { name: string; description: string }[]) => estTokens(skills.map((s) => `- ${s.name}: ${s.description}\n`).join(""));

export function buildBudget(inv: Inventory, services: Service[], manifest?: Manifest, repo?: string): Budget {
  const serviceOf = (harness: string, ref: string) => services.find((s) => s.providers[harness]?.ref === ref)?.id;
  const sum = (xs: { tokens: number }[]) => xs.reduce((n, x) => n + x.tokens, 0);

  // ----- Claude -----
  const claudeLevers: Lever[] = [];
  for (const p of inv.plugins.claude.filter((p) => p.enabled)) {
    const cost = pluginContext(p);
    const svc = serviceOf("claude", p.id);
    const lazy = svc && services.find((s) => s.id === svc)?.providers.claude?.lazyAlternative;
    claudeLevers.push({ id: `plugin:claude:${p.id}`, label: `${pretty(p.name)} plugin`, tokens: cost.tokens, kind: "plugin", action: lazy ? "make-lazy" : "disable", serviceId: svc, estimated: cost.estimated });
  }
  const pluginsTotal = sum(claudeLevers);
  const personal = inv.skills.filter((s) => s.visibleIn.claude && s.source === "claude-user");
  const skillsTokens = skillListing(personal);
  if (personal.length) claudeLevers.push({ id: "skills:claude:user", label: `${personal.length} personal ${personal.length === 1 ? "skill" : "skills"} (listing)`, tokens: skillsTokens, kind: "skills", estimated: true });

  const scoped = new Set(Object.values(manifest?.policy?.rules ?? {}).map((r) => expand(r.file)));
  const global = claudeLoad(undefined);
  let instructions = 0;
  let rules = 0;
  let drift = 0;
  for (const f of global) {
    const isRule = f.reason.includes("rule");
    const reverted = isRule && scoped.has(expand(f.path));
    if (reverted) drift += f.tokens;
    else if (isRule) rules += f.tokens;
    else instructions += f.tokens;
    const name = f.path.split("/").pop()!.replace(/\.md$/, "");
    claudeLevers.push({
      id: `${isRule ? "rule" : "instructions"}:claude:${f.path}`,
      label: reverted ? `${name} rule (reverted to always-on)` : isRule ? `${name} rule` : f.path,
      tokens: f.tokens,
      kind: isRule ? "rule" : "instructions",
      action: isRule ? "rescope" : undefined,
      estimated: true,
    });
  }

  // ----- Codex -----
  const codexLevers: Lever[] = [];
  const byPlugin = new Map<string, { name: string; description: string }[]>();
  for (const s of inv.skills.filter((s) => s.source === "codex-plugin" && s.visibleIn.codex)) byPlugin.set(s.owner, [...(byPlugin.get(s.owner) ?? []), s]);
  for (const [id, skills] of byPlugin) codexLevers.push({ id: `plugin:codex:${id}`, label: `${pretty(id.split("@")[0])} plugin (skills listing)`, tokens: skillListing(skills), kind: "plugin", serviceId: serviceOf("codex", id), estimated: true });
  const codexPlugins = sum(codexLevers);
  const codexSkills = inv.skills.filter((s) => s.visibleIn.codex && (s.source === "agents-user" || s.source === "codex-user"));
  const codexSkillTokens = skillListing(codexSkills);
  if (codexSkills.length) codexLevers.push({ id: "skills:codex:user", label: `${codexSkills.length} personal ${codexSkills.length === 1 ? "skill" : "skills"} (listing)`, tokens: codexSkillTokens, kind: "skills", estimated: true });
  let codexInstructions = 0;
  let codexDrift = 0;
  for (const f of codexLoad(undefined)) {
    // A tool update re-injecting its rules into developer_instructions is drift, not intent.
    const reverted = f.path.endsWith("#developer_instructions") && inv.findings.some((x) => x.title.startsWith("Argent rules are always-on again in Codex"));
    if (reverted) codexDrift += f.tokens;
    else codexInstructions += f.tokens;
    codexLevers.push({ id: `instructions:codex:${f.path}`, label: reverted ? "developer_instructions (re-injected by an update)" : f.path, tokens: f.tokens, kind: "instructions", estimated: true });
  }

  const harness = (levers: Lever[], cats: HarnessBudget["categories"]): HarnessBudget => ({ total: sum(cats), categories: cats, levers: levers.filter((l) => l.tokens > 0).sort(byTokensDesc) });
  return {
    harnesses: {
      claude: harness(claudeLevers, [
        { id: "plugins", tokens: pluginsTotal },
        { id: "skills-listing", tokens: skillsTokens },
        { id: "instructions", tokens: instructions },
        { id: "rules", tokens: rules },
        { id: "drift", tokens: drift },
      ]),
      codex: harness(codexLevers, [
        { id: "plugins", tokens: codexPlugins },
        { id: "skills-listing", tokens: codexSkillTokens },
        { id: "instructions", tokens: codexInstructions },
        { id: "rules", tokens: 0 },
        { id: "drift", tokens: codexDrift },
      ]),
    },
    loadPreview: repo ? loadPreview(repo) : undefined,
  };
}
