// Keep Claude Code's skill directories in step with the canonical Agent Skills locations, using real
// copies (no symlinks). Canonical: ~/.agents/skills (read by Codex), with ~/.codex/skills as a legacy
// fallback. Each target keeps a manifest of what it copied, so drift and local edits are detected.
//
//   bun src/skills-sync.ts            # plan only
//   bun src/skills-sync.ts --apply    # apply the plan
import { createHash } from "node:crypto";
import { cpSync, existsSync, lstatSync, readdirSync, readFileSync, readlinkSync, realpathSync, rmSync, statSync, writeFileSync } from "node:fs";
import { basename, join, relative, resolve } from "node:path";
import { agentsHome, claudeHome, codexHome, expand } from "./config";

const MANIFEST = ".actl-sync.json";
const RESERVED = new Set(["synced", ".trash"]);

type Manifest = { version: 1; skills: Record<string, { source: string; hash: string; syncedAt: string }> };
export type SyncAction =
  | { kind: "copy" | "update" | "replace-link"; name: string; source: string; target: string }
  | { kind: "adopt"; name: string; source: string; target: string } // same content already present; just record it
  | { kind: "promote"; name: string; source: string; target: string } // target-only skill copied to the canonical root
  | { kind: "remove"; name: string; target: string; reason: string }
  | { kind: "conflict"; name: string; target: string; reason: string; source?: string };
export type SyncPlan = { scope: string; targetRoot: string; actions: SyncAction[] };

function listSkillDirs(root: string): Map<string, string> {
  const out = new Map<string, string>();
  let names: string[] = [];
  try {
    names = readdirSync(root);
  } catch {
    return out;
  }
  for (const n of names) {
    if (n.startsWith(".") || RESERVED.has(n)) continue;
    const p = join(root, n);
    try {
      if (existsSync(join(p, "SKILL.md"))) out.set(n, p);
    } catch {}
  }
  return out;
}

export function hashDir(dir: string): string {
  const h = createHash("sha256");
  const walk = (d: string) => {
    for (const n of readdirSync(d).sort()) {
      if (n === ".DS_Store" || n === MANIFEST) continue;
      const p = join(d, n);
      const st = statSync(p);
      if (st.isDirectory()) walk(p);
      else {
        h.update(relative(dir, p));
        h.update(readFileSync(p));
      }
    }
  };
  walk(realpathSync(dir));
  return h.digest("hex").slice(0, 16);
}

function readManifest(root: string): Manifest {
  try {
    return JSON.parse(readFileSync(join(root, MANIFEST), "utf8"));
  } catch {
    return { version: 1, skills: {} };
  }
}

const isLink = (p: string) => {
  try {
    return lstatSync(p).isSymbolicLink();
  } catch {
    return false;
  }
};

/** Skill names provided by enabled Claude plugins; those never need a personal copy. */
function claudePluginSkillNames(): Set<string> {
  const names = new Set<string>();
  try {
    const settings = JSON.parse(readFileSync(claudeHome("settings.json"), "utf8"));
    const installed = JSON.parse(readFileSync(claudeHome("plugins", "installed_plugins.json"), "utf8")).plugins ?? {};
    for (const [id, on] of Object.entries(settings.enabledPlugins ?? {})) {
      const path = on && installed[id]?.[0]?.installPath;
      if (!path) continue;
      // Plugins may declare skill folders anywhere (e.g. planetscale-skills/skills/), so search the install.
      for (const md of new Bun.Glob("**/SKILL.md").scanSync({ cwd: path, followSymlinks: false })) {
        const parts = md.split("/");
        if (parts.length >= 2 && !parts.includes("node_modules")) names.add(parts[parts.length - 2]);
      }
    }
  } catch {}
  return names;
}

/**
 * Plan a one-way sync from canonical source roots into a target root.
 * `promoteTo`: when set, real directories that exist only in the target are copied there as canonical.
 */
