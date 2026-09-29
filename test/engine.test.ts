import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { type Fixture, makeFixture } from "./fixture";

let f: Fixture;
beforeEach(() => {
  f = makeFixture();
});
afterEach(() => f.cleanup());

const byId = (list: any[], id: string) => list.find((x) => x.id === id);

describe("envelope", () => {
  test("schema 2 with generatedAt", () => {
    const env = f.cli("services").json();
    expect(env.schema).toBe(2);
    expect(env.command).toBe("services");
    expect(Date.parse(env.generatedAt)).toBeGreaterThan(0);
  });

  test("unknown command fails on stderr with a non-zero exit", () => {
    const r = f.cli("nope");
    expect(r.code).not.toBe(0);
    expect(r.stderr).toStartWith("actl: ");
  });
});

describe("services", () => {
  test("groups plugins, MCP servers and connectors by service; skills-only plugins are excluded", () => {
    const services = f.data("services");
    expect(services.map((s: any) => s.id).sort()).toEqual(["acmedocs", "gmail", "linear", "meet", "oldwiki", "sentry"]);
    // writing-kit is skills-only, templates is an OpenAI-internal app: neither is a service
    expect(byId(services, "writingkit")).toBeUndefined();
    expect(byId(services, "templates")).toBeUndefined();

    const sentry = byId(services, "sentry");
    expect(sentry.providers.claude).toMatchObject({ kind: "plugin", ref: "sentry@claude-plugins-official", health: "needs-auth", serverName: "plugin:sentry:sentry", canSignIn: true, skills: ["sentry-debug"] });
    expect(sentry.providers.codex).toMatchObject({ kind: "mcp", ref: "sentry", auth: "oauth", contextTokens: 0 });
    // the utm tracking parameter is dropped from the lazy alternative
    expect(sentry.providers.claude.lazyAlternative).toMatchObject({ transport: "http", url: "https://mcp.sentry.dev/mcp", serverName: "sentry" });
    expect(sentry.providers.claude.contextEstimated).toBe(true);

    const meet = byId(services, "meet");
    expect(meet.providers.claude.health).toBe("failed");
    expect(meet.providers.claude.lazyAlternative).toBeUndefined(); // two servers, one needs an env token
  });

  test("brand color and logo come from the Codex plugin manifest", () => {
    const gmail = byId(f.data("services"), "gmail");
    expect(gmail.name).toBe("Gmail");
    expect(gmail.brandColor).toBe("#EA4335");
    expect(gmail.logo).toBe(join(f.home, ".codex/plugins/cache/openai-curated-remote/gmail/0.1.0/assets/gmail.png"));
    expect(gmail.providers.codex).toMatchObject({ kind: "connector", ref: "gmail@openai-curated-remote", auth: "chatgpt", canSignIn: false });
  });

  test("parity: both, only-claude, partial and gap", () => {
    const s = f.data("services");
    expect(byId(s, "sentry").parity).toBe("both");
    expect(byId(s, "acmedocs").parity).toBe("only-claude");
    expect(byId(s, "linear").parity).toBe("partial"); // plugin installed but disabled
    expect(byId(s, "linear").gapReason).toContain("disabled");
    expect(byId(s, "gmail").parity).toBe("gap"); // claude.ai connector blocked by proxy auth
    expect(byId(s, "gmail").gapReason).toContain("claude.ai connectors are disabled");
  });

  test("a manifest gap turns only-one-harness into an explained gap", () => {
    f.write(".config/actl/manifest.toml", `version = 1\n\n[service.acmedocs]\nclaude = { mcp = { name = "acme-docs", url = "https://mcp.acme.dev/mcp" } }\ncodex = { gap = "vendor has no Codex support yet" }\n`);
    const acme = byId(f.data("services"), "acmedocs");
    expect(acme.parity).toBe("gap");
    expect(acme.gapReason).toBe("vendor has no Codex support yet");
  });
});

