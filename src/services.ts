// Services: outside systems (Notion, Sentry, …) and how each harness provides them. A plugin, a bare MCP
// server, a ChatGPT connector and a claude.ai connector are all ways to provide the same service.
// Skills-only plugins are not services; they show up under skills.
import { type collect, serviceKey } from "./collect";
import { cachedLogo } from "./logos";
import type { Manifest } from "./manifest";
import { specFor } from "./manifest";
import { cachedCost, codexPluginMeta, lazyAlternative, marketplaceEntry, type CodexPluginMeta } from "./plugins";
import { existsSync } from "node:fs";
import { join } from "node:path";
import { expand } from "./config";
import { estTokens, frontmatter, readText } from "./util";

export type Inventory = ReturnType<typeof collect>;
export type Health = "connected" | "needs-auth" | "failed" | "blocked" | "pending" | "unknown" | "absent";
export type Provider = {
  kind: "plugin" | "mcp" | "connector" | "claude.ai";
  ref: string;
  serverName?: string;
  health: Health;
  detail?: string;
  auth: "oauth" | "token" | "none" | "chatgpt" | "unknown";
  canSignIn: boolean;
  contextTokens?: number;
  contextEstimated?: boolean;
  skills: string[];
  lazyAlternative?: { transport: "http"; url: string; serverName: string; oauth?: { clientId?: string; callbackPort?: number } };
};
export type Service = {
  id: string;
  name: string;
  brandColor?: string;
  logo?: string;
  homepage?: string;
  providers: Partial<Record<string, Provider>>;
  parity: "both" | "only-claude" | "only-codex" | "gap" | "partial";
  gapReason?: string;
};

type ClaudePlugin = Inventory["plugins"]["claude"][number];
type Row = Inventory["mcp"]["rows"][number];

// Tools Codex ships for itself; their servers are part of the harness, not outside systems.
const CODEX_BUILTIN_MARKETPLACES = new Set(["openai-bundled", "openai-primary-runtime"]);
const clip = (s: string, max = 240) => (s.length > max ? `${s.slice(0, max)}…` : s);
const WORST_FIRST = ["failed", "needs-auth", "blocked", "pending", "unknown", "connected"];
const CODE_HOSTS = /^https?:\/\/(www\.)?(github\.com|gitlab\.com|bitbucket\.org)\/[^/]+/;
const BLOCKED_REASON = "claude.ai connectors are disabled while proxy or API-key auth is active";

/** Tools a harness ships for itself (Codex's bundled computer-use servers and the like) are not services. */
const isBuiltin = (r: Row) => !r.claude && !!r.codex && r.codex.transport === "stdio" && /^\.\/|\.app\/Contents\/|openai-bundled|codex-runtimes/.test(r.target);

export const pretty = (s: string) =>
  s
    .replace(/[-_](plugin|sales|crm|mcp|ai-companion|desktop)$/i, "")
    .split(/[-_\s]+/)
    .map((w) => w.charAt(0).toUpperCase() + w.slice(1))
    .join(" ");

/** The always-on cost of an enabled Claude plugin: cached from `claude plugin details`, else estimated from its skills. */
export function pluginContext(p: ClaudePlugin): { tokens: number; estimated: boolean } {
  const cached = cachedCost(p.id, p.version);
  if (cached !== undefined) return { tokens: cached, estimated: false };
  const dir = p.installPath ? expand(p.installPath) : undefined;
  if (!dir || !existsSync(dir)) return { tokens: 0, estimated: true };
  // Plugins may keep skills anywhere in the install, so search it rather than only skills/<name>/.
  let listing = "";
  for (const md of new Bun.Glob("**/SKILL.md").scanSync({ cwd: dir, followSymlinks: false })) {
    if (md.includes("node_modules/")) continue;
    const fm = frontmatter(readText(join(dir, md)) ?? "");
    listing += `- ${fm.name ?? ""}: ${fm.description ?? ""}\n`;
  }
  return { tokens: estTokens(listing), estimated: true };
}

function rootOf(url?: string): string | undefined {
  try {
    const host = new URL(url!).hostname.split(".");
    return `https://${host.slice(-2).join(".")}`;
  } catch {
    return undefined;
  }
}

