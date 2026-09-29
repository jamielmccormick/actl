// Apply and undo. Runs only actions named by id (or --all), backs up every file before it is written, and
// records each run so it can be undone: file edits are restored from backups, commands run their inverse.
import { appendFileSync, chmodSync, cpSync, existsSync, lstatSync, mkdirSync, rmSync } from "node:fs";
import { dirname, join } from "node:path";
import { maskEmail } from "./cliproxy";
import { claudeHome, claudeJsonPath, codexHome, paths, tilde } from "./config";
import type { FullInventory } from "./inventory";
import { buildPlan, type Planned, skillRepos, type Step } from "./plan";
import { applyPlan, MANIFEST_FILE, planAll, resolveConflict, type SyncPlan } from "./skills-sync";
import { readJson, readText, run, writeFileAtomic } from "./util";

export type ApplyEvent =
  | { type: "start"; runId: string; actions: string[] }
  | { type: "backup"; runId: string; files: string[]; dir: string }
  | { type: "step"; runId: string; actionId: string; state: "running" | "ok" | "failed" | "skipped"; message?: string }
  | { type: "done"; runId: string; ok: number; failed: number; tookMs: number }
  | { type: "error"; runId?: string; message: string };

export type ActivityEntry = {
  runId: string;
  at: string;
  source: "user" | "watch" | "auto";
  actions: { id: string; title: string; state: "ok" | "failed" | "skipped" }[];
  undoable: boolean;
  undoneAt?: string;
  undoOf?: string;
};

type UndoStep = { type: "cmd"; argv: string[] } | { type: "restore"; path: string };
type BackupRec = { path: string; existed: boolean; stored?: string; restorable: boolean };
type RunRecord = { runId: string; at: string; actions: { id: string; title: string; state: "ok" | "failed" | "skipped"; undo: UndoStep[]; reversible: boolean }[]; backups: BackupRec[] };

const newRunId = () => `${new Date().toISOString().replace(/[-:]/g, "").replace(/\.\d+Z$/, "").replace("T", "-")}-${crypto.randomUUID().slice(0, 4)}`;
const clip = (s: string) => maskEmail(s.trim().split("\n").filter(Boolean).slice(-2).join(" ")).slice(0, 300);

class Backups {
  recs: BackupRec[] = [];
  constructor(readonly dir: string) {}
  save(path: string, restorable = true) {
    const prev = this.recs.find((r) => r.path === path);
    if (prev) {
      prev.restorable ||= restorable;
      return;
    }
    let existed = false;
    try {
      lstatSync(path);
      existed = true;
    } catch {}
    const rec: BackupRec = { path, existed, restorable };
    if (existed) {
      rec.stored = join(this.dir, "files", String(this.recs.length));
      mkdirSync(dirname(rec.stored), { recursive: true });
      cpSync(path, rec.stored, { recursive: true, verbatimSymlinks: true });
    }
    this.recs.push(rec);
  }
}

function restore(rec: BackupRec) {
  rmSync(rec.path, { recursive: true, force: true });
  if (rec.existed && rec.stored) {
    mkdirSync(dirname(rec.path), { recursive: true });
    cpSync(rec.stored, rec.path, { recursive: true, verbatimSymlinks: true });
  }
}

// Config files the harness CLIs rewrite. Kept as reference copies for manual recovery; undo uses inverse
// commands instead, because restoring a whole ~/.claude.json would discard unrelated changes made since.
const cliFiles = (argv: string[]) =>
  argv[0] === "claude" ? [claudeJsonPath, claudeHome("settings.json"), claudeHome("plugins", "installed_plugins.json")] : argv[0] === "codex" ? [codexHome("config.toml")] : [];

function syncPlanFor(scope: string, inv: FullInventory): SyncPlan | undefined {
  return planAll(skillRepos(inv)).plans.find((p) => p.scope === scope);
}

/** Paths a skills step writes, so they can be backed up first. */
function skillTouches(step: Step, inv: FullInventory, choice?: string): string[] {
  if (step.type !== "skills-sync" && step.type !== "skills-resolve") return [];
  const plan = syncPlanFor(step.scope, inv);
  if (!plan) return [];
  const manifest = join(plan.targetRoot, MANIFEST_FILE);
  if (step.type === "skills-resolve") {
    const a = plan.actions.find((x) => x.kind === "conflict" && x.name === step.name);
    if (!a || a.kind !== "conflict") return [];
    return [choice === "keep-edit" && a.source ? a.source : a.target, manifest];
  }
  return [...plan.actions.filter((a) => a.kind !== "conflict" && a.kind !== "adopt").map((a) => a.target), manifest];
}

