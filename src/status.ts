// The menu-bar summary. Must answer in well under a second: it reads the cached inventory and proxy
// snapshot plus a few cheap file checks, and never runs a harness CLI or touches the network.
import { existsSync, readFileSync } from "node:fs";
import { claudeHome, codexHome, expand, paths } from "./config";
import { claudeInstructionMode } from "./budget";
import { type FullInventory, readInventoryCache } from "./inventory";
import { loadManifest } from "./manifest";
import type { HarnessId } from "./plan";
import { hasPathsFrontmatter, readJson } from "./util";

export type AttentionItem = {
  id: string;
  severity: "error" | "warn" | "info";
  kind: "sign-in" | "failed" | "drift" | "sync" | "update" | "gap" | "quota";
  title: string;
  detail?: string;
  harness?: HarnessId;
  fix?: { label: string; actionIds?: string[]; signIn?: { harness: HarnessId; servers: string[] } };
};
export type Status = {
  level: "healthy" | "attention" | "error" | "syncing";
  harnesses: { id: HarnessId; name: string; connected: number; total: number; needsSignIn: number; failed: number }[];
  attention: AttentionItem[];
  proxy?: { accounts: { label: string; state: "active" | "cooldown" | "disabled" | "error"; retryAt?: string }[] };
  checkedAt: string;
  stale: boolean;
};

export const STALE_MS = 30 * 60_000;

export function versionNewer(latest?: string, installed?: string): boolean {
  if (!latest || !installed) return false;
  const parts = (v: string) => v.replace(/^v/, "").split(/[.+-]/).map((x) => Number.parseInt(x, 10) || 0);
  const [a, b] = [parts(latest), parts(installed)];
  for (let i = 0; i < Math.max(a.length, b.length); i++) if ((a[i] ?? 0) !== (b[i] ?? 0)) return (a[i] ?? 0) > (b[i] ?? 0);
  return false;
}

export function proxyAccounts(snapshot: any): NonNullable<Status["proxy"]>["accounts"] {
  const now = Date.now();
  return (snapshot?.accounts ?? []).map((a: any, i: number) => {
    const retry = a.nextRetryAfter && Date.parse(a.nextRetryAfter) > now ? a.nextRetryAfter : undefined;
    const state = a.disabled ? "disabled" : a.unavailable || retry ? "cooldown" : /error|invalid|expired/i.test(`${a.status ?? ""}`) ? "error" : "active";
    return { label: a.label ?? a.email ?? `${a.provider ?? "account"} ${a.ref ?? i + 1}`, state, retryAt: retry };
  });
}

const refreshing = () => {
  const pid = Number(readJson<{ pid: number }>(`${paths.inventoryCache}.lock`)?.pid);
  if (!pid) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
};

function harnessCounts(inv: FullInventory | undefined) {
  const list = inv?.harnesses.filter((h) => h.supported && h.installed) ?? [
    ...(existsSync(claudeHome()) ? [{ id: "claude", name: "Claude Code" }] : []),
    ...(existsSync(codexHome()) ? [{ id: "codex", name: "Codex" }] : []),
  ];
  return list.map((h) => {
    const providers = (inv?.services ?? []).map((s) => s.providers[h.id]).filter((p) => p && p.health !== "absent");
    return {
      id: h.id,
      name: h.name,
      connected: providers.filter((p) => p!.health === "connected").length,
      total: providers.length,
      needsSignIn: providers.filter((p) => p!.health === "needs-auth").length,
      failed: providers.filter((p) => p!.health === "failed").length,
    };
  });
}