function planOne(scope: string, sources: string[], targetRoot: string, opts: { promoteTo?: string; skip?: Set<string> } = {}): SyncPlan {
  const actions: SyncAction[] = [];
  const manifest = readManifest(targetRoot);
  // First source wins, so ~/.agents/skills overrides the legacy ~/.codex/skills copy of the same name.
  const canonical = new Map<string, string>();
  for (const root of sources) for (const [n, p] of listSkillDirs(root)) if (!canonical.has(n)) canonical.set(n, p);
  const targetEntries = existsSync(targetRoot) ? readdirSync(targetRoot).filter((n) => !n.startsWith(".") && !RESERVED.has(n)) : [];

  for (const [name, source] of canonical) {
    const target = join(targetRoot, name);
    if (opts.skip?.has(name)) {
      // Provided elsewhere (e.g. a Claude plugin); an old link or synced copy here only duplicates it.
      if (isLink(target) || manifest.skills[name]) actions.push({ kind: "remove", name, target, reason: "provided by a plugin or user-level skill" });
      continue;
    }
    const srcHash = hashDir(source);
    if (isLink(target)) {
      actions.push({ kind: "replace-link", name, source, target });
    } else if (!existsSync(target)) {
      actions.push({ kind: "copy", name, source, target });
    } else {
      const tgtHash = hashDir(target);
      const recorded = manifest.skills[name];
      if (tgtHash === srcHash) {
        if (!recorded || recorded.hash !== srcHash) actions.push({ kind: "adopt", name, source, target });
      } else if (recorded && recorded.hash === tgtHash) {
        actions.push({ kind: "update", name, source, target }); // source moved on; target untouched since last sync
      } else {
        actions.push({ kind: "conflict", name, target, source, reason: recorded ? "edited in place since last sync" : "differs from canonical and was not created by sync" });
      }
    }
  }
  for (const name of targetEntries) {
    if (canonical.has(name)) continue;
    const target = join(targetRoot, name);
    if (isLink(target)) {
      if (!existsSync(target)) actions.push({ kind: "remove", name, target, reason: "dangling link" });
      else if (!opts.skip?.has(name)) actions.push({ kind: "conflict", name, target, reason: `link to ${readlinkSync(target)} outside the canonical roots` });
      continue;
    }
    if (manifest.skills[name]) actions.push({ kind: "remove", name, target, reason: "removed from canonical source" });
    else if (opts.promoteTo && existsSync(join(target, "SKILL.md"))) actions.push({ kind: "promote", name, source: target, target: join(opts.promoteTo, name) });
  }
  return { scope, targetRoot, actions };
}

function gitIgnored(repo: string, rel: string): boolean {
  const p = Bun.spawnSync(["git", "-C", repo, "check-ignore", "-q", rel]);
  return p.exitCode === 0;
}

export function planAll(repos: string[] = []): { plans: SyncPlan[]; skippedRepos: { repo: string; reason: string }[] } {
  const userSources = [agentsHome("skills"), codexHome("skills")];
  const pluginSkills = claudePluginSkillNames();
  const user = planOne("user", userSources, claudeHome("skills"), { promoteTo: userSources[0], skip: pluginSkills });
  // Repo copies only carry repo-specific skills; anything available at user level or from a plugin already loads.
  const userLevel = new Set([...pluginSkills, ...userSources.flatMap((r) => [...listSkillDirs(r).keys()])]);
  const plans = [user];
  const skippedRepos: { repo: string; reason: string }[] = [];
  for (const repo of repos) {
    if (!existsSync(join(repo, ".agents", "skills"))) continue;
    // Only write where the repo treats .claude/skills as generated, machine-local output.
    if (!gitIgnored(repo, ".claude/skills/x/SKILL.md")) {
      skippedRepos.push({ repo, reason: ".claude/skills is not gitignored; copying would create tracked files" });
      continue;
    }
    plans.push(planOne(`repo:${basename(repo)}`, [join(repo, ".agents", "skills")], join(repo, ".claude", "skills"), { skip: userLevel }));
  }
  return { plans, skippedRepos };
}

