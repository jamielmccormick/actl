// The only write actions actl exposes: start an MCP OAuth sign-in through the owning CLI.
// The CLI opens the browser and stores the token itself; nothing secret passes through here.
import { homedir } from "node:os";

export type Tool = "claude" | "codex";
export type LoginJob = {
  id: string;
  tool: Tool;
  name: string;
  status: "running" | "succeeded" | "failed" | "timed-out";
  startedAt: string;
  endedAt?: string;
  exitCode?: number;
};

const TIMEOUT_MS = 5 * 60_000;
const jobs = new Map<string, LoginJob>();

/** Server names that may be signed in, taken from the latest inventory so arbitrary input never reaches a CLI. */
export function loginTargets(inventory: any): Record<Tool, Set<string>> {
  const claude = new Set<string>();
  const codex = new Set<string>();
  for (const row of inventory?.mcp?.rows ?? []) {
    if (row.claude?.serverName && ["needs-auth", "connected", "failed"].includes(row.claude.status) && row.claude.scope !== "claude.ai") claude.add(row.claude.serverName);
    if (row.codex?.serverName && (row.codex.auth === "o_auth" || row.codex.auth === "not_logged_in")) codex.add(row.codex.serverName);
  }
  return { claude, codex };
}

export function startLogin(tool: Tool, name: string, allowed: Record<Tool, Set<string>>): LoginJob | { error: string } {
  if (!allowed[tool]?.has(name)) return { error: `${name} is not a sign-in target for ${tool}` };
  const running = [...jobs.values()].find((j) => j.tool === tool && j.name === name && j.status === "running");
  if (running) return running;

  const job: LoginJob = { id: crypto.randomUUID(), tool, name, status: "running", startedAt: new Date().toISOString() };
  jobs.set(job.id, job);
  // Argument array, no shell: the name is passed verbatim. The CLIs refuse to run OAuth without a terminal,
  // so `script` gives them a pseudo-terminal; they open the browser and wait for the callback.
  const proc = Bun.spawn(["script", "-q", "/dev/null", tool, "mcp", "login", name], { cwd: homedir(), stdin: "ignore", stdout: "ignore", stderr: "ignore" });
  const timer = setTimeout(() => {
    if (job.status === "running") {
      job.status = "timed-out";
      job.endedAt = new Date().toISOString();
      proc.kill();
    }
  }, TIMEOUT_MS);
  proc.exited.then((code) => {
    clearTimeout(timer);
    if (job.status !== "running") return;
    job.exitCode = code;
    job.status = code === 0 ? "succeeded" : "failed";
    job.endedAt = new Date().toISOString();
  });
  return job;
}

export function listJobs(): LoginJob[] {
  return [...jobs.values()].sort((a, b) => b.startedAt.localeCompare(a.startedAt)).slice(0, 20);
}

export type LoginEvent =
  | { type: "opening"; harness: Tool; server: string }
  | { type: "waiting"; harness: Tool; server: string }
  | { type: "done"; harness: Tool; server: string; ok: boolean; message?: string };

/** The same PTY trick for the CLI's --json mode: the harness opens the browser and stores the token itself. */
export async function loginWithEvents(tool: Tool, name: string, emit: (e: LoginEvent) => void): Promise<number> {
  emit({ type: "opening", harness: tool, server: name });
  const proc = Bun.spawn(["script", "-q", "/dev/null", tool, "mcp", "login", name], { cwd: homedir(), stdin: "ignore", stdout: "pipe", stderr: "ignore" });
  // Drained while the login runs; its last line explains a failure better than an exit code.
  const output = new Response(proc.stdout).text();
  emit({ type: "waiting", harness: tool, server: name });
  let timedOut = false;
  const timer = setTimeout(() => {
    timedOut = true;
    proc.kill();
  }, TIMEOUT_MS);
  const code = await proc.exited;
  clearTimeout(timer);
  const ok = code === 0 && !timedOut;
  const reason = ok || timedOut ? undefined : failureReason(await output.catch(() => ""));
  emit({ type: "done", harness: tool, server: name, ok, message: ok ? undefined : timedOut ? "timed out after 5 minutes" : reason ?? `${tool} mcp login exited with ${code}` });
  return ok ? 0 : 1;
}

/** Last meaningful line of the harness's login output, without terminal escapes or hyperlinks. */
export function failureReason(raw: string): string | undefined {
  const clean = raw
    .replace(/\x1b\]8;;[^\x07\x1b]*(\x07|\x1b\\)/g, "")
    .replace(/\x1b\[[0-9;?]*[A-Za-z]/g, "")
    .replace(/\r/g, "\n");
  const lines = clean.split("\n").map((l) => l.trim()).filter((l) => l && !/claude\.ai connectors are disabled/.test(l));
  const line = lines.reverse().find((l) => /couldn|error|fail|incompatible|denied|invalid|not supported/i.test(l)) ?? lines[0];
  return line ? line.slice(0, 240) : undefined;
}