function runStep(step: Step, inv: FullInventory, choice?: string): { ok: boolean; message: string; undo: UndoStep[] } {
  switch (step.type) {
    case "cmd": {
      const r = run(step.argv, undefined, 300_000);
      return { ok: r.ok, message: clip(r.out) || (r.ok ? "done" : `exit ${r.code}`), undo: step.inverse ? [{ type: "cmd", argv: step.inverse }] : [] };
    }
    case "write":
      writeFileAtomic(step.path, step.content);
      return { ok: true, message: `wrote ${tilde(step.path)}`, undo: [{ type: "restore", path: step.path }] };
    case "skills-sync": {
      const plan = syncPlanFor(step.scope, inv);
      if (!plan) return { ok: false, message: `no skills plan for ${step.scope}`, undo: [] };
      const touched = skillTouches(step, inv);
      mkdirSync(plan.targetRoot, { recursive: true });
      const log = applyPlan({ ...plan, actions: plan.actions.filter((a) => a.kind !== "conflict") });
      return { ok: true, message: log.join("; ").slice(0, 300), undo: touched.map((path) => ({ type: "restore", path })) };
    }
    case "skills-resolve": {
      const plan = syncPlanFor(step.scope, inv);
      if (!plan || (choice !== "use-canonical" && choice !== "keep-edit")) return { ok: false, message: "needs a choice: use-canonical or keep-edit", undo: [] };
      const touched = skillTouches(step, inv, choice);
      return { ok: true, message: resolveConflict(plan, step.name, choice), undo: touched.map((path) => ({ type: "restore", path })) };
    }
  }
}

function runUndo(steps: UndoStep[], backups: BackupRec[]): { ok: boolean; message: string } {
  const messages: string[] = [];
  for (const u of steps) {
    if (u.type === "cmd") {
      const r = run(u.argv, undefined, 300_000);
      messages.push(clip(r.out));
      if (!r.ok) return { ok: false, message: messages.filter(Boolean).join("; ") || `${u.argv.slice(0, 3).join(" ")} failed` };
    } else {
      const rec = backups.find((b) => b.path === u.path);
      if (!rec) return { ok: false, message: `no backup of ${tilde(u.path)}` };
      restore(rec);
      messages.push(`restored ${tilde(u.path)}`);
    }
  }
  return { ok: true, message: messages.filter(Boolean).join("; ").slice(0, 300) };
}

function record(runDir: string, rec: RunRecord, entry: ActivityEntry) {
  writeFileAtomic(join(runDir, "run.json"), `${JSON.stringify(rec, null, 2)}\n`);
  mkdirSync(dirname(paths.activity), { recursive: true });
  appendFileSync(paths.activity, `${JSON.stringify(entry)}\n`);
}

export function apply(inv: FullInventory, ids: string[], opts: { all?: boolean; choices?: Record<string, string> }, emit: (e: ApplyEvent) => void) {
  const started = Date.now();
  const runId = newRunId();
  const { planned } = buildPlan(inv);
  const selected: (Planned | { id: string; missing: true })[] = opts.all ? planned.filter((a) => a.defaultSelected) : ids.map((id) => planned.find((a) => a.id === id) ?? { id, missing: true as const });
  if (!selected.length) {
    emit({ type: "error", runId, message: opts.all ? "nothing to apply: the plan has no default actions" : "name at least one action id, or pass --all" });
    return 1;
  }
  emit({ type: "start", runId, actions: selected.map((a) => a.id) });

  const runDir = join(paths.backups, runId);
  mkdirSync(runDir, { recursive: true });
  chmodSync(paths.backups, 0o700);
  const backups = new Backups(runDir);
  for (const a of selected) {
    if ("missing" in a) continue;
    for (const s of a.steps) {
      if (s.type === "write") backups.save(s.path);
      if (s.type === "cmd") cliFiles(s.argv).forEach((f) => existsSync(f) && backups.save(f, false));
      skillTouches(s, inv, opts.choices?.[a.id]).forEach((p) => backups.save(p));
    }
  }
  if (backups.recs.length) emit({ type: "backup", runId, files: backups.recs.map((r) => tilde(r.path)), dir: tilde(runDir) });

  const rec: RunRecord = { runId, at: new Date().toISOString(), actions: [], backups: backups.recs };
  let ok = 0;
  let failed = 0;
  for (const a of selected) {
    if ("missing" in a) {
      emit({ type: "step", runId, actionId: a.id, state: "skipped", message: "not in the current plan (already applied, or the state changed)" });
      rec.actions.push({ id: a.id, title: a.id, state: "skipped", undo: [], reversible: false });
      continue;
    }
    const choice = opts.choices?.[a.id];
    if (a.requiresChoice && !a.requiresChoice.options.some((o) => o.id === choice)) {
      emit({ type: "step", runId, actionId: a.id, state: "skipped", message: `needs a choice: ${a.requiresChoice.options.map((o) => `${a.id}=${o.id}`).join(" or ")}` });
      rec.actions.push({ id: a.id, title: a.title, state: "skipped", undo: [], reversible: false });
      continue;
    }
    emit({ type: "step", runId, actionId: a.id, state: "running" });
    const undo: UndoStep[] = [];
    let result = { ok: true, message: "" };
    for (const step of a.steps) {
      try {
        const r = runStep(step, inv, choice);
        if (r.ok) undo.unshift(...[...r.undo].reverse());
        result = { ok: r.ok, message: r.message };
      } catch (e) {
        result = { ok: false, message: clip(String((e as Error).message ?? e)) };
      }
      if (!result.ok) break;
    }
    if (!result.ok && undo.length) {
      // Don't leave an action half done (e.g. a plugin disabled but its server never added).
      const back = runUndo(undo, backups.recs);
      result.message = `${result.message}; rolled back${back.ok ? "" : ` (rollback failed: ${back.message})`}`;
    }
    result.ok ? ok++ : failed++;
    emit({ type: "step", runId, actionId: a.id, state: result.ok ? "ok" : "failed", message: result.message || undefined });
    rec.actions.push({ id: a.id, title: a.title, state: result.ok ? "ok" : "failed", undo: result.ok ? undo : [], reversible: a.reversible });
  }
  const undoable = rec.actions.some((x) => x.state === "ok" && x.reversible);
  record(runDir, rec, { runId, at: rec.at, source: "user", actions: rec.actions.map(({ id, title, state }) => ({ id, title, state })), undoable });
  emit({ type: "done", runId, ok, failed, tookMs: Date.now() - started });
  return failed ? 1 : 0;
}

