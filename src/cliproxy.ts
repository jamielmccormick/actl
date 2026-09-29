// Read-only view of a local CLIProxyAPI management API (optional integration; see [proxy] in config.ts).
//
// Safety rules (see README):
// - The management key is read server-side only and never leaves this module: not in
//   responses, logs, URLs or error messages.
// - Only an allowlist of GET endpoints is called. Nothing here writes, downloads credentials,
//   pops the usage queue, or reads log bodies.
// - Five failed auths ban the client IP for ~30 minutes, and other local clients share that IP.
//   Any 401/403 trips a circuit breaker that stops all authenticated calls until restart.
//   Nothing is retried automatically.
// - Output objects are built from explicitly picked fields; emails are masked and key
//   material is dropped.
import { readFileSync } from "node:fs";
import { config as settings } from "./config";

const ORIGIN = settings.proxy.endpoint.replace(/\/+$/, "");
const API = `${ORIGIN}/v8/management`;
const KEY_FILE = settings.proxy.keyFile;
const TIMEOUT_MS = 5_000;
const CACHE_MS = 45_000;
const LATEST_CACHE_MS = 6 * 60 * 60_000;
const BREW_CACHE_MS = 60 * 60_000;

// The only management paths this module may request (all GET).
const ALLOWED = new Set(["/config", "/credentials", "/observability/usage/api-keys", "/observability/logs/errors", "/server/latest-version"]);

// ---------- sanitizing helpers ----------

const EMAIL_RE = /([A-Za-z0-9._%+-])[A-Za-z0-9._%+-]*@([A-Za-z0-9.-]+\.[A-Za-z]{2,})/g;
const SECRETISH_RE = /\b(Bearer\s+\S+|sk-[A-Za-z0-9_-]{8,}|ey[A-Za-z0-9_-]{20,}\.[A-Za-z0-9._-]+|[A-Za-z0-9_-]{40,})/g;

export function maskEmail(s: string): string {
  return s.replace(EMAIL_RE, (_m, first: string, domain: string) => `${first}***@${domain}`);
}
/** Mask emails and anything that looks like a token; clamp length. */
function scrub(v: unknown, max = 240): string | undefined {
  if (typeof v !== "string") return undefined;
  const t = maskEmail(v).replace(SECRETISH_RE, "[redacted]").trim();
  if (!t) return undefined;
  return t.length > max ? `${t.slice(0, max)}…` : t;
}
const bool = (v: unknown) => (typeof v === "boolean" ? v : undefined);
const num = (v: unknown) => (typeof v === "number" && Number.isFinite(v) ? v : undefined);
const shortStr = (v: unknown) => (typeof v === "string" && v.length <= 80 ? scrub(v, 80) : undefined);
const iso = (v: unknown) => (typeof v === "string" && !Number.isNaN(Date.parse(v)) ? new Date(v).toISOString() : undefined);
const get = (o: any, path: string) => path.split(".").reduce((a, k) => (a && typeof a === "object" ? a[k] : undefined), o);
const first = <T>(...vals: (T | undefined)[]) => vals.find((v) => v !== undefined);

type Bucket = { time?: string; success: number; failed: number };
function buckets(v: unknown): Bucket[] {
  if (!Array.isArray(v)) return [];
  return v.slice(-20).map((b) => ({ time: iso(b?.time) ?? shortStr(b?.time), success: num(b?.success) ?? 0, failed: num(b?.failed) ?? 0 }));
}

// ---------- transport ----------

type CallResult = { ok: true; status: number; json: any; version?: string } | { ok: false; reason: string; status?: number };

let authBlocked: { status: number; at: string; endpoint: string } | undefined;

function readKey(): string | undefined {
  const env = process.env.ACTL_CLIPROXY_KEY?.trim();
  if (env) return env;
  try {
    return readFileSync(KEY_FILE, "utf8").trim() || undefined;
  } catch {
    return undefined;
  }
}

function failureReason(e: unknown): string {
  // Never echo raw error text: map to a fixed vocabulary.
  const name = (e as any)?.name;
  const code = String((e as any)?.code ?? "");
  if (name === "TimeoutError" || name === "AbortError") return "timeout";
  if (code.includes("ECONNREFUSED") || code === "ConnectionRefused") return "connection refused";
  return "request failed";
}

