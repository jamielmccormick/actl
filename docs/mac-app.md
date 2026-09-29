# actl for Mac: design

Status: in design (2026-09-28). The mockups are in Paper, in the file "actl — Mac app". The project is meant to be published as open source, so nothing may assume one person's machine.

## Goal

One always-on place to see and manage every agent capability on this Mac across Claude Code and Codex: services (connectors and MCP servers), skills, plugins, instructions, and the CLIProxyAPI subscription pool. Anything that drifts out of parity, needs a sign-in, or breaks after an update is reported without you having to ask.

## Shape

- **Menu bar item**, always running. Its icon shows health (healthy / needs attention / error). The popover lists what needs you, each with a one-click fix: sign in, apply sync, or a proxy account in cooldown.
- **Main window** for everything else: Home, Services, Skills, Instructions, Proxy, Context budget, and Review changes.
- **Notifications** only for things that need action: a sign-in expired, a proxy account went unavailable, an update reverted a change, or a new version is out.
- **Login item** through `SMAppService`, so it starts with the Mac. No hand-written LaunchAgent plist.

## Architecture

```
actl.app (SwiftUI, macOS 27)
 ├─ MenuBarExtra (window style)  ─┐
 ├─ Main window (NavigationSplitView)
 ├─ Store: observable models, stale-while-revalidate cache
 ├─ Watchers: FSEvents on ~/.claude, ~/.codex, ~/.agents, repo skill dirs
 └─ Engine client ── Process ──► actl (bundled binary)
                                  ├─ inventory   (read-only, JSON)
                                  ├─ plan        (manifest vs actual → actions)
                                  ├─ apply       (runs the approved actions)
                                  ├─ login       (claude/codex mcp login under a PTY)
                                  ├─ proxy       (CLIProxyAPI, allowlisted GETs)
                                  └─ manifest adopt | validate
```

**Engine: keep TypeScript and ship it as a binary.** `actl` is today's collector, skills sync, proxy client and login code. `bun build --compile` turns it into one self-contained binary (about 60 MB) that the app bundles. It is also installed to `~/.local/bin`, so Claude and Codex sessions can run `actl plan` themselves, and a small `actl` skill teaches them how.
- **Why not rewrite in Swift:** the logic already works and is tested. Agents get the same engine the app uses. Engine changes don't need an app rebuild.
- **Cost:** two languages, and the binary is large. If that ever matters, the JSON contract lets us port the engine to Swift later without touching the UI.

**Service logos.** `actl` resolves each service's mark and caches it under `~/Library/Application Support/actl/logos/`, trying three sources in order:

1. **Plugin manifest.** Codex plugin manifests ship `interface.logo`, `composerIcon` and `brandColor`. These are official and local. The same manifests also give display names for opaque connector IDs, such as `app-69d9…` → NetSuite.
2. **The service's own site.** The engine fetches the `apple-touch-icon` or `icon` link from the homepage listed in the Claude marketplace entry (or the service URL's domain), once, and refreshes it monthly. No third-party favicon service is used.
3. **A designed monogram tile.** Its color is derived from the service name.

Low-resolution sources render smaller inside the standard tile instead of being upscaled. The first pass found usable icons for 35 of 36 services; Intercom needs the fallback.

**No local web server.** The app calls the engine directly, so the localhost HTTP surface and its DNS-rebinding and CSRF guards go away.

**Refresh strategy.**
- File-based state (instructions, skills, plugins, manifest drift) refreshes within a second when FSEvents fires.
- Live MCP health (`claude mcp list` starts every server) runs every 30 minutes, when the popover opens with data older than 5 minutes, and on demand.
- The proxy panel refreshes every 60 s while visible and every 10 minutes in the background.

**Build and install.**
- A Swift package plus a `make app` script assembles `actl.app`, ad-hoc signs it, and copies it to `~/Applications`.
- There is no App Store, notarization or sandbox. The app needs to read your home directory and run the CLIs.
- `make install` rebuilds from the repo, so updating means `git pull && make install`.

## The manifest: recommended

Yes, adopt one, with two rules that keep it from becoming a chore:

1. **You never have to edit it by hand.** On first run, `actl manifest adopt` writes it from the current state. After that, every change you make in the app updates the manifest and then applies it. Hand edits still work, and the app shows them as pending changes.
2. **Observed state stays the source of truth for health; the manifest records intent.** Drift means actual state and intent disagree. The app shows the diff as a plan and never auto-applies it.

