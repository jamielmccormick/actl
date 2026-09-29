// Plan: diff the manifest (intent) against the inventory (actual) into reviewable actions. Read-only.
// Each action carries the steps `apply` will run; ids are stable for identical drift so the app can keep
// a selection across refreshes.
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { claudeHome, claudeJsonPath, codexHome, expand, paths, tilde } from "./config";
import { claudeInstructionMode } from "./budget";
import type { FullInventory } from "./inventory";
import { loadManifest, type Manifest, providerKind, type ProviderSpec, tomlValue } from "./manifest";
import type { Service } from "./services";
import { planAll, type SyncAction } from "./skills-sync";
import { versionNewer } from "./status";
import { estTokens, frontmatter, hasPathsFrontmatter, readJson, readText, readToml } from "./util";

export type HarnessId = "claude" | "codex" | (string & {});
export type PlanKind =
  | "skills.sync" | "skills.resolve-conflict" | "mcp.add" | "mcp.remove" | "plugin.install" | "plugin.uninstall"
  | "plugin.enable" | "plugin.disable" | "service.make-lazy" | "rule.rescope" | "instructions.mode" | "proxy.update";
export type PlanAction = {
  id: string;
  harness?: HarnessId | "proxy";
  group: "instructions" | "skills" | "services" | "plugins" | "proxy";
  kind: PlanKind;
  title: string;
  detail?: string;
  consequence?: string;
  tokensDelta?: number;
  diff?: { path: string; before: string; after: string };
  requiresChoice?: { options: { id: string; label: string }[] };
  reversible: boolean;
  defaultSelected: boolean;
};
export type Plan = { manifestPath: string; manifestExists: boolean; manifestErrors: string[]; actions: PlanAction[]; summary: { count: number; tokensDelta: Record<string, number> } };

/** What apply runs. `inverse` is what undo runs; file writes are undone from backups. */
export type Step =
  | { type: "cmd"; argv: string[]; inverse?: string[] }
  | { type: "write"; path: string; content: string }
  | { type: "skills-sync"; scope: string }
  | { type: "skills-resolve"; scope: string; name: string };
export type Planned = PlanAction & { steps: Step[] };

const HARNESS_NAME: Record<string, string> = { claude: "Claude Code", codex: "Codex" };
const hn = (h: string) => HARNESS_NAME[h] ?? h;

// ---------- current MCP config (user scope), read live for exact names and inverse commands ----------

type McpConf = { url?: string; command?: string; args?: string[]; hasSecrets: boolean };
function claudeUserMcp(): Record<string, McpConf> {
  const servers = readJson(claudeJsonPath)?.mcpServers ?? {};
  return Object.fromEntries(
    Object.entries<any>(servers).map(([n, c]) => [n, { url: c?.url, command: c?.command, args: c?.args, hasSecrets: !!(c?.headers && Object.keys(c.headers).length) || !!(c?.env && Object.keys(c.env).length) }]),
  );
}
function codexMcp(): Record<string, McpConf> {
  const servers = readToml(codexHome("config.toml"))?.mcp_servers ?? {};
  return Object.fromEntries(
    Object.entries<any>(servers).map(([n, c]) => [n, { url: c?.url, command: c?.command, args: c?.args, hasSecrets: !!(c?.env || c?.http_headers || c?.env_http_headers || c?.bearer_token_env_var || c?.bearer_token) }]),
  );
}

export function mcpAddArgv(harness: string, name: string, spec: { url?: string; command?: string; args?: string[]; oauth?: { clientId?: string; callbackPort?: number } }): string[] {
  if (harness === "claude") {
    const oauth = [...(spec.oauth?.clientId ? ["--client-id", spec.oauth.clientId] : []), ...(spec.oauth?.callbackPort ? ["--callback-port", String(spec.oauth.callbackPort)] : [])];
    return spec.url ? ["claude", "mcp", "add", "-s", "user", "-t", "http", ...oauth, name, spec.url] : ["claude", "mcp", "add", "-s", "user", name, "--", spec.command!, ...(spec.args ?? [])];
  }
  return spec.url ? ["codex", "mcp", "add", name, "--url", spec.url] : ["codex", "mcp", "add", name, "--", spec.command!, ...(spec.args ?? [])];
}
const mcpRemoveArgv = (harness: string, name: string) => (harness === "claude" ? ["claude", "mcp", "remove", "-s", "user", name] : ["codex", "mcp", "remove", name]);
const pluginArgv = (harness: string, verb: "install" | "uninstall" | "enable" | "disable", id: string) =>
  harness === "claude" ? ["claude", "plugin", verb, id, "-s", "user"] : ["codex", "plugin", verb === "install" ? "add" : "remove", id];