async function call(path: string): Promise<CallResult> {
  if (!ALLOWED.has(path)) return { ok: false, reason: "endpoint not allowlisted" };
  if (authBlocked) return { ok: false, reason: "auth circuit breaker open" };
  const key = readKey();
  if (!key) return { ok: false, reason: "management key not found" };
  let res: Response;
  try {
    res = await fetch(API + path, {
      method: "GET",
      headers: { Authorization: `Bearer ${key}`, Accept: "application/json" },
      signal: AbortSignal.timeout(TIMEOUT_MS),
      redirect: "manual",
    });
  } catch (e) {
    return { ok: false, reason: failureReason(e) };
  }
  const version = res.headers.get("x-cpa-version") ?? undefined;
  if (res.status === 401 || res.status === 403) {
    authBlocked = { status: res.status, at: new Date().toISOString(), endpoint: path };
    await res.body?.cancel();
    return { ok: false, status: res.status, reason: `HTTP ${res.status} (auth rejected; further calls disabled until actl restarts)` };
  }
  if (!res.ok) {
    await res.body?.cancel();
    return { ok: false, status: res.status, reason: `HTTP ${res.status}` };
  }
  try {
    return { ok: true, status: res.status, json: await res.json(), version };
  } catch {
    return { ok: false, status: res.status, reason: "invalid JSON" };
  }
}

/** Unauthenticated liveness probe; does not count toward the auth-failure ban. */
async function listening(): Promise<boolean> {
  try {
    const res = await fetch(`${ORIGIN}/`, { signal: AbortSignal.timeout(2_000), redirect: "manual" });
    await res.body?.cancel();
    return true;
  } catch {
    return false;
  }
}

let brewCache: { at: number; version?: string } | undefined;
async function brewVersion(): Promise<string | undefined> {
  if (brewCache && Date.now() - brewCache.at < BREW_CACHE_MS) return brewCache.version;
  let version: string | undefined;
  try {
    const p = Bun.spawn(["brew", "info", "--json=v2", "cliproxyapi"], { stdout: "pipe", stderr: "ignore", env: { ...process.env, HOMEBREW_NO_AUTO_UPDATE: "1" } });
    const timer = setTimeout(() => p.kill(), 15_000);
    const out = await new Response(p.stdout).text();
    clearTimeout(timer);
    const f = JSON.parse(out)?.formulae?.[0];
    version = shortStr(f?.installed?.[0]?.version);
  } catch {
    version = undefined;
  }
  brewCache = { at: Date.now(), version };
  return version;
}

let latestCache: { at: number; version?: string } | undefined;

// ---------- shaping ----------

function pickConfig(c: any) {
  // v8 layout first, legacy flat names as fallback.
  return {
    host: shortStr(first(get(c, "server.host"), c?.host)),
    port: num(first(get(c, "server.port"), c?.port)),
    routingStrategy: shortStr(first(get(c, "routing.strategy"), get(c, "routing-strategy"))),
    sessionAffinity: bool(get(c, "routing.session-affinity")),
    sessionAffinitySubagents: bool(get(c, "routing.session-affinity-subagents")),
    sessionAffinityTtl: shortStr(get(c, "routing.session-affinity-ttl")),
    requestRetry: num(first(get(c, "routing.retry.request-retry"), c?.["request-retry"])),
    quotaExceeded: {
      switchProject: bool(get(c, "quota-exceeded.switch-project")),
      switchPreviewModel: bool(get(c, "quota-exceeded.switch-preview-model")),
    },
    logging: {
      debug: bool(first(get(c, "observability.logs.debug"), c?.debug)),
      toFile: bool(first(get(c, "observability.logs.logging-to-file"), c?.["logging-to-file"])),
      requestLog: bool(first(get(c, "observability.logs.request-log"), c?.["request-log"])),
    },
    allowRemote: bool(first(get(c, "management.allow-remote"), get(c, "remote-management.allow-remote"))),
    disableControlPanel: bool(first(get(c, "management.disable-control-panel"), get(c, "remote-management.disable-control-panel"))),
    usageStatisticsEnabled: bool(first(get(c, "observability.usage.enabled"), get(c, "observability.usage-statistics-enabled"), c?.["usage-statistics-enabled"])),
  };
}

/** Upstream errors arrive as raw JSON strings; reduce them to "type: message". */
function statusSummary(v: unknown): string | undefined {
  if (typeof v !== "string") return undefined;
  try {
    const j = JSON.parse(v);
    const e = j?.error ?? j;
    const parts = [shortStr(e?.type), scrub(e?.message, 160)].filter(Boolean);
    if (parts.length) return parts.join(": ");
  } catch {
    // not JSON
  }
  return scrub(v);
}

function pickAccount(a: any) {
  const idx = a?.auth_index;
  return {
    // auth_index is an opaque index; id/name are file names that embed the full email, so they are not used.
    ref: typeof idx === "string" || typeof idx === "number" ? String(idx).slice(0, 40) : undefined,
    provider: shortStr(a?.provider) ?? shortStr(a?.type),
    email: typeof a?.email === "string" ? maskEmail(a.email) : undefined,
    label: scrub(a?.label, 80),
    accountType: shortStr(a?.account_type),
    account: scrub(a?.account, 80),
    status: shortStr(a?.status),
    statusMessage: statusSummary(a?.status_message),
    disabled: bool(a?.disabled) ?? false,
    unavailable: bool(a?.unavailable) ?? false,
    runtimeOnly: bool(a?.runtime_only) ?? false,
    source: shortStr(a?.source),
    lastRefresh: iso(a?.last_refresh),
    nextRetryAfter: iso(a?.next_retry_after),
    updatedAt: iso(a?.updated_at),
    success: num(a?.success) ?? 0,
    failed: num(a?.failed) ?? 0,
    recent: buckets(a?.recent_requests),
  };
}