function codexRowProvider(r: NonNullable<Row["codex"]>, meta: CodexPluginMeta | undefined, skills: string[]): Provider {
  if (r.transport === "connector")
    return { kind: "connector", ref: r.pluginId ?? "", health: r.enabled ? "connected" : "absent", detail: "ChatGPT connector; its sign-in is managed in ChatGPT", auth: "chatgpt", canSignIn: false, skills, contextTokens: 0 };
  const oauth = r.auth === "o_auth" || r.auth === "not_logged_in";
  const health: Health = !r.enabled ? "absent" : r.auth === "not_logged_in" ? "needs-auth" : "connected";
  const detail = !r.enabled ? "disabled in config.toml" : r.auth === "not_logged_in" ? "needs authentication" : "configured; Codex does not report live health";
  return {
    kind: "mcp",
    ref: r.serverName ?? "",
    serverName: r.serverName,
    health,
    detail,
    auth: oauth ? "oauth" : r.auth === "bearer_token" ? "token" : r.auth === "unsupported" ? "none" : "unknown",
    canSignIn: oauth && r.transport !== "stdio",
    skills: meta ? skills : [],
    contextTokens: 0,
  };
}

export function buildServices(inv: Inventory, manifest?: Manifest): Service[] {
  const services = new Map<string, Service>();
  const get = (id: string, name: string) => {
    if (!services.has(id)) services.set(id, { id, name, providers: {}, parity: "gap" });
    return services.get(id)!;
  };
  const codexMeta = [...codexPluginMeta().values()];
  const metaFor = (id: string) => codexMeta.find((m) => serviceKey(m.id) === id || (m.displayName && serviceKey(m.displayName) === id));
  const codexSkills = (pluginId?: string) => (pluginId ? inv.skills.filter((s) => s.source === "codex-plugin" && s.owner === pluginId).map((s) => s.name) : []);
  const pluginRows = (p: ClaudePlugin) => inv.mcp.rows.filter((r) => r.claude?.serverName?.toLowerCase().startsWith(`plugin:${p.name.toLowerCase()}:`));
  const homepages = new Map<string, string>();

  // Prefer an active provider over an absent one, then plugin > mcp > claude.ai for the same harness.
  const RANK = { plugin: 0, mcp: 1, connector: 1, "claude.ai": 2 } as const;
  const offer = (s: Service, harness: string, p: Provider) => {
    const cur = s.providers[harness];
    const better = !cur || (cur.health === "absent" && p.health !== "absent") || ((cur.health === "absent") === (p.health === "absent") && RANK[p.kind] < RANK[cur.kind]);
    if (better) s.providers[harness] = p;
  };

  for (const p of inv.plugins.claude) {
    if (!p.hasMcp) continue; // skills-only plugins are not services
    const id = serviceKey(`plugin:${p.name}:x`);
    const s = get(id, pretty(p.name));
    const rows = pluginRows(p);
    const worst = rows.map((r) => r.claude!).sort((a, b) => WORST_FIRST.indexOf(a.status) - WORST_FIRST.indexOf(b.status))[0];
    const cost = pluginContext(p);
    const http = p.mcpServers.some((d) => d.transport !== "stdio");
    offer(s, "claude", {
      kind: "plugin",
      ref: p.id,
      serverName: p.mcpServers.length === 1 ? rows[0]?.claude!.serverName : undefined,
      health: !p.enabled ? "absent" : worst ? worst.status : "unknown",
      detail: !p.enabled ? "plugin installed but disabled" : worst ? clip(worst.detail) : "not reported by `claude mcp list`",
      auth: http ? "oauth" : "none",
      // One OAuth server only: a server authenticated by an env token header can't be signed in to.
      canSignIn: p.enabled && p.mcpServers.length === 1 && http && !p.mcpServers[0].needsEnv && ["needs-auth", "failed", "connected"].includes(worst?.status ?? ""),
      contextTokens: p.enabled ? cost.tokens : 0,
      contextEstimated: cost.estimated,
      skills: inv.skills.filter((sk) => sk.source === "claude-plugin" && sk.owner === p.id).map((sk) => sk.name),
      lazyAlternative: lazyAlternative(p.mcpServers),
    });
    const home = marketplaceEntry(p.id)?.homepage;
    if (home && !CODE_HOSTS.test(home)) homepages.set(id, home);
    else if (!homepages.has(id)) {
      const root = rootOf(p.mcpServers.find((d) => d.url)?.url);
      if (root) homepages.set(id, root);
    }
  }

  for (const r of inv.mcp.rows) {
    if (isBuiltin(r)) continue;
    const id = serviceKey(r.name);
    if (r.claude && r.claude.scope !== "plugin") {
      const s = get(id, pretty(r.name.replace(/^claude\.ai\s+/, "")));
      if (r.claude.scope === "claude.ai") {
        s.name = r.name.replace(/^claude\.ai\s+/, "");
        offer(s, "claude", { kind: "claude.ai", ref: s.name, health: r.claude.status, detail: r.claude.detail, auth: "oauth", canSignIn: false, skills: [], contextTokens: 0 });
      } else {
        const http = /^https?:\/\//.test(r.target);
        offer(s, "claude", {
          kind: "mcp",
          ref: r.claude.serverName ?? r.name,
          serverName: r.claude.serverName,
          health: r.claude.status,
          detail: clip(r.claude.detail),
          auth: http ? "oauth" : "none",
          canSignIn: http && ["needs-auth", "failed", "connected"].includes(r.claude.status),
          skills: [],
          contextTokens: 0,
        });
        if (http && !homepages.has(id)) homepages.set(id, rootOf(r.target)!);
      }
    } else if (r.claude?.scope === "plugin" && !services.has(id)) {
      continue; // a plugin row whose plugin record is missing: nothing reliable to show
    }
    if (r.codex) {
      const s = get(id, pretty(r.name));
      const meta = r.codex.pluginId ? codexMeta.find((m) => m.id === r.codex!.pluginId) : undefined;
      offer(s, "codex", codexRowProvider(r.codex, meta, codexSkills(r.codex.pluginId)));
      if (!homepages.has(id) && /^https?:\/\//.test(r.target)) homepages.set(id, rootOf(r.target)!);
    }
  }

  // Codex plugins that bundle their own MCP server (not ChatGPT connectors).
  for (const p of inv.plugins.codex) {
    const meta = codexMeta.find((m) => m.id === p.id);
    if (!p.enabled || p.connector || !meta?.mcp.length || CODEX_BUILTIN_MARKETPLACES.has(p.id.split("@")[1])) continue;
    const id = serviceKey(p.id);
    const s = get(id, meta.displayName ?? pretty(p.id.split("@")[0]));
    offer(s, "codex", { kind: "plugin", ref: p.id, health: "unknown", detail: "plugin MCP server; Codex does not report live health", auth: meta.mcp.some((d) => d.transport !== "stdio") ? "oauth" : "none", canSignIn: false, skills: codexSkills(p.id), contextTokens: 0 });
  }

  for (const s of services.values()) {
    const connector = s.providers.codex?.kind === "connector" ? codexMeta.find((m) => m.id === s.providers.codex!.ref) : undefined;
    const meta = connector ?? metaFor(s.id);
    if (meta?.displayName) s.name = meta.displayName;
    s.brandColor = meta?.brandColor;
    s.homepage = [meta?.homepage, homepages.get(s.id)].find((u) => u && !CODE_HOSTS.test(u));
    s.logo = meta?.logo ?? cachedLogo(s.id);
    const active = (h: string) => {
      const p = s.providers[h];
      return !!p && p.health !== "absent" && p.health !== "blocked";
    };
    const claude = active("claude");
    const codex = active("codex");
    const gapNote = (h: string) => specFor(manifest, s.id, h)?.gap;
    if (claude && codex) s.parity = "both";
    else if (claude || codex) {
      const missing = claude ? "codex" : "claude";
      const mp = s.providers[missing];
      const note = gapNote(missing) ?? (mp?.health === "blocked" ? BLOCKED_REASON : undefined);
      if (note) {
        s.parity = "gap";
        s.gapReason = note;
      } else if (mp) {
        s.parity = "partial"; // present but switched off
        s.gapReason = mp.detail;
      } else s.parity = claude ? "only-claude" : "only-codex";
    } else {
      s.parity = "gap";
      s.gapReason = gapNote("claude") ?? gapNote("codex") ?? (s.providers.claude?.health === "blocked" ? BLOCKED_REASON : "no harness provides it right now");
    }
  }
  return [...services.values()].sort((a, b) => a.name.localeCompare(b.name));
}
