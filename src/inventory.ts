// The full inventory: collect.ts's raw view plus the derived models (harness identity, services, budget).
// Each run is cached for `status`, which must answer without re-running the slow health checks.
import { rmSync } from "node:fs";
import { buildBudget } from "./budget";
import { collect } from "./collect";
import { paths } from "./config";
import { withIdentity } from "./harnesses";
import { loadManifest } from "./manifest";
import { cachedCost } from "./plugins";
import { buildServices } from "./services";
import { readJson, writeFileAtomic } from "./util";

export type FullInventory = ReturnType<typeof build>;

/** How to re-invoke this engine: the compiled binary itself, or `bun <script>` from source. */
export const selfCommand = () => (Bun.main.startsWith("/$bunfs") ? [process.execPath] : [process.execPath, Bun.main]);

export function fullInventory(opts: { repo?: string; persist?: boolean } = {}) {
  const persist = opts.persist ?? true;
  const lock = `${paths.inventoryCache}.lock`;
  if (persist) writeFileAtomic(lock, JSON.stringify({ pid: process.pid }));
  try {
    return build(persist, opts.repo);
  } finally {
    if (persist) rmSync(lock, { force: true });
  }
}

function build(persist: boolean, repo?: string) {
  const inv = collect();
  const { manifest } = loadManifest();
  const harnesses = withIdentity(inv.harnesses, persist);
  const services = buildServices(inv, manifest);
  const budget = buildBudget(inv, services, manifest, repo);
  const full = { ...inv, harnesses, services, budget };
  if (persist) {
    writeFileAtomic(paths.inventoryCache, JSON.stringify(full));
    fillCostsInBackground(inv.plugins.claude.filter((p) => p.enabled));
  }
  return full;
}

/** `claude plugin details` is slow, so uncached costs are filled by a detached child after we return. */
function fillCostsInBackground(plugins: { id: string; version?: string }[]) {
  if (process.env.ACTL_NO_BACKGROUND === "1") return;
  if (!plugins.some((p) => cachedCost(p.id, p.version) === undefined)) return;
  try {
    Bun.spawn([...selfCommand(), "plugin-costs", "refresh"], { stdio: ["ignore", "ignore", "ignore"], env: process.env }).unref();
  } catch {
    // best effort: values stay marked `estimated`
  }
}

export function readInventoryCache(): { data: FullInventory; at: Date } | undefined {
  const data = readJson<FullInventory>(paths.inventoryCache);
  return data ? { data, at: new Date(data.generatedAt) } : undefined;
}
