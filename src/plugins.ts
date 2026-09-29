// Plugin metadata the harness CLIs don't report: which MCP servers a Claude plugin declares, what a Codex
// plugin's manifest says about its brand, marketplace homepages, and cached always-on token costs.
import { existsSync, statSync } from "node:fs";
import { join } from "node:path";
import { claudeHome, codexHome, paths } from "./config";
import { ls, readJson, run, writeFileAtomic } from "./util";

export type McpDecl = {
  name: string;
  transport: "http" | "sse" | "stdio";
  url?: string;
  command?: string;
  args?: string[];
  headerNames: string[];
  /** A header or env value needs a variable the user must supply (e.g. a bearer token). */
  needsEnv: boolean;
  oauth?: { clientId?: string; callbackPort?: number };
};

const SECRET_PARAM = /key|token|secret|auth|sig|password|pass|credential/i;

/** Drop tracking and anything credential-shaped from a URL's query string. */
export function cleanUrl(url: string): string {
  try {
    const u = new URL(url);
    for (const k of [...u.searchParams.keys()]) if (k.startsWith("utm_") || SECRET_PARAM.test(k)) u.searchParams.delete(k);
    const s = u.toString();
    return u.search || url.endsWith("/") ? s : s.replace(/\/$/, "");
  } catch {
    return url.split("?")[0];
  }
}

function declsFrom(obj: any): McpDecl[] {
  const map = obj?.mcpServers ?? obj;
  if (!map || typeof map !== "object" || Array.isArray(map)) return [];
  return Object.entries(map as Record<string, any>).flatMap(([name, c]) => {
    if (!c || typeof c !== "object") return [];
    const headers = c.headers && typeof c.headers === "object" ? c.headers : {};
    const env = c.env && typeof c.env === "object" ? c.env : {};
    const transport = c.type === "sse" ? "sse" : c.type === "http" || (c.url && !c.command) ? "http" : "stdio";
    return [{
      name,
      transport,
      url: typeof c.url === "string" ? cleanUrl(c.url) : undefined,
      command: typeof c.command === "string" ? c.command : undefined,
      args: Array.isArray(c.args) ? c.args.map(String) : undefined,
      headerNames: Object.keys(headers),
      needsEnv: [...Object.values(headers), ...Object.values(env)].some((v) => typeof v === "string" && v.includes("${")),
      oauth: c.oauth && (c.oauth.clientId || c.oauth.callbackPort) ? { clientId: c.oauth.clientId, callbackPort: c.oauth.callbackPort } : undefined,
    } satisfies McpDecl];
  });
}

/** Servers a Claude plugin declares: root .mcp.json plus plugin.json `mcpServers` (inline or a path). */
export function claudePluginMcp(installPath?: string): McpDecl[] {
  if (!installPath || !existsSync(installPath)) return [];
  const manifest = readJson(join(installPath, ".claude-plugin", "plugin.json")) ?? {};
  const out = [...declsFrom(readJson(join(installPath, ".mcp.json")))];
  const decl = manifest.mcpServers;
  for (const d of typeof decl === "string" ? [decl] : Array.isArray(decl) ? decl : []) if (typeof d === "string") out.push(...declsFrom(readJson(join(installPath, d))));
  if (decl && typeof decl === "object" && !Array.isArray(decl)) out.push(...declsFrom(decl));
  const seen = new Set<string>();
  return out.filter((d) => !seen.has(d.name) && seen.add(d.name));
}

/** The one HTTP server a plugin could be swapped for. Multi-server plugins and env-token servers don't qualify. */
export function lazyAlternative(decls: McpDecl[]): { transport: "http"; url: string; serverName: string; oauth?: McpDecl["oauth"] } | undefined {
  if (decls.length !== 1) return undefined;
  const d = decls[0];
  if (d.transport !== "http" || !d.url || d.needsEnv) return undefined;
  return { transport: "http", url: d.url, serverName: d.name, oauth: d.oauth };
}

// ---------- marketplaces ----------

const marketplaceCache = new Map<string, Map<string, any>>();
export function marketplaceEntry(pluginId: string): { homepage?: string; description?: string } | undefined {
  const [name, mkt] = pluginId.split("@");
  if (!mkt) return undefined;
  if (!marketplaceCache.has(mkt)) {
    const m = readJson(claudeHome("plugins", "marketplaces", mkt, ".claude-plugin", "marketplace.json"));
    marketplaceCache.set(mkt, new Map((m?.plugins ?? []).map((p: any) => [p?.name, p])));
  }
  const e = marketplaceCache.get(mkt)!.get(name);
  return e ? { homepage: typeof e.homepage === "string" ? e.homepage : undefined, description: e.description } : undefined;
}