export function readActivity(limit = 50): ActivityEntry[] {
  const lines = (readText(paths.activity) ?? "").split("\n").filter(Boolean);
  const entries = lines.flatMap((l) => {
    try {
      return [JSON.parse(l) as ActivityEntry];
    } catch {
      return [];
    }
  });
  for (const e of entries)
    if (e.undoOf) {
      const orig = entries.find((x) => x.runId === e.undoOf);
      if (orig) {
        orig.undoneAt = e.at;
        orig.undoable = false;
      }
    }
  return entries.reverse().slice(0, limit);
}

export function undo(runId: string, emit: (e: ApplyEvent) => void) {
  const started = Date.now();
  if (!/^[\w-]+$/.test(runId)) {
    emit({ type: "error", message: `not a run id: ${runId}` });
    return 2;
  }
  const rec = readJson<RunRecord>(join(paths.backups, runId, "run.json"));
  const entry = readActivity(10_000).find((e) => e.runId === runId);
  if (!rec) {
    emit({ type: "error", message: `no record of run ${runId}` });
    return 2;
  }
  if (entry?.undoneAt || entry?.undoOf) {
    emit({ type: "error", runId, message: entry.undoOf ? "an undo run can't be undone; apply the plan again instead" : `run ${runId} was already undone at ${entry.undoneAt}` });
    return 2;
  }
  const newId = newRunId();
  const targets = rec.actions.filter((a) => a.state === "ok").reverse();
  emit({ type: "start", runId: newId, actions: targets.map((a) => a.id) });
  let ok = 0;
  let failed = 0;
  const results: ActivityEntry["actions"] = [];
  for (const a of targets) {
    if (!a.reversible || !a.undo.length) {
      emit({ type: "step", runId: newId, actionId: a.id, state: "skipped", message: "not reversible" });
      results.push({ id: a.id, title: `Undo: ${a.title}`, state: "skipped" });
      continue;
    }
    emit({ type: "step", runId: newId, actionId: a.id, state: "running" });
    const r = runUndo(a.undo, rec.backups);
    r.ok ? ok++ : failed++;
    emit({ type: "step", runId: newId, actionId: a.id, state: r.ok ? "ok" : "failed", message: r.message || undefined });
    results.push({ id: a.id, title: `Undo: ${a.title}`, state: r.ok ? "ok" : "failed" });
  }
  const runDir = join(paths.backups, newId);
  mkdirSync(runDir, { recursive: true });
  record(runDir, { runId: newId, at: new Date().toISOString(), actions: [], backups: [] }, { runId: newId, at: new Date().toISOString(), source: "user", actions: results, undoable: false, undoOf: runId });
  emit({ type: "done", runId: newId, ok, failed, tookMs: Date.now() - started });
  return failed ? 1 : 0;
}
