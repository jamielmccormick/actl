# actl

*Pronounced "actual".* The actual state of your coding agents: instructions, skills, MCP servers, plugins and sign-ins, kept at parity across Claude Code and Codex.

A native macOS app is in design (see `docs/mac-app.md`). Today it ships as the `actl` engine and a local web dashboard.

- **Instructions**: global and per-repo `AGENTS.md`, `CLAUDE.md`, `CLAUDE.local.md` and `.claude/rules`, with which tool loads each file.
- **Skills**: `~/.claude/skills`, `~/.codex/skills`, `~/.agents/skills`, repo `.claude/skills` and `.agents/skills`, and plugin skills, with visibility per tool and broken or version-pinned links.
- **MCP servers**: one matrix across both tools. Claude status comes from `claude mcp list` (live health check). Codex status comes from `codex mcp list --json`.
- **Plugins**: Claude `enabledPlugins` and Codex `[plugins]`.
- **Findings**: computed problems, such as dead links, servers configured in only one tool, blocked claude.ai connectors, and duplicate instruction files.
- **CLIProxyAPI**: proxy status, pooled accounts (masked), per-account traffic, error logs, and version drift, read through the management API on the server side.
- **Sign-in**: one-click MCP OAuth. The server runs `claude mcp login` or `codex mcp login` for servers listed in the current inventory, and the browser handles the rest.

## Skills sync

`~/.agents/skills` is the canonical, cross-tool location, and Codex reads it natively. `bun src/skills-sync.ts --apply` copies skills into `~/.claude/skills` and into a repo's `.claude/skills` when the repo gitignores it. No symlinks are used. A hash manifest (`.actl-sync.json`) means changed sources are re-copied, and copies edited in place are reported as conflicts, never overwritten. Skills that exist only in `~/.claude/skills` are promoted to `~/.agents/skills`. Skills a Claude plugin already provides are skipped. Without `--apply`, it prints the plan.

## Setup

Requirements: macOS, [Bun](https://bun.sh), and at least one supported harness: Claude Code and/or Codex.

```sh
git clone <repo-url> actl && cd actl
bun src/actl.ts findings | jq      # works with no configuration
```

Configuration is optional. Create `~/.config/actl/config.toml` to change the defaults:

```toml
[scan]
roots = ["~/Code"]                 # default: ~/Code, ~/Developer, ~/Projects, ~/src, … whichever exist
workspaces = ["~/Documents/Notes"] # folders whose children hold AGENTS.md/CLAUDE.md

[proxy]                            # optional CLIProxyAPI integration
enabled = "auto"                   # "auto" (use it if it's running and a key exists) | true | false
endpoint = "http://127.0.0.1:8317"
key_file = "~/.cli-proxy-api/management-key"
```

Tool homes follow each tool's own overrides: `CLAUDE_CONFIG_DIR`, `CODEX_HOME` and `XDG_CONFIG_HOME`.

## CLI

```sh
bun src/actl.ts inventory|findings|proxy     # JSON: { schema, command, data }
bun src/actl.ts skills plan|apply [--repo=~/Code/app]
bun src/actl.ts login claude|codex <server>  # MCP OAuth sign-in in your terminal
bun build --compile src/actl.ts --outfile build/actl   # single self-contained binary
```

## Run

```sh
bun src/server.ts          # http://127.0.0.1:4777
bun src/collect.ts | jq    # raw inventory JSON
```

The server binds to `127.0.0.1` only. The inventory is cached for five minutes; **Refresh** re-collects it, which takes about 5–10 seconds because `claude mcp list` health-checks every server.

## Safety

- Writes are limited to starting an MCP sign-in, and to `skills-sync --apply` from the CLI. Everything else is read-only; where a fix exists, the UI shows the command.
- POST requests need an `x-actl` header and a same-origin `Origin`. Every `/api` route rejects non-loopback `Host` headers, which blocks DNS rebinding.
- The CLIProxyAPI management key stays on the server. It's read from `~/.cli-proxy-api/management-key`, only an allowlist of GET routes is called, and a single 401 stops further calls, because five failures ban localhost for 30 minutes.
- No secrets. The collector reads server names, URLs and commands, but never env values, headers or tokens.
- Repos are discovered from common code folders, from projects your harnesses have opened, and from `scan.roots` in the config. Only main checkouts count, not linked worktrees.

## Background: how each tool loads configuration (checked 2026-09-28, Claude Code 2.1.283, codex-cli 0.158.0)

| | Claude Code | Codex |
| - | - | - |
| Global instructions | `~/.claude/CLAUDE.md` (imports `~/.codex/AGENTS.md`), `~/.claude/rules/*.md` | `~/.codex/AGENTS.md` |
| Project instructions | `CLAUDE.md` and `AGENTS.md` (mode `claude-md-and-agents-md` in `~/.claude/settings.json`); nested files load when Claude reads files in that directory | `AGENTS.md` from the git root down to the cwd; nothing below the cwd; 32 KiB combined cap |
| Imports | `@path`, up to 4 hops | None |
| Skills | `~/.claude/skills`, `.claude/skills`, plugins. **Does not read `.agents/skills`** | `~/.agents/skills`, repo `.agents/skills`, `~/.codex/skills` (legacy), plugins |
| MCP | `~/.claude.json` (user/local), `.mcp.json` (project), plugins, claude.ai connectors | `~/.codex/config.toml` `[mcp_servers]`, project `.codex/config.toml`, plugins |

claude.ai connectors load only under a claude.ai login. When `ANTHROPIC_AUTH_TOKEN`/`ANTHROPIC_BASE_URL` are set, for example by CLIProxyAPI, they are disabled. Register the servers you need directly in `~/.claude.json` instead.