// ---------- Codex plugin manifests ----------

export type CodexPluginMeta = {
  id: string;
  displayName?: string;
  logo?: string;
  brandColor?: string;
  homepage?: string;
  /** Ships a ChatGPT app for an outside system. OpenAI's own apps (templates, pets, …) don't count. */
  app: boolean;
  mcp: McpDecl[];
};

function latestVersionDir(dir: string): string | undefined {
  return ls(dir)
    .map((v) => ({ p: join(dir, v), t: statSync(join(dir, v)).mtimeMs }))
    .filter((v) => statSync(v.p).isDirectory())
    .sort((a, b) => b.t - a.t)[0]?.p;
}

let codexMetaCache: Map<string, CodexPluginMeta> | undefined;
export function codexPluginMeta(): Map<string, CodexPluginMeta> {
  if (codexMetaCache) return codexMetaCache;
  const out = new Map<string, CodexPluginMeta>();
  const root = codexHome("plugins", "cache");
  for (const mkt of ls(root))
    for (const name of ls(join(root, mkt))) {
      const dir = latestVersionDir(join(root, mkt, name));
      if (!dir) continue;
      const m = readJson(join(dir, ".codex-plugin", "plugin.json")) ?? {};
      const ui = m.interface ?? {};
      const logoRel = typeof ui.logo === "string" ? ui.logo : typeof ui.composerIcon === "string" ? ui.composerIcon : undefined;
      const logo = logoRel ? join(dir, logoRel) : undefined;
      out.set(`${name}@${mkt}`, {
        id: `${name}@${mkt}`,
        displayName: typeof ui.displayName === "string" ? ui.displayName : undefined,
        logo: logo && existsSync(logo) ? logo : undefined,
        brandColor: typeof ui.brandColor === "string" && /^#[0-9a-f]{3,8}$/i.test(ui.brandColor) ? ui.brandColor : undefined,
        homepage: [m.homepage, ui.websiteURL].find((u) => typeof u === "string" && /^https?:\/\//.test(u)),
        app: Object.values<any>(readJson(join(dir, ".app.json"))?.apps ?? {}).some((a) => typeof a?.id === "string" && !a.id.startsWith("connector_openai_")),
        mcp: declsFrom(readJson(join(dir, ".mcp.json"))),
      });
    }
  codexMetaCache = out;
  return out;
}

// ---------- always-on token costs ----------

type CostCache = { version: 1; costs: Record<string, { tokens: number; at: string }> };
const readCosts = (): CostCache => readJson(paths.pluginCosts) ?? { version: 1, costs: {} };

export function cachedCost(id: string, version?: string): number | undefined {
  return readCosts().costs[`${id}@${version ?? "unknown"}`]?.tokens;
}

/** Parses "Always-on:   ~1,066 tok" (or "~1.2k tok") from `claude plugin details`. */
export function parseAlwaysOn(text: string): number | undefined {
  const m = text.match(/Always-on:\s*~?\s*([\d.,]+)\s*(k)?\s*tok/i);
  if (!m) return undefined;
  const n = Number(m[1].replace(/,/g, ""));
  return Number.isFinite(n) ? Math.round(m[2] ? n * 1000 : n) : undefined;
}

/** Runs the slow CLI for each plugin not cached yet. Never on the hot path: `inventory` runs this in the background. */
export function refreshCosts(plugins: { id: string; version?: string }[], force = false): { id: string; tokens?: number }[] {
  const cache = readCosts();
  const results: { id: string; tokens?: number }[] = [];
  for (const p of plugins) {
    const key = `${p.id}@${p.version ?? "unknown"}`;
    if (!force && cache.costs[key]) continue;
    const tokens = parseAlwaysOn(run(["claude", "plugin", "details", p.id], undefined, 30_000).out);
    if (tokens !== undefined) cache.costs[key] = { tokens, at: new Date().toISOString() };
    results.push({ id: p.id, tokens });
  }
  writeFileAtomic(paths.pluginCosts, `${JSON.stringify(cache, null, 2)}\n`);
  return results;
}
