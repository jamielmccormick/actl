// actl: the actl engine as a CLI. The Mac app and agent sessions both call this.
// Every command that reports state prints one JSON document to stdout: { schema, command, data }.
//
//   actl inventory                      full inventory (instructions, skills, MCP, plugins, findings)
//   actl findings                       findings only
//   actl proxy                          CLIProxyAPI snapshot (masked; key stays in this process)
//   actl skills plan [--repo=<path>]    skills sync plan
//   actl skills apply [--repo=<path>]   apply the skills sync plan
//   actl login <claude|codex> <server>  run the MCP OAuth sign-in in this terminal
import { expand } from "./config";
import { resolve } from "node:path";
import { cliproxy } from "./cliproxy";
import { collect } from "./collect";
import { applyPlan, planAll } from "./skills-sync";

const SCHEMA = 1;
const [command, sub, ...rest] = process.argv.slice(2);
const flags = [sub, ...rest].filter((a): a is string => !!a && a.startsWith("--"));
const repos = flags.filter((a) => a.startsWith("--repo=")).map((a) => resolve(expand(a.slice(7))));

function emit(data: unknown) {
  process.stdout.write(`${JSON.stringify({ schema: SCHEMA, command: [command, sub].filter((x) => x && !x.startsWith("--")).join(" "), data })}\n`);
}

function fail(message: string, code = 2): never {
  process.stderr.write(`actl: ${message}\n`);
  process.exit(code);
}

switch (command) {
  case "inventory":
    emit(collect());
    break;
  case "findings":
    emit(collect().findings);
    break;
  case "proxy":
    emit(await cliproxy(true));
    break;
  case "skills": {
    const { plans, skippedRepos } = planAll(repos);
    if (sub === "plan") emit({ plans, skippedRepos });
    else if (sub === "apply") emit({ applied: plans.map((p) => ({ scope: p.scope, log: applyPlan(p) })), skippedRepos });
    else fail("usage: actl skills <plan|apply> [--repo=<path>]");
    break;
  }
  case "login": {
    const name = rest[0];
    if ((sub !== "claude" && sub !== "codex") || !name) fail("usage: actl login <claude|codex> <server>");
    // Interactive: the CLI owns the OAuth flow and token storage; we only hand it the terminal.
    const proc = Bun.spawn([sub, "mcp", "login", name], { stdio: ["inherit", "inherit", "inherit"] });
    process.exit(await proc.exited);
  }
  default:
    fail(`unknown command${command ? ` "${command}"` : ""}. Commands: inventory, findings, proxy, skills plan|apply, login`);
}
