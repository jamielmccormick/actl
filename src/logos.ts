// Service logos fetched from each service's own homepage (apple-touch-icon or <link rel=icon>), cached for
// 30 days. Network access happens only in `actl logos refresh`; everything else reads the cache.
import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { paths } from "./config";
import { readJson, writeFileAtomic } from "./util";

type Index = { version: 1; logos: Record<string, { file?: string; source?: string; fetchedAt: string; error?: string }> };
const REFRESH_MS = 30 * 24 * 60 * 60_000;
const TIMEOUT_MS = 4_000;
const MAX_BYTES = 512 * 1024;
const indexPath = () => join(paths.logos, "index.json");
const readIndex = (): Index => readJson(indexPath()) ?? { version: 1, logos: {} };

export function cachedLogo(serviceId: string): string | undefined {
  const e = readIndex().logos[serviceId];
  return e?.file && existsSync(e.file) ? e.file : undefined;
}

const EXT: Record<string, string> = { "image/png": "png", "image/x-icon": "ico", "image/vnd.microsoft.icon": "ico", "image/svg+xml": "svg", "image/jpeg": "jpg", "image/webp": "webp", "image/gif": "gif" };

/** Icon candidates from a homepage, best first: apple-touch-icon, then the largest declared icon, then /favicon.ico. */
export function iconCandidates(html: string, base: string): string[] {
  const links = [...html.matchAll(/<link\b[^>]*>/gi)].map((m) => m[0]);
  const attr = (tag: string, name: string) => tag.match(new RegExp(`\\b${name}\\s*=\\s*["']([^"']+)["']`, "i"))?.[1];
  const scored = links
    .map((tag) => ({ rel: (attr(tag, "rel") ?? "").toLowerCase(), href: attr(tag, "href"), size: Number((attr(tag, "sizes") ?? "").split("x")[0]) || 0 }))
    .filter((l) => l.href && /(^|\s)(apple-touch-icon|icon)(\s|$)|shortcut icon/.test(l.rel))
    .map((l) => ({ ...l, score: (l.rel.includes("apple-touch-icon") ? 10_000 : 0) + l.size }))
    .sort((a, b) => b.score - a.score);
  const urls = [...scored.map((l) => l.href!), "/apple-touch-icon.png", "/favicon.ico"];
  return [...new Set(urls.map((u) => new URL(u, base).toString()))];
}

async function fetchIcon(homepage: string): Promise<{ bytes: Uint8Array; ext: string; source: string } | undefined> {
  let html = "";
  let base = homepage;
  try {
    const res = await fetch(homepage, { signal: AbortSignal.timeout(TIMEOUT_MS), headers: { "User-Agent": "actl (logo fetch)" } });
    base = res.url || homepage;
    html = res.ok ? (await res.text()).slice(0, 200_000) : "";
  } catch {
    // fall through to the conventional paths
  }
  for (const url of iconCandidates(html, base)) {
    try {
      const res = await fetch(url, { signal: AbortSignal.timeout(TIMEOUT_MS) });
      const type = (res.headers.get("content-type") ?? "").split(";")[0].trim();
      if (!res.ok || !EXT[type]) {
        await res.body?.cancel();
        continue;
      }
      const bytes = new Uint8Array(await res.arrayBuffer());
      if (bytes.length && bytes.length <= MAX_BYTES) return { bytes, ext: EXT[type], source: url };
    } catch {
      // try the next candidate
    }
  }
  return undefined;
}

/** Services that already carry a plugin-manifest logo are skipped: that mark is official and local. */
export async function refreshLogos(services: { id: string; homepage?: string; logo?: string }[], force = false) {
  const index = readIndex();
  mkdirSync(paths.logos, { recursive: true });
  const results: { id: string; state: "fetched" | "cached" | "skipped" | "failed"; file?: string; source?: string }[] = [];
  for (const s of services) {
    const prev = index.logos[s.id];
    if (!s.homepage || (s.logo && s.logo !== prev?.file)) {
      results.push({ id: s.id, state: "skipped" });
      continue;
    }
    if (!force && prev && Date.now() - Date.parse(prev.fetchedAt) < REFRESH_MS) {
      results.push({ id: s.id, state: "cached", file: prev.file });
      continue;
    }
    const icon = await fetchIcon(s.homepage);
    if (!icon) {
      index.logos[s.id] = { fetchedAt: new Date().toISOString(), error: "no usable icon" };
      results.push({ id: s.id, state: "failed" });
      continue;
    }
    const file = join(paths.logos, `${s.id}.${icon.ext}`);
    writeFileSync(file, icon.bytes);
    index.logos[s.id] = { file, source: icon.source, fetchedAt: new Date().toISOString() };
    results.push({ id: s.id, state: "fetched", file, source: icon.source });
  }
  writeFileAtomic(indexPath(), `${JSON.stringify(index, null, 2)}\n`);
  return results;
}
