// The manifest records intent: which harness provides each service and how, which skills are canonical,
// and policies an update must not silently revert. Observed state stays the source of truth for health.
//
// ~/.config/actl/manifest.toml
//
//   version = 1
//
//   [policy.claude]
//   instruction_files = "claude-md-and-agents-md"   # claude-md | claude-md-or-agents-md | claude-md-and-agents-md | managed-only
//
//   [policy.rules.argent]                            # a Claude rule that must stay path-scoped
//   file = "~/.claude/rules/argent.md"
//   paths = ["**/ios/**", "**/android/**"]
//
//   [skills]
//   canonical = "~/.agents/skills"
//   packages = [{ source = "acme/skills", skills = ["a", "b"] }]
//   repos = { "~/Code/acme/web" = "sync" }
//
//   [service.sentry]
//   name = "Sentry"
//   claude = { plugin = "sentry@claude-plugins-official" }            # optional: enabled = false
//   codex  = { mcp = { name = "sentry", url = "https://mcp.sentry.dev/mcp" } }
//   # other providers: { connector = "notion@openai-curated-remote" }, { claudeai = "Notion" },
//   #                  { gap = "why this harness can't have it" }, { removed = true }
//   # a service-level state = "removed" removes it from every harness on apply
import { existsSync } from "node:fs";
import { paths, tilde } from "./config";
import { readText } from "./util";

export type McpSpec = { name?: string; url?: string; command?: string; args?: string[] };
export type ProviderSpec = {
  plugin?: string;
  enabled?: boolean;
  connector?: string;
  mcp?: McpSpec;
  claudeai?: string;
  gap?: string;
  removed?: boolean;
  why?: string;
};
export type ServiceSpec = { name?: string; state?: "active" | "removed"; why?: string } & Record<string, ProviderSpec | string | undefined>;
export type RuleSpec = { harness?: string; file: string; paths: string[]; why?: string };
export type Manifest = {
  version: number;
  policy?: { claude?: { instruction_files?: string }; rules?: Record<string, RuleSpec> };
  skills?: { canonical?: string; packages?: { source: string; skills: string[] }[]; repos?: Record<string, string> };
  service?: Record<string, ServiceSpec>;
  proxy?: { endpoint?: string };
};

export const HARNESS_KEYS = ["claude", "codex"] as const;
export const INSTRUCTION_MODES = ["claude-md", "claude-md-or-agents-md", "claude-md-and-agents-md", "managed-only"];
const PROVIDER_KINDS = ["plugin", "connector", "mcp", "claudeai", "gap", "removed"] as const;

export function providerKind(p: ProviderSpec): (typeof PROVIDER_KINDS)[number] | undefined {
  return PROVIDER_KINDS.find((k) => p[k] !== undefined);
}