describe("harnesses", () => {
  test("codes follow one rule and color slots are stable across runs", () => {
    const first = f.data("inventory").harnesses;
    expect(first.map((h: any) => h.code)).toEqual(["CC", "CX", "CU", "GM", "OC", "CP"]);
    expect(byId(first, "claude").colorSlot).toBe(0);
    expect(byId(first, "codex").colorSlot).toBe(1);
    const state = JSON.parse(f.read(".config/actl/state.json"));
    expect(state.colorSlots).toEqual({ claude: 0, codex: 1 });
    const second = f.data("inventory").harnesses;
    expect(second.map((h: any) => h.colorSlot)).toEqual(first.map((h: any) => h.colorSlot));
  });
});

describe("budget", () => {
  test("categories and levers per harness, estimates until costs are cached", () => {
    const b = f.data("budget");
    const claude = b.harnesses.claude;
    expect(claude.categories.map((c: any) => c.id)).toEqual(["plugins", "skills-listing", "instructions", "rules", "drift"]);
    expect(claude.total).toBe(claude.categories.reduce((n: number, c: any) => n + c.tokens, 0));
    const sentry = byId(claude.levers, "plugin:claude:sentry@claude-plugins-official");
    expect(sentry).toMatchObject({ kind: "plugin", action: "make-lazy", serviceId: "sentry", estimated: true });
    expect(byId(claude.levers, "plugin:claude:writing-kit@acme-tools").action).toBe("disable");
    // the always-on rule is a rescope lever; the path-scoped one costs nothing
    const mobile = byId(claude.levers, "rule:claude:~/.claude/rules/mobile.md");
    expect(mobile).toMatchObject({ kind: "rule", action: "rescope" });
    expect(claude.levers.some((l: any) => l.id.includes("scoped.md"))).toBe(false);
    // levers are ranked by tokens
    const tokens = claude.levers.map((l: any) => l.tokens);
    expect(tokens).toEqual([...tokens].sort((a: number, b: number) => b - a));
    expect(b.harnesses.codex.categories.find((c: any) => c.id === "rules").tokens).toBe(0);
  });

  test("plugin-costs refresh caches `claude plugin details` by id@version", () => {
    f.data("inventory");
    f.clearCalls();
    f.data("plugin-costs", "refresh");
    expect(f.calls()).toContain("claude plugin details sentry@claude-plugins-official");
    const cache = JSON.parse(f.read(".cache/actl/plugin-costs.json"));
    expect(cache.costs["sentry@claude-plugins-official@1.4.0"].tokens).toBe(1234);
    const lever = byId(f.data("budget").harnesses.claude.levers, "plugin:claude:sentry@claude-plugins-official");
    expect(lever).toMatchObject({ tokens: 1234, estimated: false });
    // cached ids are not fetched again
    f.clearCalls();
    f.data("plugin-costs", "refresh");
    expect(f.calls().filter((c) => c.includes("plugin details sentry"))).toHaveLength(0);
  });

  test("load preview: Claude order follows its loading rules", () => {
    const preview = f.data("budget", `--repo=${f.repo}/apps/site`).loadPreview;
    expect(preview.repo).toBe("~/Code/acme/web/apps/site");
    const claude = preview.harnesses.claude.files.map((x: any) => x.path);
    expect(claude).toEqual([
      "~/.claude/CLAUDE.md",
      "~/.claude/shared/extra.md", // @import, relative to the importing file
      "~/.claude/deeper.md", // second hop
      "~/.claude/rules/mobile.md", // no paths: frontmatter
      "~/Code/acme/web/CLAUDE.md",
      "~/Code/acme/web/AGENTS.md", // claude-md-and-agents-md
      "~/Code/acme/web/.claude/rules/style.md",
      "~/Code/acme/web/apps/site/AGENTS.md",
      "~/Code/acme/web/apps/site/CLAUDE.local.md",
    ]);
    expect(preview.harnesses.claude.files[1].reason).toBe("imported by ~/.claude/CLAUDE.md");
    expect(preview.harnesses.claude.total).toBe(preview.harnesses.claude.files.reduce((n: number, x: any) => n + x.tokens, 0));
  });

  test("load preview: claude-md-or-agents-md skips AGENTS.md when the project has a CLAUDE.md", () => {
    const s = JSON.parse(f.read(".claude/settings.json"));
    s.pluginConfigs["agents-md@builtin"].options.instructionFiles = "claude-md-or-agents-md";
    f.write(".claude/settings.json", JSON.stringify(s));
    const files = f.data("budget", `--repo=${f.repo}/apps/site`).loadPreview.harnesses.claude.files.map((x: any) => x.path);
    expect(files.some((p: string) => p.endsWith("AGENTS.md"))).toBe(false);
  });

  test("load preview: Codex reads its global file, then one AGENTS.md per directory from the git root", () => {
    const codex = f.data("budget", `--repo=${f.repo}/apps/site`).loadPreview.harnesses.codex.files;
    expect(codex.map((x: any) => x.path)).toEqual(["~/.codex/AGENTS.md", "~/Code/acme/web/AGENTS.md", "~/Code/acme/web/apps/site/AGENTS.md"]);
  });

  test("load preview: Codex override wins and the project-doc cap truncates, then skips", () => {
    f.write(".codex/AGENTS.override.md", "# Override\n");
    f.write(".codex/config.toml", `project_doc_max_bytes = 30\n`);
    const codex = f.data("budget", `--repo=${f.repo}/apps/site`).loadPreview.harnesses.codex.files;
    expect(codex[0]).toMatchObject({ path: "~/.codex/AGENTS.override.md", reason: "global override (AGENTS.override.md)" });
    expect(codex[1].reason).toContain("truncated");
    expect(codex[1].tokens).toBe(8); // 30 of its 39 bytes
    expect(codex[2]).toMatchObject({ tokens: 0 });
    expect(codex[2].reason).toContain("skipped");
  });
});

