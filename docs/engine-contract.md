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
| `actl inventory` | `Inventory` (the existing collect.ts shape plus `services`, `budget` and `harnesses`) | no |
| `actl status` | `Status`: a small summary for the menu bar | no |
| `actl services` | `Service[]` | no |
| `actl budget [--repo=<path>]` | `Budget` | no |
| `actl proxy` | the existing `CliproxySnapshot` | no |
| `actl manifest adopt [--force]` | `{ path, created: boolean, manifest }` | writes the manifest if missing (or with `--force`) |
| `actl manifest show` | `{ path, exists, manifest, errors: string[] }` | no |
| `actl plan` | `Plan` | no |
| `actl apply <actionId...> \| --all` | JSONL `ApplyEvent` | yes |
| `actl undo <runId>` | JSONL `ApplyEvent` | yes |
| `actl activity [--limit=50]` | `ActivityEntry[]` | no |
| `actl login <claude\|codex> <server>` | interactive; with `--json`, JSONL `LoginEvent` | tokens are stored by the harness CLI |

`status` must be fast (< 1 s). It must not run `claude mcp list`; it reads the cached last inventory from `~/.cache/actl/inventory.json` (written by `inventory`) plus cheap file checks.

## Types

```ts
type HarnessId = "claude" | "codex" | string;   // more harnesses later
type Health = "connected" | "needs-auth" | "failed" | "blocked" | "pending" | "unknown" | "absent";

type Harness = {
  id: HarnessId; name: string; code: string;    // code: "CC", "CX", "CU", "GM", "OC"
  supported: boolean; installed: boolean; version?: string; home?: string;
  colorSlot: number;                            // 0–5, stable by first-seen order; the UI maps slots to hues
};

// A service is an outside system (Notion, Sentry, …). Skills-only plugins are NOT services.
type Service = {
  id: string;                                   // stable key, e.g. "sentry"
  name: string;                                 // display name
  brandColor?: string;                          // from the plugin manifest when known
  logo?: string;                                // absolute path to a cached logo file, if resolved
  providers: Partial<Record<HarnessId, Provider>>;
  parity: "both" | "only-claude" | "only-codex" | "gap" | "partial";
  gapReason?: string;                           // e.g. "no Claude equivalent while proxy auth is active"
};

type Provider = {
  kind: "plugin" | "mcp" | "connector" | "claude.ai";
  ref: string;                                  // plugin id, MCP server name or connector plugin id
  serverName?: string;                          // exact name to pass to `<harness> mcp login`
  health: Health; detail?: string;
  auth: "oauth" | "token" | "none" | "chatgpt" | "unknown";
  canSignIn: boolean;
  contextTokens?: number;                       // always-on cost per session (plugins); 0 for bare MCP
  skills: string[];                             // skill names this provider contributes
  lazyAlternative?: { transport: "http"; url: string };   // exists => "Make lazy" is possible
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
// id@version; that command is slow, so never run it on the hot path.

type Status = {
  level: "healthy" | "attention" | "error" | "syncing";
  harnesses: { id: HarnessId; name: string; connected: number; total: number; needsSignIn: number; failed: number }[];
  attention: AttentionItem[];                   // what the popover lists
  proxy?: { accounts: { label: string; state: "active" | "cooldown" | "disabled" | "error"; retryAt?: string }[] };
  checkedAt: string; stale: boolean;
};
type AttentionItem = {
  id: string; severity: "error" | "warn" | "info";
  kind: "sign-in" | "failed" | "drift" | "sync" | "update" | "gap" | "quota";
  title: string; detail?: string; harness?: HarnessId;
  fix?: { label: string; actionIds?: string[]; signIn?: { harness: HarnessId; servers: string[] } };
};

// Manifest: TOML at ~/.config/actl/manifest.toml (schema in docs/mac-app.md).
type Plan = {
  manifestPath: string; manifestExists: boolean;
  actions: PlanAction[];
  summary: { count: number; tokensDelta: Record<HarnessId, number> };
};
type PlanAction = {
  id: string;                                   // stable for identical drift, e.g. "skills.sync:user"
  harness?: HarnessId | "proxy";
  group: "instructions" | "skills" | "services" | "plugins" | "proxy";
  kind: "skills.sync" | "skills.resolve-conflict" | "mcp.add" | "mcp.remove" | "plugin.install" |
        "plugin.uninstall" | "plugin.enable" | "plugin.disable" | "service.make-lazy" | "rule.rescope" |
        "proxy.update";
  title: string;                                // "Re-scope the argent rule to mobile paths"
  detail?: string;
  consequence?: string;                         // "Brief restart of the proxy (~3 s)"
  tokensDelta?: number;                         // negative = saves tokens
  diff?: { path: string; before: string; after: string };
  requiresChoice?: { options: { id: string; label: string }[] };   // e.g. a skill conflict
  reversible: boolean;
  defaultSelected: boolean;
};

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
};

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