export function validate(m: any): string[] {
  const errors: string[] = [];
  if (!m || typeof m !== "object") return ["manifest is not a table"];
  if (m.version !== 1) errors.push(`version must be 1 (found ${JSON.stringify(m.version)})`);
  const mode = m.policy?.claude?.instruction_files;
  if (mode !== undefined && !INSTRUCTION_MODES.includes(mode)) errors.push(`policy.claude.instruction_files: "${mode}" is not one of ${INSTRUCTION_MODES.join(", ")}`);
  for (const [id, r] of Object.entries<any>(m.policy?.rules ?? {})) {
    if (typeof r?.file !== "string") errors.push(`policy.rules.${id}: file is required`);
    if (!Array.isArray(r?.paths) || !r.paths.length || r.paths.some((p: unknown) => typeof p !== "string")) errors.push(`policy.rules.${id}: paths must be a non-empty list of globs`);
    if (r?.harness !== undefined && r.harness !== "claude") errors.push(`policy.rules.${id}: only Claude rules can be path-scoped`);
  }
  const sk = m.skills;
  if (sk !== undefined) {
    if (sk.canonical !== undefined && typeof sk.canonical !== "string") errors.push("skills.canonical must be a path");
    for (const [i, p] of (sk.packages ?? []).entries()) if (typeof p?.source !== "string" || !Array.isArray(p?.skills)) errors.push(`skills.packages[${i}]: needs source and skills`);
    for (const [repo, mode] of Object.entries<any>(sk.repos ?? {})) if (mode !== "sync" && mode !== "ignore") errors.push(`skills.repos."${repo}": use "sync" or "ignore"`);
  }
  for (const [id, s] of Object.entries<any>(m.service ?? {})) {
    if (!/^[a-z0-9][a-z0-9-]*$/.test(id)) errors.push(`service.${id}: ids are lowercase letters, digits and dashes`);
    if (s?.state !== undefined && s.state !== "active" && s.state !== "removed") errors.push(`service.${id}.state: "active" or "removed"`);
    for (const h of HARNESS_KEYS) {
      const p = s?.[h];
      if (p === undefined) continue;
      if (typeof p !== "object") {
        errors.push(`service.${id}.${h}: must be an inline table`);
        continue;
      }
      const kinds = PROVIDER_KINDS.filter((k) => p[k] !== undefined);
      if (kinds.length !== 1) errors.push(`service.${id}.${h}: set exactly one of ${PROVIDER_KINDS.join(", ")} (found ${kinds.join(", ") || "none"})`);
      if (p.plugin !== undefined && !/^[^@\s]+@[^@\s]+$/.test(p.plugin)) errors.push(`service.${id}.${h}.plugin: use name@marketplace`);
      if (p.connector !== undefined && (h !== "codex" || !/^[^@\s]+@[^@\s]+$/.test(p.connector))) errors.push(`service.${id}.${h}.connector: Codex only, as name@marketplace`);
      if (p.claudeai !== undefined && h !== "claude") errors.push(`service.${id}.${h}.claudeai: Claude only`);
      if (p.mcp !== undefined && (typeof p.mcp !== "object" || (!p.mcp.url && !p.mcp.command))) errors.push(`service.${id}.${h}.mcp: needs url or command`);
      if (p.mcp?.url !== undefined && !/^https?:\/\//.test(p.mcp.url)) errors.push(`service.${id}.${h}.mcp.url: must be http(s)`);
      if (p.removed !== undefined && p.removed !== true) errors.push(`service.${id}.${h}.removed: only true is meaningful`);
      if (p.gap !== undefined && typeof p.gap !== "string") errors.push(`service.${id}.${h}.gap: give the reason as a string`);
    }
  }
  return errors;
}

export function loadManifest(path = paths.manifest): { path: string; exists: boolean; manifest?: Manifest; errors: string[] } {
  const text = readText(path);
  if (text === undefined) return { path: tilde(path), exists: existsSync(path), errors: [] };
  let parsed: any;
  try {
    parsed = Bun.TOML.parse(text);
  } catch (e) {
    return { path: tilde(path), exists: true, errors: [`TOML: ${String((e as Error).message ?? e)}`] };
  }
  return { path: tilde(path), exists: true, manifest: parsed, errors: validate(parsed) };
}

export const specFor = (m: Manifest | undefined, serviceId: string, harness: string): ProviderSpec | undefined => {
  const s = m?.service?.[serviceId];
  const p = s?.[harness];
  return p && typeof p === "object" ? (p as ProviderSpec) : undefined;
};

// ---------- writing ----------

export const tomlKey = (k: string) => (/^[A-Za-z0-9_-]+$/.test(k) ? k : JSON.stringify(k));
// JSON string escapes are valid TOML basic-string escapes.
export const tomlValue = (v: unknown): string => {
  if (typeof v === "string") return JSON.stringify(v);
  if (typeof v === "number" || typeof v === "boolean") return String(v);
  if (Array.isArray(v)) return `[${v.map(tomlValue).join(", ")}]`;
  if (v && typeof v === "object")
    return `{ ${Object.entries(v)
      .filter(([, x]) => x !== undefined)
      .map(([k, x]) => `${tomlKey(k)} = ${tomlValue(x)}`)
      .join(", ")} }`;
  return '""';
};