describe("manifest", () => {
  test("adopt writes the current state, never overwrites without --force, and show validates it", () => {
    const first = f.data("manifest", "adopt");
    expect(first.created).toBe(true);
    expect(first.path).toBe("~/.config/actl/manifest.toml");
    const text = f.read(".config/actl/manifest.toml");
    expect(text).toContain('[service.sentry]\nname = "Sentry"\nclaude = { plugin = "sentry@claude-plugins-official" }\ncodex = { mcp = { name = "sentry", url = "https://mcp.sentry.dev/mcp" } }');
    expect(text).toContain('claude = { plugin = "linear@claude-plugins-official", enabled = false }');
    expect(text).toContain('claude = { claudeai = "Gmail" }  # blocked while proxy or API-key auth is active');
    expect(text).toContain("# codex: not configured.");
    expect(text).toContain('instruction_files = "claude-md-and-agents-md"');
    expect(text).toContain('[policy.rules.scoped]\nfile = "~/.claude/rules/scoped.md"\npaths = ["**/*.swift"]');
    expect(text).toContain("# [policy.rules.mobile]"); // always-on rule: suggested, not asserted
    expect(text).not.toContain(f.home); // paths use ~

    const shown = f.data("manifest", "show");
    expect(shown).toMatchObject({ exists: true, errors: [] });
    expect(shown.manifest.service.sentry.claude.plugin).toBe("sentry@claude-plugins-official");

    f.write(".config/actl/manifest.toml", `${text}\n# my edit\n`);
    expect(f.data("manifest", "adopt").created).toBe(false);
    expect(f.read(".config/actl/manifest.toml")).toContain("# my edit");
    expect(f.data("manifest", "adopt", "--force").created).toBe(true);
    expect(f.read(".config/actl/manifest.toml")).not.toContain("# my edit");
  });

  test("an adopted manifest plans no service drift", () => {
    f.data("manifest", "adopt");
    const plan = f.data("plan");
    const drift = plan.actions.filter((a: any) => a.defaultSelected && a.group !== "skills");
    expect(drift).toEqual([]);
  });

  test("show reports validation errors", () => {
    f.write(".config/actl/manifest.toml", `version = 2\n[policy.claude]\ninstruction_files = "everything"\n[service.x]\nclaude = { plugin = "no-marketplace", gap = "both" }\ncodex = { claudeai = "Nope" }\n`);
    const shown = f.data("manifest", "show");
    expect(shown.errors).toEqual(expect.arrayContaining([
      expect.stringContaining("version must be 1"),
      expect.stringContaining("instruction_files"),
      expect.stringContaining("set exactly one of"),
      expect.stringContaining("use name@marketplace"),
      expect.stringContaining("claudeai: Claude only"),
    ]));
  });

  test("show without a manifest", () => {
    expect(f.data("manifest", "show")).toMatchObject({ exists: false, manifest: null, errors: [] });
  });
});

