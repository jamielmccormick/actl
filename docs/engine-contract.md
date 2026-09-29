# Engine contract (schema 2)

The macOS app and agents talk to the engine only through the `actl` CLI. Every state command prints one JSON document to stdout:

```ts
type Envelope<T> = { schema: 2; command: string; generatedAt: string; data: T };
```

Errors go to stderr as `actl: <message>`, with a non-zero exit code. Long-running commands (`apply`, `undo`, `login`) print **JSON Lines** progress events to stdout instead, one event per line, ending with a `done` or `error` event.

All paths in output use `~` for the home directory. Output never contains secrets: tokens, env values, headers, keys or full emails.

## Commands

| Command | Output | Writes |
| - | - | - |
| `actl inventory [--repo=<path>]` | `Inventory` (the existing collect.ts shape plus `services`, `budget` and `harnesses`) | its own cache and state only (see below) |
| `actl status` | `Status`: a small summary for the menu bar | no |
| `actl services [--cached]` | `Service[]` | no |
| `actl budget [--repo=<path>] [--cached]` | `Budget` | no |
| `actl findings` | `Finding[]` (collect.ts) | no |
| `actl proxy` | the existing `CliproxySnapshot` | caches it for `status` |
| `actl manifest adopt [--force]` | `{ path, created: boolean, manifest }` | writes the manifest if missing (or with `--force`) |
| `actl manifest show` | `{ path, exists, manifest, errors: string[] }` (`manifest` is `null` when missing) | no |
| `actl plan [--cached]` | `Plan` | no |
| `actl apply <actionId[=optionId]...> \| --all` | JSONL `ApplyEvent` | yes |
| `actl undo <runId>` | JSONL `ApplyEvent` | yes |
| `actl activity [--limit=50]` | `ActivityEntry[]` (newest first) | no |
| `actl login <claude\|codex> <server>` | interactive; with `--json`, JSONL `LoginEvent` | tokens are stored by the harness CLI |
| `actl logos refresh [--force]` | `{ id, state: "fetched" \| "cached" \| "skipped" \| "failed", file?, source? }[]` | the logo cache (network) |
| `actl plugin-costs refresh [--force]` | `{ id, tokens? }[]` | the plugin-cost cache (slow) |

`status` must be fast (< 1 s). It must not run `claude mcp list`; it reads the cached last inventory from `~/.cache/actl/inventory.json` (written by `inventory`) plus cheap file checks. Proxy account states come from `~/.cache/actl/proxy.json`, written by `actl proxy`; `status` never calls the proxy.

`services`, `budget`, `plan`, `apply` and `manifest adopt` collect a fresh inventory by default (5–15 s, because `claude mcp list` health-checks every server). `--cached` reuses the last inventory when one exists. `status` is always cached.

Engine files (`$XDG_CONFIG_HOME` defaults to `~/.config`, `$XDG_CACHE_HOME` to `~/.cache`):

