// Small shared helpers. Nothing here writes outside the paths callers pass in.
import { mkdirSync, readdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import { HOME } from "./config";

export function run(cmd: string[], cwd = HOME, timeoutMs = 60_000): { ok: boolean; out: string; code: number } {
  try {
    const p = Bun.spawnSync(cmd, { cwd, stdout: "pipe", stderr: "pipe", timeout: timeoutMs });
    return { ok: p.exitCode === 0, out: `${p.stdout.toString()}${p.stderr.toString()}`, code: p.exitCode ?? -1 };
  } catch (e) {
    return { ok: false, out: String(e), code: -1 };
  }
}

export function readJson<T = any>(p: string): T | undefined {
  try {
    return JSON.parse(readFileSync(p, "utf8"));
  } catch {
    return undefined;
  }
}

export function readToml(p: string): any {
  try {
    return Bun.TOML.parse(readFileSync(p, "utf8"));
  } catch {
    return undefined;
  }
}

export function readText(p: string): string | undefined {
  try {
    return readFileSync(p, "utf8");
  } catch {
    return undefined;
  }
}

export function ls(dir: string): string[] {
  try {
    return readdirSync(dir).filter((n) => !n.startsWith("."));
  } catch {
    return [];
  }
}

/** Write via a temp file and rename, so a crash never leaves a half-written file. */
export function writeFileAtomic(p: string, data: string) {
  mkdirSync(dirname(p), { recursive: true });
  const tmp = `${p}.${process.pid}.tmp`;
  writeFileSync(tmp, data);
  renameSync(tmp, p);
}

export function frontmatter(md: string): Record<string, string> {
  const m = md.match(/^---\n([\s\S]*?)\n---/);
  if (!m) return {};
  const out: Record<string, string> = {};
  let key = "";
  for (const line of m[1].split("\n")) {
    const kv = line.match(/^([A-Za-z_-]+):\s*(.*)$/);
    if (kv) {
      key = kv[1];
      out[key] = kv[2].replace(/^[>|]-?\s*$/, "").replace(/^["']|["']$/g, "");
    } else if (key && /^\s+\S/.test(line)) {
      out[key] = `${out[key]} ${line.trim()}`.trim();
    }
  }
  return out;
}

/** Claude rules with `paths:` frontmatter load only when a matching file is read. */
export const hasPathsFrontmatter = (md: string) => /^paths:/m.test(md.match(/^---\n([\s\S]*?)\n---/)?.[1] ?? "");

/** ~4 characters per token: the same rough rule the harnesses' own estimates use for prose. */
export const estTokens = (text: string) => Math.ceil(text.length / 4);

export const tokensOfFile = (p: string) => estTokens(readText(p) ?? "");

export const byTokensDesc = <T extends { tokens: number }>(a: T, b: T) => b.tokens - a.tokens;