const PLAN_MANIFEST = `version = 1

[policy.claude]
instruction_files = "claude-md"

[policy.rules.mobile]
file = "~/.claude/rules/mobile.md"
paths = ["**/ios/**", "**/android/**"]

[service.sentry]
claude = { mcp = { name = "sentry", url = "https://mcp.sentry.dev/mcp" } }
codex = { mcp = { name = "sentry", url = "https://mcp.sentry.dev/mcp" } }

[service.linear]
claude = { plugin = "linear@claude-plugins-official" }

[service.writingkit]
claude = { plugin = "writing-kit@acme-tools", enabled = false }

[service.acmekit]
claude = { plugin = "acme-kit@acme-tools" }
codex = { connector = "acme-kit@openai-curated-remote" }

[service.acmedocs]
claude = { mcp = { name = "acme-docs", url = "https://mcp.acme.dev/mcp" } }
codex = { mcp = { name = "acme-docs", url = "https://mcp.acme.dev/mcp" } }

[service.oldwiki]
state = "removed"

[service.gmail]
codex = { removed = true }
`;

describe("plan", () => {
  test("diffs the manifest into every supported kind with stable ids", () => {
    f.write(".config/actl/manifest.toml", PLAN_MANIFEST);
    f.write(".cache/actl/proxy.json", JSON.stringify({ listening: true, endpoint: "127.0.0.1:8317", installedVersion: "6.1.0", latestVersion: "6.2.0", versionSource: "brew", accounts: [] }));
    const plan = f.data("plan");
    expect(plan.manifestExists).toBe(true);
    expect(plan.manifestErrors).toEqual([]);
    const ids = plan.actions.map((a: any) => a.id).sort();
    expect(ids).toEqual([
      "instructions.mode:claude",
      "mcp.add:codex:acmedocs",
      "mcp.remove:claude:oldwiki",
      "plugin.disable:claude:writingkit",
      "plugin.enable:claude:linear",
      "plugin.install:claude:acmekit",
      "plugin.install:codex:acmekit",
      "plugin.uninstall:codex:gmail",
      "proxy.update",
      "rule.rescope:claude:mobile",
      "service.make-lazy:claude:sentry",
      "skills.resolve-conflict:user:tidy",
      "skills.sync:user",
    ]);
    const lazy = byId(plan.actions, "service.make-lazy:claude:sentry");
    expect(lazy).toMatchObject({ kind: "service.make-lazy", group: "services", harness: "claude", reversible: true, defaultSelected: true });
    expect(lazy.tokensDelta).toBeLessThan(0);
    const rescope = byId(plan.actions, "rule.rescope:claude:mobile");
    expect(rescope.diff.path).toBe("~/.claude/rules/mobile.md");
    expect(rescope.diff.after).toStartWith('---\npaths:\n  - "**/ios/**"\n  - "**/android/**"\n---\n# Mobile rule');
    expect(rescope.tokensDelta).toBeLessThan(0);
    const conflict = byId(plan.actions, "skills.resolve-conflict:user:tidy");
    expect(conflict.requiresChoice.options.map((o: any) => o.id)).toEqual(["use-canonical", "keep-edit"]);
    expect(conflict.defaultSelected).toBe(false);
    expect(byId(plan.actions, "proxy.update")).toMatchObject({ reversible: false, defaultSelected: false });
    expect(byId(plan.actions, "mcp.remove:claude:oldwiki").reversible).toBe(true);
    expect(plan.summary.count).toBe(ids.length);
    expect(plan.summary.tokensDelta.claude).toBeLessThan(0);
    // ids are stable for identical drift
    expect(f.data("plan").actions.map((a: any) => a.id).sort()).toEqual(ids);
  });

  test("without a manifest, only suggestions and skills drift; plan is read-only", () => {
    const plan = f.data("plan");
    expect(plan.manifestExists).toBe(false);
    expect(byId(plan.actions, "service.make-lazy:claude:sentry")).toMatchObject({ defaultSelected: false });
    expect(byId(plan.actions, "service.make-lazy:claude:sentry").detail).toStartWith("Suggestion.");
    const writes = f.calls().filter((c) => /mcp (add|remove)|plugin (install|uninstall|enable|disable)/.test(c));
    expect(writes).toEqual([]);
    expect(f.exists(".config/actl/backups")).toBe(false);
  });
});