This is what makes the app a management tool rather than a viewer. "Add Linear to both harnesses" or "remove Zoom everywhere" becomes one intent that turns into the right per-harness actions. It also records decisions and their reasons (for example, "PostHog is MCP-only in Claude: the plugin costs 30k tokens/session") that would otherwise live only in memory.

Location: `~/.config/actl/manifest.toml`. It could later move into a private dotfiles repo for history and a second machine.

```toml
version = 1

[harness.claude]
project_instructions = "claude-md-and-agents-md"

[instructions]
shared = "~/.codex/AGENTS.md"          # imported by ~/.claude/CLAUDE.md

# A service is the unit of parity. Each harness says how it provides it, or why it can't.
[service.notion]
claude = { plugin = "notion@claude-plugins-official" }
codex  = { connector = "notion@openai-curated-remote" }

[service.sentry]
claude = { plugin = "sentry@claude-plugins-official" }
codex  = { mcp = { url = "https://mcp.sentry.dev/mcp" } }

[service.posthog]
claude = { mcp = { url = "https://mcp.posthog.com/mcp" }, why = "plugin adds ~30k tokens/session" }
codex  = { connector = "posthog@openai-curated-remote" }

[service.gmail]
codex  = { connector = "gmail@openai-curated-remote" }
claude = { gap = "no Claude connector while CLIProxyAPI auth is active" }

[service.zoom]
state = "removed"                      # removed from both harnesses on apply

[skills]
canonical = "~/.agents/skills"
packages  = [
  { source = "axiomhq/skills",    skills = ["axiom-sre", "axiom-alerting", "building-dashboards"] },
  { source = "mattpocock/skills", skills = ["codebase-design", "domain-modeling", "grilling"] },
]
repos = { "~/Code/acme/web" = "sync" }

[policy.argent]
claude_rule = "path-scoped"
codex_always_on = false

[proxy]
endpoint = "http://127.0.0.1:8317"
```

## Portability (open source)

- **Harness adapters.** Claude Code and Codex are the first two adapters. Each one knows its home directory, how it loads instructions, where its skills live, how MCP and plugins are configured, and how sign-in works. The engine detects which harnesses are installed and skips the rest. Cursor, Gemini CLI, OpenCode and Copilot CLI are detected today but not managed, and each can become an adapter later.
- **No hardcoded paths.** Tool homes follow each tool's own overrides (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `XDG_CONFIG_HOME`). User settings live in `~/.config/actl/config.toml` and are all optional.
- **Repo discovery** unions three sources:
  - common code folders that exist (`~/Code`, `~/Developer`, `~/Projects`, `~/src`, …) or the configured `scan.roots`
  - every project the installed harnesses have opened (Claude's project history and Codex's trusted projects), wherever it lives
  - optional workspace folders
- **Optional integrations.** Integrations such as CLIProxyAPI or Argent are off unless detected or enabled, and never required.
- **No bundled brand assets.** Service logos are resolved at runtime (see Service logos). The repo ships only our own icon and glyphs.
- **Install paths.**
  - From source: `git clone … && make install`. This needs Xcode 16+ and Bun at build time; the built app is self-contained.
  - Homebrew: a tap with a cask is the natural next step.
  - Signed builds: prebuilt downloads need a Developer ID signature and notarization, which requires a paid Apple Developer account. Until then, source builds avoid Gatekeeper quarantine because nothing is downloaded.
- **Privacy.** No telemetry and no network calls except those needed for health checks, sign-ins and logo fetches. Secrets never leave the engine process.

## Phases

1. **Engine.** Turn the collector into the `actl` CLI with a versioned JSON contract. Add the manifest (`adopt`, `validate`, `plan`, `apply`) and tests against fixture home directories.
2. **App shell.** Menu bar, main window, store, watchers, refresh schedule, notifications, login item, and `make install`.
3. **Screens.** Build the approved design, and add workflows in order of value: sign-in, review and apply, services, context budget, proxy, skills, instructions.
4. **Hardening.** Error states, an activity log, and a `/doctor prompt-audit` integration.

## Open decisions

- Is the TypeScript engine plus Swift UI split acceptable, or do you want pure Swift from the start?
- Should the manifest live at `~/.config/actl/` or in a git-tracked dotfiles repo? This is a per-user choice, so the path should be configurable.
- License (MIT proposed), project name, and repository (under the author's personal GitHub account).
- Which actions should apply with one click, and which need a review step? Proposed: sign-in and skills sync are one click; installs and removals go through Review changes.