| Path | What |
| - | - |
| `~/.config/actl/manifest.toml` | intent (the user's) |
| `~/.config/actl/state.json` | harness color slots |
| `~/.config/actl/activity.jsonl`, `backups/<runId>/` | apply history; `backups/<runId>/run.json` holds the undo recipe |
| `~/.cache/actl/inventory.json` (+ `.lock` while a refresh runs) | last inventory |
| `~/.cache/actl/plugin-costs.json` | `claude plugin details` always-on costs, keyed by `id@version` |
| `~/.cache/actl/proxy.json` | last proxy snapshot (already masked) |
| `~/Library/Caches/actl/logos/` | fetched service logos, refreshed after 30 days |

## Types

```ts
type HarnessId = "claude" | "codex" | string;   // more harnesses later
type Health = "connected" | "needs-auth" | "failed" | "blocked" | "pending" | "unknown" | "absent";

type Harness = {
  id: HarnessId; name: string; code: string;    // code: "CC", "CX", "CU", "GM", "OC", "CP"
  supported: boolean; installed: boolean; version?: string; home?: string;
  colorSlot: number;                            // 0–5, stable by first-seen order; the UI maps slots to hues
};
// code: one rule for every harness. Split the name into words (spaces and camelCase, ignoring "CLI" and
// "GitHub"); two or more words give their initials, one word gives its first letter plus its rarest
// remaining letter by English frequency. Collisions take the next rarest letter, then a digit.
// colorSlot: assigned once when a harness is first seen installed, persisted in state.json. Harnesses not
// installed get a provisional slot that is not persisted.

// A service is an outside system (Notion, Sentry, …). Skills-only plugins are NOT services.
type Service = {
  id: string;                                   // stable key, e.g. "sentry" (lowercase letters and digits)
  name: string;                                 // display name
  brandColor?: string;                          // from the plugin manifest when known
  logo?: string;                                // absolute path: the Codex plugin-manifest logo, else a fetched one
  homepage?: string;                            // where `actl logos refresh` looks for an icon
  providers: Partial<Record<HarnessId, Provider>>;
  parity: "both" | "only-claude" | "only-codex" | "gap" | "partial";
  gapReason?: string;                           // e.g. "no Claude equivalent while proxy auth is active"
};
// parity: "both" = active in both. "gap" = one side is missing or blocked and there is a reason: the manifest's
// `gap = "…"`, or a claude.ai connector blocked by proxy/API-key auth. "partial" = the other side is present
// but switched off (a disabled plugin); gapReason says so. "only-claude"/"only-codex" = missing, unexplained.

type Provider = {
  kind: "plugin" | "mcp" | "connector" | "claude.ai";   // a Codex plugin that bundles its own MCP server is "plugin"
  ref: string;                                  // plugin id, MCP server name or connector plugin id
  serverName?: string;                          // exact name to pass to `<harness> mcp login`
  health: Health; detail?: string;              // "absent" = installed but disabled
  // Codex does not health-check servers: its "connected" means configured with credentials (or none needed),
  // and `detail` says so. Connectors are "connected" when enabled; ChatGPT manages their sign-in.
  auth: "oauth" | "token" | "none" | "chatgpt" | "unknown";
  canSignIn: boolean;
  contextTokens?: number;                       // always-on cost per session (plugins); 0 for bare MCP
  contextEstimated?: boolean;                   // true until `claude plugin details` has been cached
  skills: string[];                             // skill names this provider contributes
  lazyAlternative?: { transport: "http"; url: string; serverName: string; oauth?: { clientId?: string; callbackPort?: number } };
  // exists => "Make lazy" is possible: exactly one HTTP server with no env-token headers. Tracking and
  // credential-like query parameters are stripped from the URL.
};

type Budget = {
  harnesses: Record<HarnessId, {
    total: number;
    categories: { id: "plugins" | "skills-listing" | "instructions" | "rules" | "drift"; tokens: number }[];
    levers: { id: string; label: string; tokens: number; kind: "plugin" | "rule" | "instructions" | "skills";
              action?: "make-lazy" | "rescope" | "disable"; serviceId?: string; estimated: boolean }[];
  }>;
  loadPreview?: { repo: string; harnesses: Record<HarnessId, { files: { path: string; reason: string; tokens: number }[]; total: number }> };
};
// Token counts: estimate ~4 chars per token for files. For plugins, cache the numbers from
// `claude plugin details <id>` ("Always-on: ~N tok") in ~/.cache/actl/plugin-costs.json, keyed by
// id@version; that command is slow, so never run it on the hot path. `inventory` fills missing entries in a
// detached background process; until then plugin costs are estimated from their skill listings.
// Codex has no rules and no published per-plugin cost: its "plugins" category is the plugins' skill
// listings, and levers there carry no action (Codex has no enable/disable CLI).
// Lever ids: "plugin:<harness>:<pluginId>", "rule:claude:<path>", "instructions:<harness>:<path>",
// "skills:<harness>:user". "drift" counts rules the manifest scopes that are always-on again, and Codex
// developer_instructions re-injected by a tool update.
// loadPreview: Claude loads ~/.claude/CLAUDE.md and its @imports (4 hops), user rules without `paths:`,
// then from the git root down to the repo path: CLAUDE.md, .claude/CLAUDE.md, AGENTS.md (per the
// instructionFiles mode), CLAUDE.local.md and always-on project rules. Codex loads ~/.codex/AGENTS.override.md
// or AGENTS.md, developer_instructions, then one AGENTS.override.md / AGENTS.md per directory from the git
// root, capped at project_doc_max_bytes (32 KiB); a file past the cap has tokens 0 and a "skipped" reason.

type Status = {
  level: "healthy" | "attention" | "error" | "syncing";
  harnesses: { id: HarnessId; name: string; connected: number; total: number; needsSignIn: number; failed: number }[];
  attention: AttentionItem[];                   // what the popover lists
  proxy?: { accounts: { label: string; state: "active" | "cooldown" | "disabled" | "error"; retryAt?: string }[] };
  checkedAt: string; stale: boolean;
};
// level: "error" if any error item, else "attention" if any warn item, else "syncing" while an inventory
// refresh is running, else "healthy". stale: no cache, or the cache is older than 30 minutes.
// Attention ids: "inventory.missing", "sign-in:<harness>", "failed:<harness>:<serviceId>",
// "drift:rule:<ruleId>", "drift:instructions-mode", "sync:skills", "sync:skill-conflicts",
// "gap:services", "quota:<account label>", "update:proxy".
type AttentionItem = {
  id: string; severity: "error" | "warn" | "info";
  kind: "sign-in" | "failed" | "drift" | "sync" | "update" | "gap" | "quota";
  title: string; detail?: string; harness?: HarnessId;
  fix?: { label: string; actionIds?: string[]; signIn?: { harness: HarnessId; servers: string[] } };
};

// Manifest: TOML at ~/.config/actl/manifest.toml. The schema is documented at the top of src/manifest.ts:
//   version = 1
//   [policy.claude] instruction_files = "claude-md" | "claude-md-or-agents-md" | "claude-md-and-agents-md" | "managed-only"
//   [policy.rules.<id>] file = "~/.claude/rules/x.md", paths = ["glob", …]      (a rule that must stay path-scoped)
//   [skills] canonical, packages = [{ source, skills }] (recorded only), repos = { "<path>" = "sync" | "ignore" }
//   [service.<id>] name, state = "removed"?, and per harness one of:
//     { plugin = "name@mkt", enabled? } | { connector = "name@mkt" } (Codex) | { mcp = { name?, url? | command?, args? } }
//     | { claudeai = "Name" } (Claude, recorded only) | { gap = "reason" } | { removed = true }; each may add `why`.
//   [proxy] endpoint
type Plan = {
  manifestPath: string; manifestExists: boolean;
  manifestErrors: string[];                     // a manifest with errors plans as if absent
  actions: PlanAction[];
  summary: { count: number; tokensDelta: Record<HarnessId, number> };
};
type PlanAction = {
  id: string;                                   // stable for identical drift, e.g. "skills.sync:user"
  harness?: HarnessId | "proxy";
  group: "instructions" | "skills" | "services" | "plugins" | "proxy";
  kind: "skills.sync" | "skills.resolve-conflict" | "mcp.add" | "mcp.remove" | "plugin.install" |
        "plugin.uninstall" | "plugin.enable" | "plugin.disable" | "service.make-lazy" | "rule.rescope" |
        "instructions.mode" | "proxy.update";
  title: string;                                // "Re-scope the argent rule to mobile paths"
  detail?: string;
  consequence?: string;                         // "Brief restart of the proxy (~3 s)"
  tokensDelta?: number;                         // negative = saves tokens
  diff?: { path: string; before: string; after: string };
  requiresChoice?: { options: { id: string; label: string }[] };   // e.g. a skill conflict
  reversible: boolean;
  defaultSelected: boolean;
};
// Action ids: "<kind>:<harness>:<serviceId>" for service and plugin kinds, "rule.rescope:claude:<ruleId>",
// "instructions.mode:claude", "skills.sync:<scope>", "skills.resolve-conflict:<scope>:<skill>", "proxy.update".
// Skill scopes are "user" and "repo:<name>".
// service.make-lazy is planned default-selected when the manifest asks for an MCP provider where a plugin is
// installed, and as a suggestion (defaultSelected false, detail starts "Suggestion.") for every other enabled
// plugin that has a lazyAlternative. It disables the plugin (`claude plugin disable -s user`), adds the server at
// user scope, and rewrites the service's `claude = …` line if the manifest pinned the plugin.
// plugin.enable/disable are Claude only. tokensDelta in summary sums default-selected actions.

type ApplyEvent =
  | { type: "start"; runId: string; actions: string[] }
  | { type: "backup"; runId: string; files: string[]; dir: string }
  | { type: "step"; runId: string; actionId: string; state: "running" | "ok" | "failed" | "skipped"; message?: string }
  | { type: "done"; runId: string; ok: number; failed: number; tookMs: number }
  | { type: "error"; runId?: string; message: string };

type ActivityEntry = {
  runId: string; at: string; source: "user" | "watch" | "auto";
  actions: { id: string; title: string; state: "ok" | "failed" | "skipped" }[];
  undoable: boolean; undoneAt?: string;
  undoOf?: string;                              // set on the entry an undo run writes
};

// login --json runs `script -q /dev/null <harness> mcp login <server>` so the CLI gets a PTY and opens the
// browser; it times out after 5 minutes. With a cached inventory, only known sign-in targets are accepted.
type LoginEvent =
  | { type: "opening"; harness: HarnessId; server: string }
  | { type: "waiting"; harness: HarnessId; server: string }
  | { type: "done"; harness: HarnessId; server: string; ok: boolean; message?: string };
```

## Apply rules

- **Back up before writing.** Every file an action edits is copied to `~/.config/actl/backups/<runId>/` first. `undo` restores from the backup, or runs the inverse command.
- **Use each harness's CLI where one exists.** Install and remove plugins and MCP servers with `claude plugin install|uninstall`, `claude mcp add|remove -s user`, `codex plugin add|remove` and `codex mcp add|remove`. Edit files directly only when there is no CLI, for example rule frontmatter.
- **Never apply without an explicit command.** Actions run only when named by id or with `--all`. `plan` and every other state command are read-only.
- **Record each run** in `~/.config/actl/activity.jsonl`.
- **Choices.** An action with `requiresChoice` runs only as `<actionId>=<optionId>`; without one it is reported `skipped`. `--all` runs the default-selected actions, which never require a choice.
- **Unknown ids** (already applied, or the state changed) are reported `skipped`. `apply` re-plans against a fresh inventory, so an id means the same drift it meant in `plan`.
- **All or nothing per action.** If a step fails, the action's earlier steps are rolled back before the next action runs.
- **Harness config files** (`~/.claude.json`, `~/.claude/settings.json`, `installed_plugins.json`, `~/.codex/config.toml`) are copied to the backup before a CLI edits them, for manual recovery. Undo uses inverse commands rather than restoring them, so unrelated changes made since are kept. An `mcp.remove` of a server with headers or env values is not reversible, because those values are never read.
- **Undo** runs once per run, in reverse order, and only for actions that succeeded. An undo run can't itself be undone.

## Revisions

Schema 2, implemented 2026-09-28. Additions to the first draft (all additive; nothing was removed or renamed):

- `Service.homepage`; `Provider.contextEstimated`; `lazyAlternative.serverName` and `lazyAlternative.oauth`.
- Plan kind `instructions.mode` (sets Claude's `instructionFiles` mode in `~/.claude/settings.json`); `Plan.manifestErrors`.
- `ActivityEntry.undoOf`.
- `apply <id>=<optionId>` for choices; `--all` means default-selected actions.
- `--cached` on `services`, `budget`, `plan`, `apply` and `manifest adopt`; `inventory --repo` adds a load preview.
- Commands `logos refresh` and `plugin-costs refresh`; `actl proxy` caches its snapshot for `status`.
- Not supported yet, so never planned: Codex `plugin.enable`/`plugin.disable` (Codex has no CLI for it), removing project- or local-scope MCP servers, and installing skill `packages`.