describe("apply and undo", () => {
  test("apply backs up files, runs harness CLIs, records activity; undo reverses it", () => {
    f.write(".config/actl/manifest.toml", PLAN_MANIFEST);
    const ruleBefore = f.read(".claude/rules/mobile.md");
    f.clearCalls();
    const r = f.cli("apply", "rule.rescope:claude:mobile", "service.make-lazy:claude:sentry", "mcp.add:codex:acmedocs", "skills.sync:user");
    expect(r.code).toBe(0);
    const events = r.lines();
    expect(events[0]).toMatchObject({ type: "start", actions: ["rule.rescope:claude:mobile", "service.make-lazy:claude:sentry", "mcp.add:codex:acmedocs", "skills.sync:user"] });
    const backup = events.find((e: any) => e.type === "backup");
    expect(backup.files).toEqual(expect.arrayContaining(["~/.claude/rules/mobile.md", "~/.claude/skills/grill", "~/.claude/skills/.actl-sync.json"]));
    expect(backup.dir).toStartWith("~/.config/actl/backups/");
    expect(events.at(-1)).toMatchObject({ type: "done", ok: 4, failed: 0 });
    expect(events.filter((e: any) => e.type === "step" && e.state === "ok")).toHaveLength(4);
    const runId = events[0].runId;

    expect(f.read(".claude/rules/mobile.md")).toStartWith("---\npaths:\n");
    expect(f.exists(".claude/skills/grill/SKILL.md")).toBe(true);
    expect(f.calls()).toEqual(expect.arrayContaining([
      "claude plugin disable sentry@claude-plugins-official -s user",
      "claude mcp add -s user -t http sentry https://mcp.sentry.dev/mcp",
      "codex mcp add acme-docs --url https://mcp.acme.dev/mcp",
    ]));
    const runDir = join(f.home, ".config/actl/backups", runId);
    expect(readFileSync(join(runDir, "files", "0"), "utf8")).toBe(ruleBefore);

    const activity = f.data("activity");
    expect(activity[0]).toMatchObject({ runId, source: "user", undoable: true });
    expect(activity[0].actions.map((a: any) => a.state)).toEqual(["ok", "ok", "ok", "ok"]);

    f.clearCalls();
    const u = f.cli("undo", runId);
    expect(u.code).toBe(0);
    const uev = u.lines();
    expect(uev.at(-1)).toMatchObject({ type: "done", ok: 4, failed: 0 });
    expect(f.read(".claude/rules/mobile.md")).toBe(ruleBefore);
    expect(f.exists(".claude/skills/grill")).toBe(false);
    // inverse commands run in reverse order
    expect(f.calls()).toEqual(["codex mcp remove acme-docs", "claude mcp remove -s user sentry", "claude plugin enable sentry@claude-plugins-official -s user"]);

    const after = f.data("activity");
    expect(after[0].undoOf).toBe(runId);
    expect(byId(after.map((a: any) => ({ ...a, id: a.runId })), runId)).toMatchObject({ undoable: false });
    expect(byId(after.map((a: any) => ({ ...a, id: a.runId })), runId).undoneAt).toBeTruthy();
    // a run can be undone only once
    const again = f.cli("undo", runId);
    expect(again.code).not.toBe(0);
    expect(again.lines()[0]).toMatchObject({ type: "error" });
  });

  test("make-lazy from a suggestion keeps an adopted manifest truthful", () => {
    f.data("manifest", "adopt");
    const r = f.cli("apply", "service.make-lazy:claude:sentry");
    expect(r.code).toBe(0);
    const text = f.read(".config/actl/manifest.toml");
    expect(text).toContain('claude = { mcp = { name = "sentry", url = "https://mcp.sentry.dev/mcp" }, why = "made lazy by actl');
    expect(f.data("manifest", "show").errors).toEqual([]);
    expect(r.lines().find((e: any) => e.type === "backup").files).toContain("~/.config/actl/manifest.toml");
  });

  test("a failed step rolls back the action's earlier steps", () => {
    f.write(".config/actl/manifest.toml", PLAN_MANIFEST);
    f.stub("claude", "mcp add -s user -t http sentry https://mcp.sentry.dev/mcp", "Error: server exists\n", 1);
    f.clearCalls();
    const r = f.cli("apply", "service.make-lazy:claude:sentry");
    expect(r.code).toBe(1);
    const step = r.lines().find((e: any) => e.type === "step" && e.state === "failed");
    expect(step.message).toContain("rolled back");
    const writes = f.calls().filter((c) => /mcp (add|remove)|plugin (enable|disable)/.test(c));
    expect(writes).toEqual(["claude plugin disable sentry@claude-plugins-official -s user", "claude mcp add -s user -t http sentry https://mcp.sentry.dev/mcp", "claude plugin enable sentry@claude-plugins-official -s user"]);
    expect(f.data("activity")[0]).toMatchObject({ undoable: false });
  });

  test("a skill conflict needs a choice, then resolves either way", () => {
    const skipped = f.cli("apply", "skills.resolve-conflict:user:tidy").lines();
    expect(skipped.find((e: any) => e.type === "step")).toMatchObject({ state: "skipped" });
    expect(f.read(".claude/skills/tidy/SKILL.md")).toContain("edited by hand");

    const r = f.cli("apply", "skills.resolve-conflict:user:tidy=keep-edit");
    expect(r.code).toBe(0);
    expect(f.read(".agents/skills/tidy/SKILL.md")).toContain("edited by hand");
    const runId = r.lines()[0].runId;
    expect(f.cli("undo", runId).code).toBe(0);
    expect(f.read(".agents/skills/tidy/SKILL.md")).toContain("canonical v2");

    expect(f.cli("apply", "skills.resolve-conflict:user:tidy=use-canonical").code).toBe(0);
    expect(f.read(".claude/skills/tidy/SKILL.md")).toContain("canonical v2");
    expect(f.data("plan").actions.some((a: any) => a.kind === "skills.resolve-conflict")).toBe(false);
  });

  test("unknown ids are skipped and --all applies only default-selected actions", () => {
    const r = f.cli("apply", "mcp.add:claude:nothing");
    expect(r.lines().find((e: any) => e.type === "step")).toMatchObject({ actionId: "mcp.add:claude:nothing", state: "skipped" });
    f.clearCalls();
    const all = f.cli("apply", "--all").lines();
    // no manifest: make-lazy suggestions are not default-selected, skills sync is
    expect(all[0].actions).toEqual(["skills.sync:user"]);
    expect(f.calls().filter((c) => c.includes("plugin disable"))).toEqual([]);
  });

  test("apply with nothing named is an error", () => {
    const r = f.cli("apply");
    expect(r.code).not.toBe(0);
    expect(r.stderr).toContain("usage");
  });
});