export function buildStatus(): Status {
  const cache = readInventoryCache();
  const inv = cache?.data;
  const attention: AttentionItem[] = [];
  const names: Record<string, string> = Object.fromEntries((inv?.harnesses ?? []).map((h) => [h.id, h.name]));
  const nameOf = (h: string) => names[h] ?? h;

  if (!inv)
    attention.push({ id: "inventory.missing", severity: "info", kind: "sync", title: "No inventory yet", detail: "Run a full refresh (actl inventory) to check every harness.", fix: { label: "Refresh" } });

  for (const h of ["claude", "codex"]) {
    const needs = (inv?.services ?? []).flatMap((s) => {
      const p = s.providers[h];
      return p && p.health === "needs-auth" ? [{ s, p }] : [];
    });
    if (!needs.length) continue;
    const servers = needs.filter((n) => n.p.canSignIn && n.p.serverName).map((n) => n.p.serverName!);
    attention.push({
      id: `sign-in:${h}`,
      severity: "warn",
      kind: "sign-in",
      harness: h,
      title: `${needs.length} ${needs.length === 1 ? "service needs" : "services need"} sign-in in ${nameOf(h)}`,
      detail: needs.map((n) => n.s.name).join(", "),
      fix: servers.length ? { label: "Sign in", signIn: { harness: h, servers } } : undefined,
    });
  }
  for (const s of inv?.services ?? [])
    for (const [h, p] of Object.entries(s.providers)) {
      if (p?.health !== "failed") continue;
      attention.push({
        id: `failed:${h}:${s.id}`,
        severity: "error",
        kind: "failed",
        harness: h,
        title: `${s.name} failed to connect in ${nameOf(h)}`,
        detail: p.detail,
        fix: p.canSignIn && p.serverName ? { label: "Sign in again", signIn: { harness: h, servers: [p.serverName] } } : undefined,
      });
    }

  // Live checks: these are the reverts an update can cause between two inventories.
  const { manifest } = loadManifest();
  for (const [id, r] of Object.entries(manifest?.policy?.rules ?? {})) {
    const file = expand(r.file);
    if (existsSync(file) && !hasPathsFrontmatter(readFileSync(file, "utf8")))
      attention.push({ id: `drift:rule:${id}`, severity: "warn", kind: "drift", harness: "claude", title: `The ${id} rule is always-on again`, detail: `${r.file} lost its paths: frontmatter, usually after a tool update.`, fix: { label: "Re-scope", actionIds: [`rule.rescope:claude:${id}`] } });
  }
  const mode = manifest?.policy?.claude?.instruction_files;
  if (mode && mode !== claudeInstructionMode())
    attention.push({ id: "drift:instructions-mode", severity: "warn", kind: "drift", harness: "claude", title: "Claude's instruction-file mode changed", detail: `The manifest says ${mode}; settings say ${claudeInstructionMode()}.`, fix: { label: "Restore", actionIds: ["instructions.mode:claude"] } });

  for (const f of inv?.findings ?? []) {
    if (f.area === "skills" && f.title.includes("not yet synced"))
      attention.push({ id: "sync:skills", severity: "warn", kind: "sync", title: f.title, detail: f.detail, fix: { label: "Sync skills", actionIds: ["skills.sync:user"] } });
    if (f.area === "skills" && f.title.includes("edited in place"))
      attention.push({ id: "sync:skill-conflicts", severity: "error", kind: "sync", title: f.title, detail: "Choose which copy to keep in Review changes." });
    // The live rule check above supersedes the cached finding for the same rule.
    const coveredLive = attention.some((a) => a.id.startsWith("drift:rule:") && f.title.includes("in Claude") && f.title.toLowerCase().includes(a.id.slice(11)));
    if (f.area === "instructions" && f.title.includes("always-on again") && !coveredLive)
      attention.push({ id: `drift:${f.title.toLowerCase().replace(/[^a-z]+/g, "-")}`, severity: "warn", kind: "drift", title: f.title, detail: f.detail });
  }

  const lonely = (inv?.services ?? []).filter((s) => s.parity === "only-claude" || s.parity === "only-codex");
  if (lonely.length)
    attention.push({ id: "gap:services", severity: "info", kind: "gap", title: `${lonely.length} ${lonely.length === 1 ? "service is" : "services are"} in only one harness`, detail: lonely.map((s) => s.name).join(", ") });

  const proxySnap = readJson(paths.proxyCache);
  const accounts = proxySnap?.listening ? proxyAccounts(proxySnap) : undefined;
  for (const a of accounts ?? [])
    if (a.state === "cooldown" || a.state === "error")
      attention.push({ id: `quota:${a.label}`, severity: a.state === "error" ? "error" : "warn", kind: "quota", harness: "proxy", title: `Proxy account ${a.label} is ${a.state === "cooldown" ? "cooling down" : "failing"}`, detail: a.retryAt ? `Retries after ${a.retryAt}` : undefined });
  if (versionNewer(proxySnap?.latestVersion, proxySnap?.installedVersion))
    attention.push({ id: "update:proxy", severity: "info", kind: "update", harness: "proxy", title: `CLIProxyAPI ${proxySnap.latestVersion} is available`, detail: `Installed: ${proxySnap.installedVersion}`, fix: { label: "Update", actionIds: ["proxy.update"] } });

  const order = { error: 0, warn: 1, info: 2 };
  attention.sort((a, b) => order[a.severity] - order[b.severity]);
  const checkedAt = inv?.generatedAt ?? new Date().toISOString();
  const stale = !inv || Date.now() - Date.parse(checkedAt) > STALE_MS;
  const level = attention.some((a) => a.severity === "error") ? "error" : attention.some((a) => a.severity === "warn") ? "attention" : refreshing() ? "syncing" : "healthy";
  return { level, harnesses: harnessCounts(inv), attention, proxy: accounts ? { accounts } : undefined, checkedAt, stale };
}
