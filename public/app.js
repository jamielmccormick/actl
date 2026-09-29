// actl front end. Vanilla JS, no build step.
// Reads /api/inventory (see src/collect.ts for the shape) and /api/cliproxy (src/cliproxy.ts)
// and renders six tabs.
(() => {
  "use strict";

  const TABS = ["overview", "mcp", "skills", "instructions", "plugins", "proxy"];
  const $ = (sel, el = document) => el.querySelector(sel);
  const main = $("#main");
  const searchEl = $("#search");
  const refreshBtn = $("#refresh");
  const toastEl = $("#toast");

  const state = {
    inv: null,
    tab: tabFromHash(),
    query: "",
    skillFilters: { source: "", mode: "" }, // mode: "" | claude-only | codex-only | both | broken
    expanded: new Set(), // keys of expanded rows
    proxy: null, // /api/cliproxy snapshot
    proxyError: "",
  };

  // ---------- utilities ----------

  function esc(s) {
    return String(s ?? "")
      .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;").replace(/'/g, "&#39;");
  }
  function tabFromHash() {
    const h = location.hash.replace(/^#/, "");
    return TABS.includes(h) ? h : "overview";
  }
  function fmtAgo(iso) {
    const ms = Date.now() - new Date(iso).getTime();
    if (!Number.isFinite(ms) || ms < 0) return "just now";
    const s = Math.round(ms / 1000);
    if (s < 45) return "just now";
    const m = Math.round(s / 60);
    if (m < 60) return `${m}m ago`;
    const h = Math.round(m / 60);
    if (h < 48) return `${h}h ago`;
    return `${Math.round(h / 24)}d ago`;
  }
  function kb(bytes) {
    return `${(bytes / 1024).toFixed(1)} KB`;
  }
  function matches(q, ...fields) {
    if (!q) return true;
    return fields.some((f) => f && String(f).toLowerCase().includes(q));
  }
  function hl(text) {
    // Highlight the current query inside already-escaped text.
    const t = esc(text);
    if (!state.query) return t;
    const re = new RegExp(state.query.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"), "ig");
    return t.replace(re, (m) => `<mark>${m}</mark>`);
  }
  function toast(msg) {
    toastEl.textContent = msg;
    toastEl.classList.add("show");
    clearTimeout(toast.t);
    toast.t = setTimeout(() => toastEl.classList.remove("show"), 1400);
  }
  function badge(kind, label, title) {
    return `<span class="badge ${kind}" ${title ? `title="${esc(title)}"` : ""}><span class="dot"></span>${esc(label)}</span>`;
  }
  function tick(yes, label) {
    return `<span class="tick ${yes ? "yes" : "no"}" aria-label="${yes ? "yes" : "no"}" title="${esc(label || "")}">${yes ? "✓" : "–"}</span>`;
  }
  function cmd(text) {
    return `<span class="cmd"><code title="${esc(text)}">${esc(text)}</code><button type="button" data-copy="${esc(text)}" title="Copy">copy</button></span>`;
  }
  function emptyRow(cols, msg) {
    return `<tr><td colspan="${cols}" class="empty">${esc(msg)}</td></tr>`;
  }

  // ---------- header ----------

  function renderHeader() {
    const inv = state.inv;
    const c = $("#collected");
    if (!inv) return;
    c.textContent = `collected ${fmtAgo(inv.generatedAt)}`;
    c.title = `${new Date(inv.generatedAt).toLocaleString()} · took ${(inv.tookMs / 1000).toFixed(1)}s`;
    $("#versions").innerHTML =
      `<span><b>Claude</b>${esc(inv.versions.claude || "not found")}</span>` +
      `<span><b>Codex</b>${esc(inv.versions.codex || "not found")}</span>`;
    for (const b of document.querySelectorAll("#tabs button")) {
      b.setAttribute("aria-selected", String(b.dataset.tab === state.tab));
    }
  }

  // ---------- overview ----------

  function renderOverview() {
    const inv = state.inv;
    const q = state.query;
    const visClaude = inv.skills.filter((s) => s.visibleIn.claude).length;
    const visCodex = inv.skills.filter((s) => s.visibleIn.codex).length;
    const stats = [
      ["Repos & workspaces", inv.repos.length, `${inv.repos.filter((r) => r.kind === "repo").length} repos`, "instructions"],
      ["Instruction files", inv.instructions.length, `${inv.instructions.filter((i) => i.shimOnlyImportsAgents).length} shims`, "instructions"],
      ["Skills visible in Claude", visClaude, `${inv.skills.length} entries total`, "skills"],
      ["Skills visible in Codex", visCodex, `${inv.skills.filter((s) => s.broken).length} broken links`, "skills"],
      ["MCP servers", inv.mcp.rows.length, `${inv.mcp.rows.filter((r) => r.claude?.status === "connected").length} connected in Claude`, "mcp"],
      ["Plugins", inv.plugins.claude.length + inv.plugins.codex.length, `${inv.plugins.claude.length} Claude · ${inv.plugins.codex.length} Codex`, "plugins"],
    ];
    const findings = [...inv.findings, ...proxyFindings()].filter((f) => matches(q, f.title, f.detail, f.fix, f.area, ...(f.items || [])));
    const groups = [
      ["error", "Errors"],
      ["warn", "Warnings"],
      ["info", "Info"],
    ];
    let html = `<div class="stats">${stats
      .map(([l, v, sub, tab]) => `<button class="stat" type="button" data-goto="${tab}"><div class="label">${esc(l)}</div><div class="value">${v}</div><div class="sub">${esc(sub)}</div></button>`)
      .join("")}</div>`;
    for (const [sev, label] of groups) {
      const list = findings.filter((f) => f.severity === sev);
      if (!list.length) continue;
      html += `<div class="section"><div class="section-head"><h2>${label}</h2><span class="count small">${list.length}</span></div>`;
      html += list
        .map((f, i) => {
          const key = `f:${sev}:${i}:${f.title}`;
          const items = (f.items || []).filter((it) => !q || matches(q, it, f.title, f.detail));
          return `<div class="finding ${sev}">
            <div class="finding-head">${badge(sev === "error" ? "err" : sev, sev)}<span class="chip">${esc(f.area)}</span><span class="finding-title">${hl(f.title)}</span></div>
            <div class="finding-detail">${hl(f.detail)}</div>
            ${f.fix ? `<div class="finding-fix"><b>Fix</b>${hl(f.fix)}</div>` : ""}
            ${
              f.items?.length
                ? `<details ${state.expanded.has(key) ? "open" : ""} data-key="${esc(key)}"><summary>${f.items.length} item${f.items.length === 1 ? "" : "s"}</summary><ul class="mono">${items.map((it) => `<li>${hl(it)}</li>`).join("")}</ul></details>`
                : ""
            }
          </div>`;
        })
        .join("");
      html += `</div>`;
    }
    if (!findings.length) html += `<div class="empty">${inv.findings.length ? "No findings match the search." : "No findings. Everything looks consistent."}</div>`;
    return html;
  }

  // ---------- MCP ----------

  const CLAUDE_STATUS = {
    connected: ["ok", "connected"],
    failed: ["err", "failed"],
    "needs-auth": ["warn", "needs auth"],
    blocked: ["block", "blocked"],
    pending: ["info", "pending"],
    unknown: ["", "unknown"],
  };

  // ---------- MCP sign-in ----------

  const loginJobs = { list: [], timer: null };

  function loginButton(tool, name, label) {
    const running = loginJobs.list.some((j) => j.tool === tool && j.name === name && j.status === "running");
    return `<button type="button" class="btn-inline" data-login-tool="${esc(tool)}" data-login-name="${esc(name)}" ${running ? "disabled" : ""}>${running ? "Waiting for browser…" : esc(label)}</button>`;
  }

  function renderLoginJobs() {
    const recent = loginJobs.list.filter((j) => j.status === "running" || Date.now() - Date.parse(j.endedAt || j.startedAt) < 10 * 60_000);
    if (!recent.length) return "";
    const label = { running: ["info", "waiting for browser"], succeeded: ["ok", "signed in"], failed: ["err", "failed"], "timed-out": ["warn", "timed out"] };
    return `<div class="notice"><span class="icon">↪</span><div><b>Sign-ins</b> ${recent
      .map((j) => `<span class="chips">${badge(...label[j.status])} <code>${esc(j.tool)} · ${esc(j.name)}</code></span>`)
      .join(" ")}<div class="small dim">A browser tab opens for each sign-in. Finish it there; this page updates on its own.</div></div></div>`;
  }

  async function pollLoginJobs() {
    try {
      const res = await fetch("/api/actions/jobs");
      const prev = new Map(loginJobs.list.map((j) => [j.id, j.status]));
      loginJobs.list = await res.json();
      const finished = loginJobs.list.filter((j) => prev.get(j.id) === "running" && j.status !== "running");
      const running = loginJobs.list.some((j) => j.status === "running");
      if (finished.length) {
        for (const j of finished) toast(`${j.tool} · ${j.name}: ${j.status}`);
        await load(true);
      } else if (state.tab === "mcp") render();
      clearTimeout(loginJobs.timer);
      if (running) loginJobs.timer = setTimeout(pollLoginJobs, 2000);
    } catch {}
  }

  async function startLogin(tool, name) {
    const res = await fetch("/api/actions/mcp-login", {
      method: "POST",
      headers: { "content-type": "application/json", "x-actl": "1" },
      body: JSON.stringify({ tool, name }),
    });
    const body = await res.json().catch(() => ({}));
    if (!res.ok) return toast(body.error || `Sign-in failed to start (HTTP ${res.status})`);
    toast(`Opening sign-in for ${name}…`);
    await pollLoginJobs();
  }

  function mcpCommands(r) {
    const out = [];
    const cleanName = /^claude\.ai\s+/i.test(r.name) ? r.name.replace(/^claude\.ai\s+/i, "").toLowerCase() : r.name.replace(/^plugin:[^:]+:/, "");
    const isUrl = /^https?:\/\//.test(r.target);
    const missingFromClaude = !r.claude || r.claude.scope === "claude.ai";
    if (r.codex?.auth === "o_auth" && missingFromClaude && isUrl) {
      out.push(`claude mcp add --transport http ${cleanName} ${r.target} -s user`);
    }
    if (r.claude?.status === "needs-auth" && r.claude.serverName) out.push(`claude mcp login ${r.claude.serverName}`);
    if (r.codex?.auth === "o_auth") out.push(`codex mcp login ${r.codex.serverName || cleanName}`);
    return out;
  }

  function renderMcp() {
    const inv = state.inv;
    const q = state.query;
    const rows = inv.mcp.rows.filter((r) => matches(q, r.name, r.target, r.claude?.status, r.claude?.detail, r.codex?.auth, r.codex?.transport, ...r.notes));
    let html = renderLoginJobs();
    if (inv.mcp.connectorsBlocked) {
      html += `<div class="notice"><span class="icon">!</span><div><b>claude.ai connectors are disabled in Claude Code.</b> The CLIProxyAPI auth token (<code>ANTHROPIC_AUTH_TOKEN</code>/<code>ANTHROPIC_BASE_URL</code>) takes precedence over the claude.ai login, so connectors configured on claude.ai never load here. Add the ones you need as direct MCP servers instead (they do their own OAuth).</div></div>`;
    }
    html += `<div class="section"><div class="section-head"><h2>Servers</h2><span class="count small">${rows.length} of ${inv.mcp.rows.length}</span><span class="dim small">rows highlighted in amber exist in only one tool</span></div>
      <div class="card table-wrap"><table class="grid"><colgroup><col class="c-name"><col class="c-target"><col class="c-claude"><col class="c-codex"><col class="c-cmds"></colgroup><thead><tr>
        <th>Server</th><th>Target</th><th>Claude Code</th><th>Codex</th><th>Commands</th>
      </tr></thead><tbody>`;
    if (!rows.length) html += emptyRow(5, "No MCP servers match.");
    for (const r of rows) {
      const inClaude = !!r.claude;
      const inCodex = !!r.codex;
      const onlyOne = inClaude !== inCodex;
      const onlyLabel = onlyOne ? (inClaude ? "Claude only" : "Codex only") : "";
      let claudeCell = `<span class="dim">–</span>`;
      if (r.claude) {
        const [k, l] = CLAUDE_STATUS[r.claude.status] || ["", r.claude.status];
        const canSignIn = r.claude.status === "needs-auth" && r.claude.scope !== "claude.ai" && r.claude.serverName;
        claudeCell = `<div class="cell-stack">${badge(k, l, r.claude.detail)}<span class="cell-sub">${esc(r.claude.scope)}${r.claude.detail && r.claude.detail.toLowerCase() !== l ? ` · ${esc(r.claude.detail)}` : ""}</span>${canSignIn ? loginButton("claude", r.claude.serverName, "Sign in") : ""}</div>`;
      }
      let codexCell = `<span class="dim">–</span>`;
      if (r.codex) {
        const authKind = r.codex.auth === "o_auth" ? "info" : r.codex.auth === "unsupported" ? "" : "warn";
        const codexAction =
          r.codex.auth === "o_auth" && r.codex.serverName
            ? loginButton("codex", r.codex.serverName, "Re-authenticate")
            : r.codex.auth === "chatgpt-connector"
              ? `<span class="cell-sub">sign-in managed in ChatGPT → Settings → Connectors</span>`
              : "";
        codexCell = `<div class="cell-stack"><div class="chips">${r.codex.enabled ? badge("ok", "enabled") : badge("err", "disabled")}${badge(authKind, `auth: ${r.codex.auth ?? "unknown"}`)}</div><span class="cell-sub">${esc(r.codex.transport || "")}</span>${codexAction}</div>`;
      }
      const cmds = mcpCommands(r);
      html += `<tr class="row ${onlyOne ? "only-one" : ""}">
        <td><div class="cell-stack"><span class="name">${hl(r.name)}</span>${onlyLabel ? `<span class="cell-sub">${badge("warn", onlyLabel)}</span>` : ""}${r.notes.map((n) => `<span class="cell-sub">${badge("warn", "fragile path", n)}</span>`).join("")}</div></td>
        <td class="mono desc">${hl(r.target)}</td>
        <td>${claudeCell}</td>
        <td>${codexCell}</td>
        <td>${cmds.length ? `<div class="cmds">${cmds.map(cmd).join("")}</div>` : `<span class="dim">–</span>`}</td>
      </tr>`;
    }
    html += `</tbody></table></div></div>`;

    const pm = inv.mcp.projectMcp.filter((p) => matches(q, p.repo, ...p.servers, ...p.codex));
    html += `<div class="section"><div class="section-head"><h2>Repo-scoped servers</h2><span class="count small">${pm.length}</span><span class="dim small">.mcp.json (Claude) and .codex/config.toml (Codex) inside each repo</span></div>`;
    if (!pm.length) html += `<div class="empty">No repo-scoped MCP servers.</div>`;
    else {
      html += `<div class="card table-wrap"><table class="grid"><thead><tr><th>Repo</th><th>Claude (.mcp.json)</th><th>Codex (.codex/config.toml)</th></tr></thead><tbody>`;
      for (const p of pm) {
        html += `<tr class="row"><td class="name">${hl(p.repo)}</td><td><div class="chips">${p.servers.length ? p.servers.map((s) => `<span class="chip claude">${hl(s)}</span>`).join("") : `<span class="dim">–</span>`}</div></td><td><div class="chips">${p.codex.length ? p.codex.map((s) => `<span class="chip codex">${hl(s)}</span>`).join("") : `<span class="dim">–</span>`}</div></td></tr>`;
      }
      html += `</tbody></table></div>`;
    }
    html += `</div>`;
    return html;
  }

  // ---------- skills ----------

  const SOURCE_LABEL = {
    "claude-user": "~/.claude/skills",
    "codex-user": "~/.codex/skills",
    "agents-user": "~/.agents/skills",
    "claude-project": "repo .claude/skills",
    "agents-project": "repo .agents/skills",
    "claude-plugin": "Claude plugin",
    "codex-plugin": "Codex plugin",
  };
  const sourceTool = (s) => (s.startsWith("claude") ? "claude" : "codex");

  let skillGroupsCache = null;
  function skillGroups() {
    if (skillGroupsCache) return skillGroupsCache;
    const map = new Map();
    for (const s of state.inv.skills) {
      let g = map.get(s.name);
      if (!g) map.set(s.name, (g = { name: s.name, entries: [] }));
      g.entries.push(s);
    }
    const groups = [...map.values()].map((g) => {
      const e = g.entries;
      g.claude = e.some((s) => s.visibleIn.claude);
      g.codex = e.some((s) => s.visibleIn.codex);
      g.broken = e.some((s) => s.broken);
      g.pinned = e.some((s) => s.pinnedToCodexPluginVersion && !s.broken);
      g.disabled = e.some((s) => s.codexDisabled);
      g.sources = [...new Set(e.map((s) => s.source))];
      g.owners = [...new Set(e.map((s) => s.owner))];
      g.description = e.map((s) => s.description).find(Boolean) || "";
      return g;
    });
    groups.sort((a, b) => a.name.localeCompare(b.name, undefined, { sensitivity: "base" }));
    return (skillGroupsCache = groups);
  }

  function renderSkills() {
    const q = state.query;
    const f = state.skillFilters;
    const all = skillGroups();
    const sources = [...new Set(state.inv.skills.map((s) => s.source))].sort();
    const groups = all.filter((g) => {
      if (f.source && !g.sources.includes(f.source)) return false;
      if (f.mode === "claude-only" && !(g.claude && !g.codex)) return false;
      if (f.mode === "codex-only" && !(g.codex && !g.claude)) return false;
      if (f.mode === "both" && !(g.claude && g.codex)) return false;
      if (f.mode === "broken" && !g.broken) return false;
      return matches(q, g.name, g.description, ...g.sources, ...g.owners, ...g.entries.map((e) => e.path), ...g.entries.map((e) => e.dirName));
    });
    const modes = [
      ["", "All"],
      ["both", "In both"],
      ["claude-only", "Only in Claude"],
      ["codex-only", "Only in Codex"],
      ["broken", "Broken"],
    ];
    let html = `<div class="toolbar">
      <select class="select" id="skill-source"><option value="">All sources</option>${sources.map((s) => `<option value="${s}" ${f.source === s ? "selected" : ""}>${esc(SOURCE_LABEL[s] || s)} (${state.inv.skills.filter((x) => x.source === s).length})</option>`).join("")}</select>
      ${modes.map(([v, l]) => `<button type="button" class="pill" data-mode="${v}" aria-pressed="${f.mode === v}">${l}</button>`).join("")}
      <span class="spacer"></span>
      <span class="dim small">${groups.length} of ${all.length} skills · ${state.inv.skills.length} entries</span>
    </div>
    <div class="card table-wrap"><table class="grid"><thead><tr>
      <th>Skill</th><th>Sources</th><th>Owner</th><th class="nowrap">Claude</th><th class="nowrap">Codex</th><th>Flags</th>
    </tr></thead><tbody id="skills-body">`;
    if (!groups.length) html += emptyRow(6, "No skills match these filters.");
    const parts = [];
    for (const g of groups) {
      const key = `s:${g.name}`;
      const open = state.expanded.has(key);
      const flags = [];
      if (g.broken) flags.push(badge("err", "broken link"));
      if (g.pinned) flags.push(badge("warn", "pinned to Codex plugin version"));
      if (g.disabled) flags.push(badge("block", "disabled in Codex"));
      parts.push(`<tr class="row expandable ${open ? "open" : ""}" data-key="${esc(key)}">
        <td><span class="name">${hl(g.name)}</span></td>
        <td><div class="chips">${g.sources.map((s) => `<span class="chip ${sourceTool(s)}" title="${esc(s)}">${esc(SOURCE_LABEL[s] || s)}</span>`).join("")}</div></td>
        <td class="small muted">${g.owners.map(hl).join(", ")}</td>
        <td>${tick(g.claude, "visible in Claude")}</td>
        <td>${tick(g.codex, "visible in Codex")}</td>
        <td><div class="chips">${flags.join("") || `<span class="dim">–</span>`}</div></td>
      </tr>`);
      if (open) parts.push(`<tr class="detail"><td colspan="6">${skillDetail(g)}</td></tr>`);
    }
    html += parts.join("") + `</tbody></table></div>`;
    return html;
  }

  function skillDetail(g) {
    let html = g.description ? `<div class="desc" style="margin-bottom:10px">${hl(g.description)}</div>` : `<div class="dim small" style="margin-bottom:10px">No description in SKILL.md frontmatter.</div>`;
    html += `<table class="grid" style="background:var(--surface);border:1px solid var(--border);border-radius:6px"><thead><tr><th style="position:static">Source</th><th style="position:static">Path</th><th style="position:static">Link target</th><th style="position:static">Claude</th><th style="position:static">Codex</th></tr></thead><tbody>`;
    for (const e of g.entries) {
      html += `<tr><td><span class="chip ${sourceTool(e.source)}">${esc(SOURCE_LABEL[e.source] || e.source)}</span> <span class="dim small">${esc(e.owner)}</span></td>
        <td class="mono">${esc(e.path)}${e.dirName !== g.name ? `<div class="cell-sub">dir: ${esc(e.dirName)}</div>` : ""}</td>
        <td class="mono">${e.linkTarget ? esc(e.linkTarget) : `<span class="dim">–</span>`}${e.broken ? ` ${badge("err", "missing")}` : ""}</td>
        <td>${tick(e.visibleIn.claude)}</td><td>${tick(e.visibleIn.codex)}${e.codexDisabled ? ` ${badge("block", "disabled")}` : ""}</td></tr>`;
    }
    return html + `</tbody></table>`;
  }

  // ---------- instructions ----------

  function renderInstructions() {
    const inv = state.inv;
    const q = state.query;
    const files = inv.instructions.filter((i) => matches(q, i.rel, i.path, i.owner, i.name, i.scope, ...i.loadedBy, ...i.imports));
    // user/global first, then repos in discovery order.
    const owners = ["user", ...inv.repos.map((r) => r.name)];
    for (const i of inv.instructions) if (!owners.includes(i.owner)) owners.push(i.owner);
    const byOwner = new Map(owners.map((o) => [o, []]));
    for (const i of files) byOwner.get(i.owner).push(i);
    const repoByName = new Map(inv.repos.map((r) => [r.name, r]));
    let html = `<div class="toolbar"><span class="dim small">${files.length} of ${inv.instructions.length} files · click a row to preview the first 4 KB</span></div>`;
    let any = false;
    for (const [owner, list] of byOwner) {
      if (!list.length) continue;
      any = true;
      const repo = repoByName.get(owner);
      const title = owner === "user" ? "User / global" : owner;
      const sub = owner === "user" ? "~" : repo ? `${repo.path}${repo.branch ? ` · ${repo.branch}` : ""}` : "";
      const bytes = list.reduce((a, b) => a + b.bytes, 0);
      html += `<div class="card"><div class="group-head"><h2>${hl(title)}</h2>${repo ? `<span class="chip">${esc(repo.kind)}</span>` : `<span class="chip">global</span>`}<span class="path mono small">${esc(sub)}</span><span class="spacer" style="flex:1"></span><span class="dim small">${list.length} file${list.length === 1 ? "" : "s"} · ${kb(bytes)}</span></div>
        <div class="table-wrap"><table class="grid"><thead><tr><th>File</th><th class="right">Size</th><th class="right">Lines</th><th>Git</th><th>Loaded by</th><th>Notes</th></tr></thead><tbody>`;
      for (const i of list) {
        const key = `i:${i.path}`;
        const open = state.expanded.has(key);
        const notes = [];
        if (i.shimOnlyImportsAgents) notes.push(badge("info", "shim (only imports AGENTS.md)"));
        if (i.imports.length && !i.shimOnlyImportsAgents) notes.push(badge("", `imports ${i.imports.length}`, i.imports.join("\n")));
        if (i.bytes > 12000) notes.push(badge("warn", "large"));
        html += `<tr class="row expandable ${open ? "open" : ""}" data-key="${esc(key)}">
          <td class="mono">${hl(i.rel)}</td>
          <td class="right nowrap">${kb(i.bytes)}</td>
          <td class="right nowrap">${i.lines}</td>
          <td>${i.scope === "global" ? `<span class="dim">–</span>` : i.tracked ? badge("ok", "tracked") : badge("warn", "untracked")}</td>
          <td><div class="chips">${i.loadedBy.map((t) => `<span class="chip ${t}">${t}</span>`).join("") || `<span class="dim">–</span>`}</div></td>
          <td><div class="chips">${notes.join("") || `<span class="dim">–</span>`}</div></td>
        </tr>`;
        if (open) {
          html += `<tr class="detail"><td colspan="6"><div class="kv" style="margin-bottom:8px"><b>Path</b><span class="mono">${esc(i.path)}</span>${i.imports.length ? `<b>Imports</b><span class="mono">${i.imports.map(esc).join("<br>")}</span>` : ""}</div><pre class="preview">${esc(i.preview)}${i.bytes > i.preview.length ? "\n…" : ""}</pre></td></tr>`;
        }
      }
      html += `</tbody></table></div></div>`;
    }
    if (!any) html += `<div class="empty">No instruction files match.</div>`;
    return html;
  }

  // ---------- plugins ----------

  function renderPlugins() {
    const inv = state.inv;
    const q = state.query;
    const cl = inv.plugins.claude.filter((p) => matches(q, p.id, p.version, p.installPath));
    const cx = inv.plugins.codex.filter((p) => matches(q, p.id));
    const en = (b) => (b ? badge("ok", "enabled") : badge("", "disabled"));
    let html = `<div class="two-col">`;
    html += `<div class="card"><div class="card-head"><h2>Claude Code plugins</h2><span class="count small dim">${cl.length}</span><span class="dim small mono">~/.claude/settings.json</span></div>
      <div class="table-wrap"><table class="grid"><thead><tr><th>Plugin</th><th>State</th><th>Version</th><th>Provides</th></tr></thead><tbody>`;
    if (!cl.length) html += emptyRow(4, "No Claude plugins.");
    for (const p of cl) {
      const [name, mkt] = p.id.split("@");
      html += `<tr class="row"><td><div class="cell-stack"><span class="name">${hl(name)}</span><span class="cell-sub mono">${hl(mkt || "")}${p.installPath ? ` · ${hl(p.installPath)}` : ""}</span></div></td>
        <td>${en(p.enabled)}</td><td class="mono">${esc(p.version || "–")}</td>
        <td><div class="chips">${p.hasMcp ? `<span class="chip">mcp</span>` : ""}${p.hasSkills ? `<span class="chip">skills</span>` : ""}${!p.hasMcp && !p.hasSkills ? `<span class="dim">–</span>` : ""}</div></td></tr>`;
    }
    html += `</tbody></table></div></div>`;
    html += `<div class="card"><div class="card-head"><h2>Codex plugins</h2><span class="count small dim">${cx.length}</span><span class="dim small mono">~/.codex/config.toml [plugins]</span></div>
      <div class="table-wrap"><table class="grid"><thead><tr><th>Plugin</th><th>State</th><th>Cache</th></tr></thead><tbody>`;
    if (!cx.length) html += emptyRow(3, "No Codex plugins.");
    for (const p of cx) {
      const [name, mkt] = p.id.split("@");
      html += `<tr class="row"><td><div class="cell-stack"><span class="name">${hl(name)}</span><span class="cell-sub mono">${hl(mkt || "")}</span></div></td>
        <td>${en(p.enabled)}</td><td>${p.cached ? badge("ok", "cached") : badge("warn", "not cached")}</td></tr>`;
    }
    html += `</tbody></table></div></div></div>`;
    return html;
  }

  // ---------- proxy (CLIProxyAPI) ----------

  function cmpVersion(a, b) {
    const pa = String(a).replace(/^v/, "").split(/[.-]/).map((x) => parseInt(x, 10) || 0);
    const pb = String(b).replace(/^v/, "").split(/[.-]/).map((x) => parseInt(x, 10) || 0);
    for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
      const d = (pa[i] || 0) - (pb[i] || 0);
      if (d) return d;
    }
    return 0;
  }

  function proxyFindings() {
    const p = state.proxy;
    if (!p) return [];
    const out = [];
    if (p.authBlocked) {
      out.push({ severity: "error", area: "proxy", title: "CLIProxyAPI rejected the management key", detail: `HTTP ${p.authBlocked.status} on ${p.authBlocked.endpoint}. actl stopped calling the management API to avoid an IP ban; restart it after fixing the key.` });
    }
    if (p.listening && p.installedVersion && p.latestVersion && cmpVersion(p.installedVersion, p.latestVersion) < 0) {
      out.push({ severity: "info", area: "proxy", title: `CLIProxyAPI ${p.latestVersion} is available`, detail: `Installed: ${p.installedVersion}.`, fix: "brew upgrade cliproxyapi" });
    }
    const bad = (p.accounts || []).filter((a) => a.disabled || a.unavailable);
    if (bad.length) {
      out.push({
        severity: "warn",
        area: "proxy",
        title: `${bad.length} CLIProxyAPI account${bad.length === 1 ? " is" : "s are"} disabled or unavailable`,
        detail: "Requests are routed only to the remaining accounts. See the Proxy tab.",
        items: bad.map((a) => `${a.provider || "?"} · ${a.email || a.label || a.ref}${a.disabled ? " · disabled" : ""}${a.unavailable ? " · unavailable" : ""}${a.statusMessage ? ` · ${a.statusMessage}` : ""}`),
      });
    }
    return out;
  }

  function sparkline(buckets) {
    // 20 ten-minute buckets as stacked bars: success (accent) under failed (red).
    if (!buckets || !buckets.length) return `<span class="dim">–</span>`;
    const w = 4, gap = 1, h = 22;
    const max = Math.max(1, ...buckets.map((b) => b.success + b.failed));
    const bars = buckets
      .map((b, i) => {
        const x = i * (w + gap);
        const sh = Math.round((b.success / max) * h);
        const fh = Math.round((b.failed / max) * h);
        const t = `${b.time || `bucket ${i + 1}`}: ${b.success} ok, ${b.failed} failed`; // time is a "HH:MM-HH:MM" range
        const base = `<rect x="${x}" y="0" width="${w}" height="${h}" fill="transparent"><title>${esc(t)}</title></rect>`;
        const s = sh ? `<rect x="${x}" y="${h - sh}" width="${w}" height="${sh}" rx="1" class="spark-ok"><title>${esc(t)}</title></rect>` : `<rect x="${x}" y="${h - 1}" width="${w}" height="1" class="spark-zero"/>`;
        const f = fh ? `<rect x="${x}" y="${h - sh - fh}" width="${w}" height="${fh}" rx="1" class="spark-fail"><title>${esc(t)}</title></rect>` : "";
        return base + s + f;
      })
      .join("");
    return `<svg class="spark" width="${buckets.length * (w + gap) - gap}" height="${h}" viewBox="0 0 ${buckets.length * (w + gap) - gap} ${h}" role="img" aria-label="Requests per 10 minutes">${bars}</svg>`;
  }

  const sum = (bs, k) => (bs || []).reduce((a, b) => a + (b[k] || 0), 0);
  const yn = (v, yesKind = "ok", noKind = "") => (v === undefined || v === null ? `<span class="dim">unknown</span>` : v ? badge(yesKind, "yes") : badge(noKind, "no"));

  function statusBadge(a) {
    if (a.disabled) return badge("block", "disabled");
    if (a.unavailable) return badge("warn", a.status || "unavailable");
    const s = (a.status || "unknown").toLowerCase();
    return badge(s === "active" || s === "ok" || s === "ready" ? "ok" : s === "error" ? "err" : "", a.status || "unknown");
  }

  function renderProxy() {
    const p = state.proxy;
    const q = state.query;
    if (!p) return `<div class="empty">${state.proxyError ? `Failed to load proxy status: ${esc(state.proxyError)}` : "Loading CLIProxyAPI status…"}</div>`;
    const c = p.config || {};
    let html = "";

    if (p.authBlocked) {
      html += `<div class="notice"><span class="icon">!</span><div><b>Management key rejected (HTTP ${esc(p.authBlocked.status)}).</b> actl stopped all management API calls to avoid tripping CLIProxyAPI's IP ban (5 failures lock out 127.0.0.1 for about 30 minutes, including T3 Code). Fix the key, then restart actl.</div></div>`;
    } else if (!p.listening) {
      html += `<div class="notice"><span class="icon">!</span><div><b>Proxy not running.</b> Nothing is listening on <code>${esc(p.endpoint)}</code>. Check the Homebrew service: ${cmd("brew services info cliproxyapi")}</div></div>`;
    } else if (!p.keyConfigured) {
      html += `<div class="notice"><span class="icon">!</span><div><b>No management key found.</b> actl reads <code>~/.cli-proxy-api/management-key</code> or <code>ACTL_CLIPROXY_KEY</code>.</div></div>`;
    }

    const upToDate = p.installedVersion && p.latestVersion ? cmpVersion(p.installedVersion, p.latestVersion) >= 0 : undefined;
    const stats = [
      ["Listening", p.listening ? badge("ok", "yes") : badge("err", "no"), p.endpoint],
      ["Installed", esc(p.installedVersion || "unknown"), p.versionSource || ""],
      ["Latest", esc(p.latestVersion || "unknown"), upToDate === undefined ? "" : upToDate ? "up to date" : "update available"],
      ["Routing", esc(c.routingStrategy || "unknown"), c.sessionAffinity === undefined ? "" : `session affinity ${c.sessionAffinity ? "on" : "off"}${c.sessionAffinityTtl ? ` · ttl ${c.sessionAffinityTtl}` : ""}`],
      ["Port", esc(c.port ?? "–"), c.host ? `host ${c.host}` : ""],
      ["Control panel", c.disableControlPanel === undefined ? "unknown" : c.disableControlPanel ? "disabled" : "enabled", `remote management ${c.allowRemote ? "allowed" : c.allowRemote === false ? "off" : "unknown"}`],
    ];
    html += `<div class="stats">${stats
      .map(([l, v, sub]) => `<div class="stat static"><div class="label">${esc(l)}</div><div class="value value-sm">${v}</div><div class="sub">${esc(sub)}</div></div>`)
      .join("")}</div>`;

    if (p.config) {
      html += `<div class="section"><div class="section-head"><h2>Settings</h2><span class="dim small">non-secret fields from GET /config</span></div><div class="card"><div class="card-body"><div class="kv">
        <b>Request retry</b><span>${esc(c.requestRetry ?? "–")}</span>
        <b>Quota exceeded</b><span>switch project ${yn(c.quotaExceeded?.switchProject)} · switch preview model ${yn(c.quotaExceeded?.switchPreviewModel)}</span>
        <b>Session affinity</b><span>${yn(c.sessionAffinity)} · subagents ${yn(c.sessionAffinitySubagents)}</span>
        <b>Logging</b><span>debug ${yn(c.logging?.debug, "warn")} · to file ${yn(c.logging?.toFile)} · request log ${yn(c.logging?.requestLog, "warn")}</span>
        <b>Usage statistics</b><span>${c.usageStatisticsEnabled === undefined ? `<span class="dim">not set (default)</span>` : yn(c.usageStatisticsEnabled)}</span>
      </div></div></div></div>`;
    }

    // Accounts
    const accounts = (p.accounts || []).filter((a) => matches(q, a.provider, a.email, a.label, a.accountType, a.account, a.status, a.statusMessage));
    html += `<div class="section"><div class="section-head"><h2>Accounts</h2><span class="count small">${accounts.length}${p.accounts ? ` of ${p.accounts.length}` : ""}</span><span class="dim small">GET /credentials · emails masked</span></div>
      <div class="card table-wrap"><table class="grid"><thead><tr>
        <th>Provider</th><th>Account</th><th>Type</th><th>Status</th><th>Last refresh</th><th class="right">Success</th><th class="right">Failed</th><th>Last 200 min</th>
      </tr></thead><tbody>`;
    if (!p.accounts) html += emptyRow(8, p.errors?.["/credentials"] ? `Unavailable: ${p.errors["/credentials"]}` : "Not loaded.");
    else if (!accounts.length) html += emptyRow(8, "No accounts match.");
    for (const a of accounts) {
      const flags = [];
      if (a.disabled) flags.push(badge("block", "disabled"));
      if (a.unavailable) flags.push(badge("warn", "unavailable"));
      if (a.runtimeOnly) flags.push(badge("info", "runtime only"));
      const who = a.email || a.account || a.label || (a.ref ? `#${a.ref}` : "–");
      const sub = [a.label && a.label !== who ? a.label : "", a.ref ? `index ${a.ref}` : ""].filter(Boolean).join(" · ");
      html += `<tr class="row">
        <td><span class="chip ${a.provider === "claude" ? "claude" : a.provider === "codex" ? "codex" : ""}">${hl(a.provider || "?")}</span></td>
        <td><div class="cell-stack"><span class="mono">${hl(who)}</span>${sub ? `<span class="cell-sub">${hl(sub)}</span>` : ""}</div></td>
        <td class="small">${hl(a.accountType || "–")}</td>
        <td><div class="cell-stack"><div class="chips">${statusBadge(a)}${flags.join("")}</div>${a.statusMessage ? `<span class="cell-sub">${hl(a.statusMessage)}</span>` : ""}${a.nextRetryAfter ? `<span class="cell-sub">retry after ${esc(new Date(a.nextRetryAfter).toLocaleTimeString())}</span>` : ""}</div></td>
        <td class="nowrap small" title="${esc(a.lastRefresh ? new Date(a.lastRefresh).toLocaleString() : "")}">${a.lastRefresh ? fmtAgo(a.lastRefresh) : `<span class="dim">–</span>`}</td>
        <td class="right mono">${a.success}</td>
        <td class="right mono ${a.failed ? "fail-num" : ""}">${a.failed}</td>
        <td><div class="spark-cell">${sparkline(a.recent)}<span class="cell-sub">${sum(a.recent, "success")} ok · ${sum(a.recent, "failed")} failed</span></div></td>
      </tr>`;
    }
    html += `</tbody></table></div></div>`;

    // Traffic: API-key upstreams (OAuth accounts carry their own sparkline above).
    const usage = (p.apiKeyUsage || []).filter((u) => matches(q, u.provider, u.label));
    html += `<div class="section"><div class="section-head"><h2>API-key traffic</h2><span class="count small">${usage.length}</span><span class="dim small">GET /observability/usage/api-keys · 20 × 10-minute buckets · keys never shown</span></div>`;
    if (!p.apiKeyUsage) html += `<div class="empty">${esc(p.errors?.["/observability/usage/api-keys"] ? `Unavailable: ${p.errors["/observability/usage/api-keys"]}` : "Not loaded.")}</div>`;
    else if (!usage.length) html += `<div class="empty">No API-key upstreams configured. OAuth account traffic is shown in the Accounts table.</div>`;
    else {
      html += `<div class="card table-wrap"><table class="grid"><thead><tr><th>Provider</th><th>Upstream</th><th class="right">Success</th><th class="right">Failed</th><th>Last 200 min</th></tr></thead><tbody>`;
      for (const u of usage) {
        html += `<tr class="row"><td><span class="chip">${hl(u.provider)}</span></td><td class="mono small">${hl(u.label)}</td><td class="right mono">${u.success}</td><td class="right mono ${u.failed ? "fail-num" : ""}">${u.failed}</td>
          <td><div class="spark-cell">${sparkline(u.recent)}<span class="cell-sub">${sum(u.recent, "success")} ok · ${sum(u.recent, "failed")} failed</span></div></td></tr>`;
      }
      html += `</tbody></table></div>`;
    }
    html += `</div>`;

    // Error logs
    const logs = (p.errorLogs || []).filter((l) => matches(q, l.name));
    html += `<div class="section"><div class="section-head"><h2>Recent error logs</h2><span class="count small">${p.errorLogs ? p.errorLogs.length : 0}</span><span class="dim small">GET /observability/logs/errors · names, sizes and times only</span></div>`;
    if (!p.errorLogs) html += `<div class="empty">${esc(p.errors?.["/observability/logs/errors"] ? `Unavailable: ${p.errors["/observability/logs/errors"]}` : "Not loaded.")}</div>`;
    else if (!logs.length) html += `<div class="empty">${c.logging?.requestLog ? "Request logging is on, so CLIProxyAPI does not list separate error logs." : "No error logs."}</div>`;
    else {
      html += `<div class="card table-wrap"><table class="grid"><thead><tr><th>File</th><th class="right">Size</th><th>Modified</th></tr></thead><tbody>`;
      for (const l of logs.slice(0, 20)) {
        html += `<tr class="row"><td class="mono">${hl(l.name || "–")}</td><td class="right nowrap">${kb(l.size)}</td><td class="nowrap small" title="${esc(l.modified ? new Date(l.modified).toLocaleString() : "")}">${l.modified ? fmtAgo(l.modified) : "–"}</td></tr>`;
      }
      if (logs.length > 20) html += emptyRow(3, `${logs.length - 20} older files not shown`);
      html += `</tbody></table></div>`;
    }
    html += `</div>`;

    const errs = Object.entries(p.errors || {});
    if (errs.length) {
      html += `<div class="section"><div class="section-head"><h2>Endpoint errors</h2></div><div class="card"><div class="card-body"><div class="kv">${errs.map(([k, v]) => `<b class="mono">${esc(k)}</b><span>${esc(v)}</span>`).join("")}</div></div></div></div>`;
    }

    html += `<div class="section"><div class="card"><div class="card-body small muted">
      <p style="margin:0 0 6px"><b>Read-only.</b> Phase 2 actions are not implemented: re-login via OAuth, reset cooldown, enable or disable an account.</p>
      <p style="margin:0">The official Management Center is intentionally not embedded: it keeps the management key in browser <code>localStorage</code>. actl reads the key server-side only and calls a fixed allowlist of GET endpoints. Snapshot ${esc(fmtAgo(p.generatedAt))} · took ${esc(p.tookMs)} ms · cached 45 s.</p>
    </div></div></div>`;
    return html;
  }

  async function loadProxy(refresh = false) {
    const onTab = state.tab === "proxy";
    if (onTab && refresh) {
      refreshBtn.disabled = true;
      refreshBtn.classList.add("is-loading");
    }
    try {
      const res = await fetch(`/api/cliproxy${refresh ? "?refresh" : ""}`);
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      state.proxy = await res.json();
      state.proxyError = "";
      if (refresh) toast("Proxy status refreshed");
    } catch (e) {
      state.proxyError = e.message;
    } finally {
      if (onTab && refresh) {
        refreshBtn.disabled = false;
        refreshBtn.classList.remove("is-loading");
      }
    }
    if (state.tab === "proxy" || state.tab === "overview") render();
  }

  // ---------- render dispatch ----------

  const renderers = { overview: renderOverview, mcp: renderMcp, skills: renderSkills, instructions: renderInstructions, plugins: renderPlugins, proxy: renderProxy };

  function render() {
    renderHeader();
    if (!state.inv && state.tab !== "proxy") return;
    const html = renderers[state.tab]();
    // Single innerHTML write per render keeps 300+ row tables snappy.
    main.innerHTML = html;
  }

  function setTab(tab, push = true) {
    if (!TABS.includes(tab)) return;
    state.tab = tab;
    if (push && location.hash !== `#${tab}`) history.replaceState(null, "", `#${tab}`);
    window.scrollTo(0, 0);
    render();
  }

  // ---------- data ----------

  async function load(refresh = false) {
    refreshBtn.disabled = true;
    refreshBtn.classList.add("is-loading");
    refreshBtn.querySelector("span").textContent = refresh ? "Collecting…" : "Loading…";
    try {
      const res = await fetch(`/api/inventory${refresh ? "?refresh" : ""}`);
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      state.inv = await res.json();
      skillGroupsCache = null;
      render();
      if (refresh) toast(`Re-collected in ${(state.inv.tookMs / 1000).toFixed(1)}s`);
    } catch (e) {
      main.innerHTML = `<div class="empty">Failed to load inventory: ${esc(e.message)}<br><span class="small">Is the server running? <code>bun src/server.ts</code></span></div>`;
    } finally {
      refreshBtn.disabled = false;
      refreshBtn.classList.remove("is-loading");
      refreshBtn.querySelector("span").textContent = "Refresh";
    }
  }

  // ---------- events ----------

  refreshBtn.addEventListener("click", () => (state.tab === "proxy" ? loadProxy(true) : load(true)));

  let searchTimer;
  searchEl.addEventListener("input", () => {
    clearTimeout(searchTimer);
    searchTimer = setTimeout(() => {
      state.query = searchEl.value.trim().toLowerCase();
      render();
    }, 80);
  });

  $("#tabs").addEventListener("click", (e) => {
    const b = e.target.closest("button[data-tab]");
    if (b) setTab(b.dataset.tab);
  });
  window.addEventListener("hashchange", () => setTab(tabFromHash(), false));

  main.addEventListener("click", async (e) => {
    const copy = e.target.closest("button[data-copy]");
    if (copy) {
      e.stopPropagation();
      try {
        await navigator.clipboard.writeText(copy.dataset.copy);
        toast("Copied");
      } catch {
        toast("Copy failed (clipboard blocked)");
      }
      return;
    }
    const login = e.target.closest("button[data-login-tool]");
    if (login) {
      e.stopPropagation();
      login.disabled = true;
      return startLogin(login.dataset.loginTool, login.dataset.loginName);
    }
    const goto = e.target.closest("[data-goto]");
    if (goto) return setTab(goto.dataset.goto);
    const mode = e.target.closest("button[data-mode]");
    if (mode) {
      state.skillFilters.mode = mode.dataset.mode;
      return render();
    }
    const row = e.target.closest("tr.expandable");
    if (row && !e.target.closest("a, button")) {
      const key = row.dataset.key;
      if (state.expanded.has(key)) state.expanded.delete(key);
      else state.expanded.add(key);
      const next = row.nextElementSibling;
      if (next && next.classList.contains("detail")) {
        // Collapse in place without re-rendering the table.
        row.classList.remove("open");
        next.remove();
      } else {
        // Expand: one innerHTML write of the current tab, then keep the row in view.
        render();
        main.querySelector(`tr.expandable[data-key="${CSS.escape(key)}"]`)?.scrollIntoView({ block: "nearest" });
      }
    }
  });

  main.addEventListener("toggle", (e) => {
    const d = e.target;
    if (d.tagName === "DETAILS" && d.dataset.key) {
      if (d.open) state.expanded.add(d.dataset.key);
      else state.expanded.delete(d.dataset.key);
    }
  }, true);

  main.addEventListener("change", (e) => {
    if (e.target.id === "skill-source") {
      state.skillFilters.source = e.target.value;
      render();
    }
  });

  document.addEventListener("keydown", (e) => {
    const inField = /^(INPUT|TEXTAREA|SELECT)$/.test(document.activeElement?.tagName || "");
    if (e.key === "Escape" && document.activeElement === searchEl) {
      if (searchEl.value) {
        searchEl.value = "";
        state.query = "";
        render();
      } else searchEl.blur();
      return;
    }
    if (inField || e.metaKey || e.ctrlKey || e.altKey) return;
    if (e.key === "/") {
      e.preventDefault();
      searchEl.focus();
      searchEl.select();
    } else if (/^[1-6]$/.test(e.key)) {
      setTab(TABS[Number(e.key) - 1]);
    }
  });

  const topbar = $(".topbar");
  const measureTopbar = () => document.documentElement.style.setProperty("--topbar-h", `${topbar.offsetHeight}px`);
  new ResizeObserver(measureTopbar).observe(topbar);
  measureTopbar();

  setInterval(() => {
    if (state.inv) $("#collected").textContent = `collected ${fmtAgo(state.inv.generatedAt)}`;
  }, 30_000);

  render();
  load(false);
  loadProxy(false);
})();