// ---------- file edits ----------

/** Give a rule `paths:` frontmatter, keeping any other frontmatter keys. */
export function rescopeRule(text: string, globs: string[]): string {
  const list = `paths:\n${globs.map((g) => `  - ${JSON.stringify(g)}`).join("\n")}`;
  const fm = text.match(/^---\n([\s\S]*?)\n---\n?/);
  if (!fm) return `---\n${list}\n---\n${text}`;
  const body = fm[1].replace(/^paths:.*(\n[ \t]+.*)*/m, "").replace(/\n{2,}/g, "\n").trimEnd();
  return `---\n${body ? `${body}\n` : ""}${list}\n---\n${text.slice(fm[0].length)}`;
}

/** Rewrite one harness line inside a `[service.<id>]` table of a manifest actl wrote. */
export function setServiceProvider(manifestText: string, serviceId: string, harness: string, spec: ProviderSpec): string | undefined {
  const lines = manifestText.split("\n");
  const start = lines.findIndex((l) => l.trim() === `[service.${serviceId}]`);
  if (start < 0) return undefined;
  let end = lines.findIndex((l, i) => i > start && /^\s*\[/.test(l));
  if (end < 0) end = lines.length;
  const line = `${harness} = ${tomlValue(spec)}`;
  const at = lines.findIndex((l, i) => i > start && i < end && new RegExp(`^\\s*${harness}\\s*=`).test(l));
  if (at >= 0) lines[at] = line;
  else lines.splice(start + 1, 0, line);
  return lines.join("\n");
}

// ---------- the plan ----------

export function buildPlan(inv: FullInventory, opts: { manifestPath?: string; proxySnapshot?: any } = {}): { plan: Plan; planned: Planned[] } {
  const loaded = loadManifest(opts.manifestPath ?? paths.manifest);
  const manifest: Manifest | undefined = loaded.errors.length ? undefined : loaded.manifest;
  const planned: Planned[] = [];
  const services = new Map(inv.services.map((s) => [s.id, s]));
  const claudeServers = claudeUserMcp();
  const codexServers = codexMcp();
  const serversOf = (h: string) => (h === "claude" ? claudeServers : codexServers);
  const add = (a: Planned) => {
    if (!planned.some((p) => p.id === a.id)) planned.push(a);
  };

  const removalFor = (s: Service, h: string, why: string) => {
    const cur = s.providers[h];
    if (!cur) return;
    const cost = cur.contextTokens ? -cur.contextTokens : undefined;
    if (cur.kind === "plugin" || cur.kind === "connector")
      add({
        id: `plugin.uninstall:${h}:${s.id}`, harness: h, group: "plugins", kind: "plugin.uninstall",
        title: `Uninstall the ${s.name} ${cur.kind === "connector" ? "connector" : "plugin"} from ${hn(h)}`, detail: `${cur.ref}. ${why}`,
        consequence: cur.skills.length ? `Removes its ${cur.skills.length} skills and its MCP server.` : "Removes its MCP server.",
        tokensDelta: cost, reversible: true, defaultSelected: true,
        steps: [{ type: "cmd", argv: pluginArgv(h, "uninstall", cur.ref), inverse: pluginArgv(h, "install", cur.ref) }],
      });
    else if (cur.kind === "mcp" && cur.serverName && serversOf(h)[cur.serverName]) {
      const conf = serversOf(h)[cur.serverName];
      const reversible = !conf.hasSecrets && !!(conf.url || conf.command);
      add({
        id: `mcp.remove:${h}:${s.id}`, harness: h, group: "services", kind: "mcp.remove",
        title: `Remove the ${s.name} MCP server from ${hn(h)}`, detail: `Server "${cur.serverName}". ${why}`,
        consequence: reversible ? "Its stored sign-in may need redoing if you add it back." : "Undo can't restore its headers or env values; the config file is still backed up.",
        reversible, defaultSelected: true,
        steps: [{ type: "cmd", argv: mcpRemoveArgv(h, cur.serverName), inverse: reversible ? mcpAddArgv(h, cur.serverName, conf) : undefined }],
      });
    }
  };

  for (const [id, spec] of Object.entries(manifest?.service ?? {})) {
    const s = services.get(id);
    const name = spec.name ?? s?.name ?? id;
    for (const h of ["claude", "codex"]) {
      const want = spec[h] as ProviderSpec | undefined;
      const cur = s?.providers[h];
      if (spec.state === "removed" || want?.removed) {
        if (s) removalFor(s, h, spec.state === "removed" ? "The manifest marks this service removed." : `The manifest removes it from ${hn(h)}.`);
        continue;
      }
      if (!want) continue;
      const kind = providerKind(want);
      if (kind === "plugin" || kind === "connector") {
        const ref = (want.plugin ?? want.connector)!;
        const record = h === "claude" ? inv.plugins.claude.find((p) => p.id === ref) : inv.plugins.codex.find((p) => p.id === ref);
        if (!record)
          add({
            id: `plugin.install:${h}:${id}`, harness: h, group: "plugins", kind: "plugin.install",
            title: `Install the ${name} ${kind} in ${hn(h)}`, detail: ref,
            consequence: kind === "connector" ? "Its sign-in is managed in ChatGPT." : "Adds the plugin's skills to every session; sign in to its server afterwards.",
            reversible: true, defaultSelected: true,
            steps: [{ type: "cmd", argv: pluginArgv(h, "install", ref), inverse: pluginArgv(h, "uninstall", ref) }],
          });
        else if (h === "claude" && !record.enabled && want.enabled !== false)
          add({
            id: `plugin.enable:claude:${id}`, harness: "claude", group: "plugins", kind: "plugin.enable",
            title: `Enable the ${name} plugin in Claude Code`, detail: ref, reversible: true, defaultSelected: true,
            tokensDelta: cur?.contextTokens || undefined,
            steps: [{ type: "cmd", argv: pluginArgv("claude", "enable", ref), inverse: pluginArgv("claude", "disable", ref) }],
          });
        else if (h === "claude" && record.enabled && want.enabled === false)
          add({
            id: `plugin.disable:claude:${id}`, harness: "claude", group: "plugins", kind: "plugin.disable",
            title: `Disable the ${name} plugin in Claude Code`, detail: ref, reversible: true, defaultSelected: true,
            tokensDelta: cur?.contextTokens ? -cur.contextTokens : undefined,
            steps: [{ type: "cmd", argv: pluginArgv("claude", "disable", ref), inverse: pluginArgv("claude", "enable", ref) }],
          });
      } else if (kind === "mcp") {
        const mcp = want.mcp!;
        const server = mcp.name ?? id;
        if (h === "claude" && cur?.kind === "plugin" && cur.health !== "absent" && cur.lazyAlternative) {
          add(makeLazy(s!, manifest, loaded.exists, true));
          continue;
        }
        if (serversOf(h)[server]) continue;
        add({
          id: `mcp.add:${h}:${id}`, harness: h, group: "services", kind: "mcp.add",
          title: `Add the ${name} MCP server to ${hn(h)}`, detail: `${server} → ${mcp.url ?? [mcp.command, ...(mcp.args ?? [])].join(" ")}`,
          consequence: mcp.url ? "Sign in to it afterwards." : undefined,
          tokensDelta: 0, reversible: true, defaultSelected: true,
          steps: [{ type: "cmd", argv: mcpAddArgv(h, server, mcp), inverse: mcpRemoveArgv(h, server) }],
        });
      }
    }
  }

  // Suggestions: any enabled plugin that could be swapped for its bare server. Off by default.
  for (const s of inv.services) {
    const p = s.providers.claude;
    if (p?.kind === "plugin" && p.health !== "absent" && p.lazyAlternative && manifest?.service?.[s.id]?.state !== "removed") add(makeLazy(s, manifest, loaded.exists, false));
  }

  for (const [rid, r] of Object.entries(manifest?.policy?.rules ?? {})) {
    const file = expand(r.file);
    const before = readText(file);
    if (before === undefined || hasPathsFrontmatter(before)) continue;
    const after = rescopeRule(before, r.paths);
    add({
      id: `rule.rescope:claude:${rid}`, harness: "claude", group: "instructions", kind: "rule.rescope",
      title: `Re-scope the ${rid} rule to its paths`, detail: `${tilde(file)} loads in every session; the manifest scopes it to ${r.paths.length} path patterns.`,
      consequence: "Loads only when Claude reads a matching file.",
      tokensDelta: -estTokens(before), diff: { path: tilde(file), before, after }, reversible: true, defaultSelected: true,
      steps: [{ type: "write", path: file, content: after }],
    });
  }

  const mode = manifest?.policy?.claude?.instruction_files;
  const file = claudeHome("settings.json");
  const before = readText(file) ?? "{}\n";
  const settings = (() => {
    try {
      return JSON.parse(before || "{}");
    } catch {
      return undefined; // unreadable settings: leave them to the user rather than rewrite them
    }
  })();
  if (mode && mode !== claudeInstructionMode() && settings) {
    settings.pluginConfigs ??= {};
    settings.pluginConfigs["agents-md@builtin"] ??= {};
    settings.pluginConfigs["agents-md@builtin"].options = { ...(settings.pluginConfigs["agents-md@builtin"].options ?? {}), instructionFiles: mode };
    const after = `${JSON.stringify(settings, null, 2)}\n`;
    add({
      id: "instructions.mode:claude", harness: "claude", group: "instructions", kind: "instructions.mode",
      title: `Set Claude's instruction files to ${mode}`, detail: `Currently ${claudeInstructionMode()}.`,
      consequence: "Changes which AGENTS.md and CLAUDE.md files load in every project.",
      diff: { path: tilde(file), before, after }, reversible: true, defaultSelected: true,
      steps: [{ type: "write", path: file, content: after }],
    });
  }

  planSkills(inv, manifest).forEach(add);
  planProxy(opts.proxySnapshot ?? readJson(paths.proxyCache)).forEach(add);

  const tokensDelta: Record<string, number> = {};
  for (const a of planned) if (a.defaultSelected && a.tokensDelta && a.harness) tokensDelta[a.harness] = (tokensDelta[a.harness] ?? 0) + a.tokensDelta;
  const actions = planned.map(({ steps: _, ...a }) => a);
  return { plan: { manifestPath: loaded.path, manifestExists: loaded.exists, manifestErrors: loaded.errors, actions, summary: { count: actions.length, tokensDelta } }, planned };
}

function makeLazy(s: Service, manifest: Manifest | undefined, manifestExists: boolean, wanted: boolean): Planned {
  const p = s.providers.claude!;
  const lazy = p.lazyAlternative!;
  const steps: Step[] = [{ type: "cmd", argv: pluginArgv("claude", "disable", p.ref), inverse: pluginArgv("claude", "enable", p.ref) }];
  if (!claudeUserMcp()[lazy.serverName]) steps.push({ type: "cmd", argv: mcpAddArgv("claude", lazy.serverName, lazy), inverse: mcpRemoveArgv("claude", lazy.serverName) });
  // Keep the manifest truthful, or the next plan would try to reinstall the plugin.
  const spec = manifest?.service?.[s.id]?.claude as ProviderSpec | undefined;
  let diff: PlanAction["diff"];
  if (manifestExists && spec?.plugin) {
    const before = readFileSync(paths.manifest, "utf8");
    const after = setServiceProvider(before, s.id, "claude", { mcp: { name: lazy.serverName, url: lazy.url }, why: `made lazy by actl: the plugin cost ~${p.contextTokens ?? 0} tokens per session` });
    if (after && after !== before) {
      steps.push({ type: "write", path: paths.manifest, content: after });
      diff = { path: tilde(paths.manifest), before, after };
    }
  }
  return {
    id: `service.make-lazy:claude:${s.id}`, harness: "claude", group: "services", kind: "service.make-lazy",
    title: `Make ${s.name} lazy in Claude Code`,
    detail: `${wanted ? "" : "Suggestion. "}Disable ${p.ref} and add its HTTP server "${lazy.serverName}" at user scope (${lazy.url}).`,
    consequence: `Drops the plugin's ${p.skills.length} skills from every session; the MCP tools stay. Sign in to the new server once.`,
    tokensDelta: p.contextTokens ? -p.contextTokens : undefined, diff, reversible: true, defaultSelected: wanted,
    steps,
  };
}

/** Repos whose skills are synced: the manifest's list when it has one, else every discovered repo. */
export function skillRepos(inv: FullInventory, manifest = loadManifest().manifest): string[] {
  const repos = manifest?.skills?.repos
    ? Object.entries(manifest.skills.repos).filter(([, m]) => m === "sync").map(([r]) => expand(r))
    : inv.repos.filter((r) => r.kind === "repo").map((r) => expand(r.path));
  return repos.filter((r) => existsSync(r));
}

function planSkills(inv: FullInventory, manifest: Manifest | undefined): Planned[] {
  const out: Planned[] = [];
  const listing = (dir: string) => {
    const fm = frontmatter(readText(join(dir, "SKILL.md")) ?? "");
    return estTokens(`- ${fm.name ?? ""}: ${fm.description ?? ""}\n`);
  };
  for (const plan of planAll(skillRepos(inv, manifest)).plans) {
    const scope = plan.scope;
    const work = plan.actions.filter((a) => a.kind !== "conflict" && a.kind !== "adopt");
    if (work.length) {
      const delta = work.reduce((n, a: SyncAction) => n + (a.kind === "copy" || a.kind === "promote" ? listing(a.source) : a.kind === "remove" ? -listing(a.target) : 0), 0);
      out.push({
        id: `skills.sync:${scope}`, harness: "claude", group: "skills", kind: "skills.sync",
        title: `Sync ${work.length} skill ${work.length === 1 ? "change" : "changes"} into Claude Code (${scope})`,
        detail: work.map((a) => `${a.kind} ${a.name}`).join(", "),
        consequence: `Writes copies under ${tilde(plan.targetRoot)}; edited copies are never overwritten.`,
        tokensDelta: delta || undefined, reversible: true, defaultSelected: true,
        steps: [{ type: "skills-sync", scope }],
      });
    }
    for (const a of plan.actions) {
      // Only conflicts with a canonical source can be resolved by choosing a side.
      if (a.kind !== "conflict" || a.reason.startsWith("link to")) continue;
      out.push({
        id: `skills.resolve-conflict:${scope}:${a.name}`, harness: "claude", group: "skills", kind: "skills.resolve-conflict",
        title: `Resolve the edited copy of ${a.name}`, detail: `${tilde(a.target)}: ${a.reason}.`,
        requiresChoice: { options: [{ id: "use-canonical", label: "Replace the copy with the canonical skill" }, { id: "keep-edit", label: "Make the edited copy canonical" }] },
        reversible: true, defaultSelected: false,
        steps: [{ type: "skills-resolve", scope, name: a.name }],
      });
    }
  }
  return out;
}

function planProxy(snap: any): Planned[] {
  if (!snap?.installedVersion) return [];
  if (!versionNewer(snap.latestVersion, snap.installedVersion)) return [];
  return [{
    id: "proxy.update", harness: "proxy", group: "proxy", kind: "proxy.update",
    title: `Update CLIProxyAPI to ${snap.latestVersion}`, detail: `Installed: ${snap.installedVersion}. Runs brew upgrade, then restarts the brew service.`,
    consequence: "Brief restart of the proxy (~3 s); requests in flight may fail.",
    reversible: false, defaultSelected: false,
    // The first step fails fast when the proxy wasn't installed with Homebrew.
    steps: [{ type: "cmd", argv: ["brew", "list", "--versions", "cliproxyapi"] }, { type: "cmd", argv: ["brew", "upgrade", "cliproxyapi"] }, { type: "cmd", argv: ["brew", "services", "restart", "cliproxyapi"] }],
  }];
}