export const MANIFEST_FILE = MANIFEST;

/** Resolve an edited copy: overwrite it from canonical, or make it the new canonical. Both re-record the hash. */
export function resolveConflict(plan: SyncPlan, name: string, choice: "use-canonical" | "keep-edit"): string {
  const a = plan.actions.find((x) => x.kind === "conflict" && x.name === name);
  if (!a || a.kind !== "conflict" || !a.source) throw new Error(`no resolvable conflict for ${name} in ${plan.scope}`);
  const manifest = readManifest(plan.targetRoot);
  if (choice === "use-canonical") {
    rmSync(a.target, { recursive: true, force: true });
    cpSync(realpathSync(a.source), a.target, { recursive: true, dereference: true });
  } else {
    const source = realpathSync(a.source);
    rmSync(source, { recursive: true, force: true });
    cpSync(a.target, source, { recursive: true, dereference: true });
  }
  manifest.skills[name] = { source: a.source, hash: hashDir(a.target), syncedAt: new Date().toISOString() };
  writeFileSync(join(plan.targetRoot, MANIFEST), `${JSON.stringify(manifest, null, 2)}\n`);
  return `${choice} ${name}`;
}

export function applyPlan(plan: SyncPlan): string[] {
  const log: string[] = [];
  const manifest = readManifest(plan.targetRoot);
  const now = new Date().toISOString();
  for (const a of plan.actions) {
    switch (a.kind) {
      case "copy":
      case "update":
      case "replace-link":
        rmSync(a.target, { recursive: true, force: true });
        cpSync(realpathSync(a.source), a.target, { recursive: true, dereference: true });
        manifest.skills[a.name] = { source: a.source, hash: hashDir(a.target), syncedAt: now };
        log.push(`${a.kind} ${a.name}`);
        break;
      case "adopt":
        manifest.skills[a.name] = { source: a.source, hash: hashDir(a.target), syncedAt: now };
        log.push(`adopt ${a.name}`);
        break;
      case "promote":
        if (existsSync(a.target)) {
          log.push(`skip promote ${a.name}: ${a.target} exists`);
          break;
        }
        cpSync(a.source, a.target, { recursive: true, dereference: true });
        manifest.skills[a.name] = { source: a.target, hash: hashDir(a.source), syncedAt: now };
        log.push(`promote ${a.name} -> ${a.target}`);
        break;
      case "remove":
        rmSync(a.target, { recursive: true, force: true });
        delete manifest.skills[a.name];
        log.push(`remove ${a.name} (${a.reason})`);
        break;
      case "conflict":
        log.push(`CONFLICT ${a.name}: ${a.reason}`);
        break;
    }
  }
  writeFileSync(join(plan.targetRoot, MANIFEST), `${JSON.stringify(manifest, null, 2)}\n`);
  return log;
}

if (import.meta.main) {
  const apply = process.argv.includes("--apply");
  const repos = process.argv.filter((a) => a.startsWith("--repo=")).map((a) => resolve(expand(a.slice(7))));
  const { plans, skippedRepos } = planAll(repos);
  for (const plan of plans) {
    const counts = plan.actions.reduce<Record<string, number>>((m, a) => ((m[a.kind] = (m[a.kind] ?? 0) + 1), m), {});
    console.log(`\n# ${plan.scope} → ${plan.targetRoot}  ${JSON.stringify(counts)}`);
    for (const a of plan.actions) if (a.kind !== "adopt") console.log(`  ${a.kind.padEnd(12)} ${a.name}${"reason" in a ? `  (${a.reason})` : ""}`);
    if (apply) for (const line of applyPlan(plan)) console.log(`  ✓ ${line}`);
  }
  for (const s of skippedRepos) console.log(`\n# skipped ${s.repo}: ${s.reason}`);
  if (!apply) console.log("\nPlan only. Re-run with --apply to write.");
}