describe("status", () => {
  test("without an inventory cache it is stale and says so, quickly", () => {
    const t = performance.now();
    const s = f.data("status");
    expect(performance.now() - t).toBeLessThan(1000);
    expect(s.stale).toBe(true);
    expect(s.attention[0]).toMatchObject({ id: "inventory.missing", kind: "sync" });
    expect(s.harnesses.map((h: any) => h.id)).toEqual(["claude", "codex"]);
    expect(f.calls()).toEqual([]); // no harness CLI on the hot path
  });

  test("from the cache: counts, sign-in queue, failures, drift and proxy accounts", () => {
    f.data("inventory");
    f.write(".config/actl/manifest.toml", PLAN_MANIFEST);
    const future = new Date(Date.now() + 3_600_000).toISOString();
    f.write(".cache/actl/proxy.json", JSON.stringify({ listening: true, accounts: [{ email: "a***@example.com", provider: "claude", nextRetryAfter: future }, { label: "team", provider: "codex" }] }));
    f.clearCalls();
    const s = f.data("status");
    expect(f.calls()).toEqual([]);
    expect(s.stale).toBe(false);
    expect(s.level).toBe("error");
    const claude = byId(s.harnesses, "claude");
    expect(claude).toMatchObject({ total: 5, failed: 1, needsSignIn: 1 });
    expect(byId(s.attention, "sign-in:claude").fix.signIn).toEqual({ harness: "claude", servers: ["plugin:sentry:sentry"] });
    expect(byId(s.attention, "sign-in:codex").fix.signIn).toEqual({ harness: "codex", servers: ["linear"] });
    expect(byId(s.attention, "failed:claude:meet")).toMatchObject({ severity: "error", kind: "failed" });
    expect(byId(s.attention, "drift:rule:mobile").fix.actionIds).toEqual(["rule.rescope:claude:mobile"]);
    expect(byId(s.attention, "drift:instructions-mode").fix.actionIds).toEqual(["instructions.mode:claude"]);
    expect(s.proxy.accounts).toEqual([{ label: "a***@example.com", state: "cooldown", retryAt: future }, { label: "team", state: "active" }]);
    expect(byId(s.attention, "quota:a***@example.com").severity).toBe("warn");
  });
});

