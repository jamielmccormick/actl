// actl: the actl engine as a CLI. The Mac app and agent sessions both call this; see docs/engine-contract.md.
// State commands print one JSON document: { schema, command, generatedAt, data }.
// apply, undo and login --json print JSON Lines events instead.
//
//   actl inventory [--repo=<path>]            full inventory, plus services, budget and harnesses; caches it
//   actl status                               menu-bar summary from the cache (fast; no CLIs, no network)
//   actl services [--cached]                  Service[]
//   actl budget [--repo=<path>] [--cached]    context budget and load preview
//   actl findings                             findings only
//   actl proxy                                CLIProxyAPI snapshot (masked; key stays in this process)
//   actl manifest adopt [--force] | show      write the manifest from current state / validate it
//   actl plan [--cached]                      manifest vs actual, as reviewable actions
//   actl apply <id[=choice]...> | --all       run named actions (JSONL)
//   actl undo <runId>                         reverse a run (JSONL)
//   actl activity [--limit=50]                recent runs
//   actl login <claude|codex> <server> [--json]
//   actl logos refresh [--force]              fetch service logos from their homepages (network)
//   actl plugin-costs refresh [--force]       cache `claude plugin details` always-on costs (slow)
//   actl skills plan|apply [--repo=<path>]    skills sync, as before
import { resolve } from "node:path";
import { loginTargets, loginWithEvents } from "./actions";
import { adopt } from "./adopt";
import { apply, readActivity, undo } from "./apply";
import { buildBudget } from "./budget";
import { cliproxy } from "./cliproxy";
import { collect } from "./collect";
import { expand, paths } from "./config";
import { fullInventory, readInventoryCache } from "./inventory";
import { refreshLogos } from "./logos";
import { loadManifest } from "./manifest";
import { buildPlan } from "./plan";
import { refreshCosts } from "./plugins";
import { applyPlan, planAll } from "./skills-sync";
import { buildStatus } from "./status";
import { writeFileAtomic } from "./util";

const SCHEMA = 2;
const argv = process.argv.slice(2);
const flags = argv.filter((a) => a.startsWith("--"));
const [command, ...args] = argv.filter((a) => !a.startsWith("--"));
const flag = (name: string) => flags.includes(`--${name}`);
const value = (name: string) => flags.find((f) => f.startsWith(`--${name}=`))?.slice(name.length + 3);
const repos = flags.filter((a) => a.startsWith("--repo=")).map((a) => resolve(expand(a.slice(7))));

function emit(data: unknown, sub?: string) {
  process.stdout.write(`${JSON.stringify({ schema: SCHEMA, command: [command, sub].filter(Boolean).join(" "), generatedAt: new Date().toISOString(), data })}\n`);
}
const line = (event: unknown) => process.stdout.write(`${JSON.stringify(event)}\n`);

function fail(message: string, code = 2): never {
  process.stderr.write(`actl: ${message}\n`);
  process.exit(code);
}

/** Fresh by default; `--cached` reuses the last inventory when there is one. */
const inventory = () => (flag("cached") && readInventoryCache()?.data) || fullInventory();

switch (command) {
  case "inventory":
    emit(fullInventory({ repo: repos[0] }));
    break;
  case "status":
    emit(buildStatus());
    break;
  case "services":
    emit(inventory().services);
    break;
  case "budget": {
    const inv = inventory();
    emit(repos[0] ? buildBudget(inv, inv.services, loadManifest().manifest, repos[0]) : inv.budget);
    break;
  }
  case "findings":
    emit(collect().findings);
    break;
  case "proxy": {
    const snap = await cliproxy(true);
    // `status` reads this instead of calling the proxy: status must stay fast and the management API is ban-prone.
    writeFileAtomic(paths.proxyCache, JSON.stringify(snap));
    emit(snap);
    break;
  }
  case "manifest": {
    const sub = args[0];
    if (sub === "show") {
      const m = loadManifest();
      emit({ path: m.path, exists: m.exists, manifest: m.manifest ?? null, errors: m.errors }, sub);
    } else if (sub === "adopt") {
      try {
        emit(adopt(inventory(), flag("force")), sub);
      } catch (e) {
        fail(String((e as Error).message ?? e));
      }
    } else fail("usage: actl manifest <adopt [--force]|show>");
    break;
  }
  case "plan":
    emit(buildPlan(inventory()).plan);
    break;
  case "apply": {
    if (!args.length && !flag("all")) fail("usage: actl apply <actionId[=choice]...> | --all");
    const choices: Record<string, string> = {};
    const ids = args.map((a) => {
      const [id, choice] = a.split("=");
      if (choice) choices[id] = choice;
      return id;
    });
    process.exitCode = apply(inventory(), ids, { all: flag("all"), choices }, line);
    break;
  }
  case "undo":
    if (!args[0]) fail("usage: actl undo <runId>");
    process.exitCode = undo(args[0], line);
    break;
  case "activity":
    emit(readActivity(Number(value("limit") ?? 50) || 50));
    break;
  case "login": {
    const [tool, name] = args;
    if ((tool !== "claude" && tool !== "codex") || !name) fail("usage: actl login <claude|codex> <server> [--json]");
    if (flag("json")) {
      // With a cached inventory, only known sign-in targets reach the CLI (as in the web dashboard).
      const cached = readInventoryCache()?.data;
      if (cached && !loginTargets(cached)[tool].has(name)) {
        line({ type: "done", harness: tool, server: name, ok: false, message: `${name} is not a sign-in target for ${tool}` });
        process.exit(1);
      }
      process.exitCode = await loginWithEvents(tool, name, line);
    } else {
      // Interactive: the CLI owns the OAuth flow and token storage; we only hand it the terminal.
      const proc = Bun.spawn([tool, "mcp", "login", name], { stdio: ["inherit", "inherit", "inherit"] });
      process.exit(await proc.exited);
    }
    break;
  }
  case "logos": {
    if (args[0] !== "refresh") fail("usage: actl logos refresh [--force]");
    emit(await refreshLogos(inventory().services, flag("force")), "refresh");
    break;
  }
  case "plugin-costs": {
    if (args[0] !== "refresh") fail("usage: actl plugin-costs refresh [--force]");
    const plugins = (readInventoryCache()?.data ?? collect()).plugins.claude.filter((p) => p.enabled);
    emit(refreshCosts(plugins, flag("force")), "refresh");
    break;
  }
  case "skills": {
    const sub = args[0];
    const { plans, skippedRepos } = planAll(repos);
    if (sub === "plan") emit({ plans, skippedRepos }, sub);
    else if (sub === "apply") emit({ applied: plans.map((p) => ({ scope: p.scope, log: applyPlan(p) })), skippedRepos }, sub);
    else fail("usage: actl skills <plan|apply> [--repo=<path>]");
    break;
  }
  default:
    fail(`unknown command${command ? ` "${command}"` : ""}. Commands: inventory, status, services, budget, findings, proxy, manifest, plan, apply, undo, activity, login, logos, plugin-costs, skills`);
}