function pickApiKeyUsage(j: any) {
  // Shape: { [provider]: { "base_url|api_key": { success, failed, recent_requests } } }.
  // The map key contains the raw API key, so it is replaced by an ordinal and the base URL host.
  const out: { provider: string; label: string; success: number; failed: number; recent: Bucket[] }[] = [];
  if (!j || typeof j !== "object" || Array.isArray(j)) return out;
  for (const [provider, keys] of Object.entries(j)) {
    if (!keys || typeof keys !== "object") continue;
    let n = 0;
    for (const [composite, e] of Object.entries(keys as Record<string, any>)) {
      n++;
      const base = composite.split("|")[0] ?? "";
      let host = "default endpoint";
      try {
        if (base) host = new URL(base).host;
      } catch {
        host = "custom endpoint";
      }
      out.push({ provider: shortStr(provider) ?? "unknown", label: `key ${n} · ${host}`, success: num(e?.success) ?? 0, failed: num(e?.failed) ?? 0, recent: buckets(e?.recent_requests) });
    }
  }
  return out;
}

function pickErrorLogs(j: any) {
  const files = Array.isArray(j?.files) ? j.files : [];
  return files.slice(0, 50).map((f: any) => ({
    name: scrub(f?.name, 120),
    size: num(f?.size) ?? 0,
    modified: num(f?.modified) ? new Date(f.modified * 1000).toISOString() : undefined,
  }));
}

// ---------- snapshot ----------

async function snapshot() {
  const started = Date.now();
  const errors: Record<string, string> = {};
  // Disabled in config: report it as not running without touching the network.
  const up = settings.proxy.enabled === false ? false : await listening();
  const base = {
    generatedAt: new Date().toISOString(),
    endpoint: ORIGIN.replace(/^https?:\/\//, ""),
    listening: up,
    keyConfigured: !!readKey(),
    authBlocked: authBlocked ? { ...authBlocked } : undefined,
  };
  if (!up) {
    const installed = await brewVersion();
    return { ...base, installedVersion: installed, versionSource: installed ? "brew" : undefined, latestVersion: latestCache?.version, errors, tookMs: Date.now() - started };
  }

  // Sequential on purpose: if the first call is rejected, the breaker stops the rest.
  let headerVersion: string | undefined;
  const run = async <T>(path: string, pick: (j: any) => T): Promise<T | undefined> => {
    const r = await call(path);
    if (!r.ok) {
      errors[path] = r.reason;
      return undefined;
    }
    headerVersion ??= shortStr(r.version);
    return pick(r.json);
  };

  const config = await run("/config", pickConfig);
  const accounts = await run("/credentials", (j) => (Array.isArray(j?.files) ? j.files : Array.isArray(j) ? j : []).map(pickAccount));
  const apiKeyUsage = await run("/observability/usage/api-keys", pickApiKeyUsage);
  const errorLogs = await run("/observability/logs/errors", pickErrorLogs);

  if (!latestCache || Date.now() - latestCache.at > LATEST_CACHE_MS) {
    const v = await run("/server/latest-version", (j) => shortStr(j?.["latest-version"]));
    // Cache failures too (with the previous value) so GitHub is not hit on every refresh.
    latestCache = { at: Date.now(), version: v ?? latestCache?.version };
  }

  const installed = headerVersion ?? (await brewVersion());
  return {
    ...base,
    authBlocked: authBlocked ? { ...authBlocked } : undefined,
    installedVersion: installed,
    versionSource: headerVersion ? "X-CPA-VERSION header" : installed ? "brew" : undefined,
    latestVersion: latestCache.version,
    config,
    accounts,
    apiKeyUsage,
    errorLogs,
    errors,
    tookMs: Date.now() - started,
  };
}

export type CliproxySnapshot = Awaited<ReturnType<typeof snapshot>>;

let cache: { at: number; data: CliproxySnapshot } | undefined;
let inflight: Promise<CliproxySnapshot> | undefined;

/** Cached for 45s. `refresh` bypasses the cache but never more often than every 10s. */
export async function cliproxy(refresh = false): Promise<CliproxySnapshot> {
  const age = cache ? Date.now() - cache.at : Infinity;
  if (cache && (age < (refresh ? 10_000 : CACHE_MS))) return cache.data;
  inflight ??= snapshot()
    .then((data) => {
      cache = { at: Date.now(), data };
      return data;
    })
    .finally(() => (inflight = undefined));
  return inflight;
}