describe("login", () => {
  test("--json emits opening, waiting and done using the harness CLI under a PTY", () => {
    f.data("inventory");
    const events = f.cli("login", "claude", "plugin:sentry:sentry", "--json").lines();
    expect(events.map((e: any) => e.type)).toEqual(["opening", "waiting", "done"]);
    expect(events[2]).toMatchObject({ harness: "claude", server: "plugin:sentry:sentry", ok: true });
    expect(f.calls()).toContain("claude mcp login plugin:sentry:sentry");
  });

  test("--json refuses names that aren't sign-in targets", () => {
    f.data("inventory");
    const r = f.cli("login", "claude", "not-a-server", "--json");
    expect(r.code).toBe(1);
    expect(r.lines()[0]).toMatchObject({ type: "done", ok: false });
    expect(f.calls().some((c) => c.includes("mcp login"))).toBe(false);
  });
});

describe("inventory cache and web server", () => {
  test("inventory fills uncached plugin costs in the background", async () => {
    const env = { ...f.env, ACTL_NO_BACKGROUND: "0" };
    const p = Bun.spawnSync(["bun", join(import.meta.dir, "../src/actl.ts"), "inventory"], { env, stdout: "pipe" });
    expect(p.exitCode).toBe(0);
    const costs = join(f.home, ".cache/actl/plugin-costs.json");
    for (let i = 0; i < 100 && !existsSync(costs); i++) await Bun.sleep(100);
    expect(JSON.parse(readFileSync(costs, "utf8")).costs["sentry@claude-plugins-official@1.4.0"].tokens).toBe(1234);
  });

  test("inventory writes the cache that status reads", () => {
    f.data("inventory");
    const cached = JSON.parse(f.read(".cache/actl/inventory.json"));
    expect(cached.services.length).toBe(6);
    expect(cached.budget.harnesses.claude.total).toBeGreaterThan(0);
    expect(existsSync(join(f.home, ".cache/actl/inventory.json.lock"))).toBe(false);
  });

  test("/api/inventory still serves the collect shape plus the new models", async () => {
    const port = 4800 + Math.floor(Math.random() * 500);
    const proc = Bun.spawn(["bun", join(import.meta.dir, "../src/server.ts")], { env: { ...f.env, ACTL_PORT: String(port) }, stdout: "pipe", stderr: "pipe" });
    try {
      let res: Response | undefined;
      for (let i = 0; i < 50 && !res; i++) {
        try {
          res = await fetch(`http://127.0.0.1:${port}/api/inventory`);
        } catch {
          await Bun.sleep(100);
        }
      }
      const inv = (await res!.json()) as any;
      for (const k of ["repos", "instructions", "skills", "plugins", "mcp", "findings", "harnesses", "services", "budget"]) expect(inv).toHaveProperty(k);
      expect((await fetch(`http://127.0.0.1:${port}/api/inventory`, { headers: { Host: "evil.example" } })).status).toBe(403);
    } finally {
      proc.kill();
    }
  }, 20_000);
});

