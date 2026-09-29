// Local-only dashboard server. Binds to 127.0.0.1; read-only in v1.
import { listJobs, loginTargets, startLogin, type Tool } from "./actions";
import { cliproxy } from "./cliproxy";
import type { collect } from "./collect";

const PORT = Number(process.env.ACTL_PORT ?? 4777);
const publicDir = new URL("../public/", import.meta.url).pathname;

let cache: { at: number; data: ReturnType<typeof collect> } | undefined;
let inflight: Promise<ReturnType<typeof collect>> | undefined;

async function inventory(refresh: boolean) {
  if (!refresh && cache && Date.now() - cache.at < 5 * 60_000) return cache.data;
  // Collect in a child process: the collector shells out synchronously and would otherwise block every request.
  inflight ??= new Response(Bun.spawn(["bun", new URL("./collect.ts", import.meta.url).pathname], { stdout: "pipe", stderr: "ignore" }).stdout)
    .json()
    .then((data) => {
      cache = { at: Date.now(), data };
      return data;
    })
    .finally(() => (inflight = undefined));
  return inflight;
}

Bun.serve({
  hostname: "127.0.0.1",
  port: PORT,
  // Collection health-checks every MCP server and can take ~15s; Bun's default idle timeout is 10s.
  idleTimeout: 120,
  async fetch(req) {
    const url = new URL(req.url);
    if (url.pathname.startsWith("/api/")) {
      // Block DNS rebinding: only accept our own loopback Host header.
      const host = (req.headers.get("host") ?? "").toLowerCase();
      if (host !== `127.0.0.1:${PORT}` && host !== `localhost:${PORT}`) {
        return new Response("Forbidden host", { status: 403 });
      }
    }
    if (url.pathname.startsWith("/api/actions/")) {
      if (req.method === "GET" && url.pathname === "/api/actions/jobs") return Response.json(listJobs(), { headers: { "Cache-Control": "no-store" } });
      // Writes need our custom header (forces a CORS preflight we never approve) and a same-origin Origin.
      const origin = req.headers.get("origin");
      const sameOrigin = !origin || origin === `http://127.0.0.1:${PORT}` || origin === `http://localhost:${PORT}`;
      if (req.method !== "POST" || req.headers.get("x-actl") !== "1" || !sameOrigin) return new Response("Forbidden", { status: 403 });
      if (url.pathname === "/api/actions/mcp-login") {
        const body = (await req.json().catch(() => ({}))) as { tool?: Tool; name?: string };
        if ((body.tool !== "claude" && body.tool !== "codex") || typeof body.name !== "string") return Response.json({ error: "tool and name required" }, { status: 400 });
        const result = startLogin(body.tool, body.name, loginTargets(await inventory(false)));
        return Response.json(result, { status: "error" in result ? 400 : 202 });
      }
      return new Response("Not found", { status: 404 });
    }
    if (url.pathname === "/api/cliproxy") {
      return Response.json(await cliproxy(url.searchParams.has("refresh")), { headers: { "Cache-Control": "no-store" } });
    }
    if (url.pathname === "/api/inventory") {
      return Response.json(await inventory(url.searchParams.has("refresh")));
    }
    const file = Bun.file(publicDir + (url.pathname === "/" ? "index.html" : url.pathname.slice(1)));
    // no-cache: revalidate every load so an edited app.js is never served stale.
    if (!url.pathname.includes("..") && (await file.exists())) return new Response(file, { headers: { "Cache-Control": "no-cache" } });
    return new Response("Not found", { status: 404 });
  },
});

console.log(`actl → http://127.0.0.1:${PORT}`);
