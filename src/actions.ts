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
    if (row.codex?.serverName && row.codex.auth === "o_auth") codex.add(row.codex.serverName);
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