describe("logos", () => {
  test("refresh fetches the apple-touch-icon from a homepage and services pick it up", async () => {
    const png = new Uint8Array([137, 80, 78, 71]);
    const server = Bun.serve({
      port: 0,
      fetch(req) {
        const path = new URL(req.url).pathname;
        if (path === "/") return new Response('<html><head><link rel="icon" href="/small.ico"><link rel="apple-touch-icon" sizes="180x180" href="/touch.png"></head></html>', { headers: { "content-type": "text/html" } });
        if (path === "/touch.png") return new Response(png, { headers: { "content-type": "image/png" } });
        return new Response("no", { status: 404 });
      },
    });
    try {
      const script = `import { refreshLogos } from ${JSON.stringify(join(import.meta.dir, "../src/logos.ts"))};
        console.log(JSON.stringify(await refreshLogos([{ id: "acmedocs", homepage: "http://127.0.0.1:${server.port}/" }, { id: "gmail", homepage: "https://example.invalid", logo: "/x.png" }])));`;
      // Async spawn: the icon server runs in this process and must keep serving while the child fetches.
      const runScript = async () => JSON.parse(await new Response(Bun.spawn(["bun", "-e", script], { env: f.env, stdout: "pipe", stderr: "inherit" }).stdout).text());
      const results = await runScript();
      expect(results[0]).toMatchObject({ id: "acmedocs", state: "fetched", source: `http://127.0.0.1:${server.port}/touch.png` });
      expect(results[1].state).toBe("skipped"); // has a plugin-manifest logo
      const file = join(f.home, "Library/Caches/actl/logos/acmedocs.png");
      expect(readFileSync(file)).toEqual(Buffer.from(png));
      expect(byId(f.data("services"), "acmedocs").logo).toBe(file);
      // within 30 days it is served from cache
      const again = await runScript();
      expect(again[0].state).toBe("cached");
      expect(readdirSync(join(f.home, "Library/Caches/actl/logos")).sort()).toEqual(["acmedocs.png", "index.json"]);
    } finally {
      server.stop(true);
    }
  });
});
