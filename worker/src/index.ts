import { handleInteraction } from "./discord/router";
import { handleScheduled } from "./scheduled";
import { handleAdmin } from "./admin";
import type { Env } from "./types";

export default {
  async fetch(req: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(req.url);

    // GET /whatismyip — lets users discover their public IP for /allowlist
    if (req.method === "GET" && url.pathname === "/whatismyip") {
      const ip = req.headers.get("CF-Connecting-IP") ?? "unknown";
      return new Response(ip, { headers: { "Content-Type": "text/plain" } });
    }

    // GET /idle-shutdown — called by the server watchdog before poweroff
    if (req.method === "POST" && url.pathname === "/idle-shutdown") {
      return handleIdleShutdown(req, env);
    }

    // PATCH /admin/modpacks/:name — CI updates AMI IDs after builds
    if (req.method === "PATCH" && url.pathname.startsWith("/admin/")) {
      return handleAdmin(req, env, ctx);
    }

    // POST / — Discord interaction webhook
    if (req.method === "POST" && url.pathname === "/") {
      return handleInteraction(req, env, ctx);
    }

    return new Response("not found", { status: 404 });
  },

  async scheduled(_event: ScheduledEvent, env: Env, ctx: ExecutionContext): Promise<void> {
    ctx.waitUntil(handleScheduled(env));
  },
} satisfies ExportedHandler<Env>;

async function handleIdleShutdown(req: Request, env: Env): Promise<Response> {
  const body = await req.text();
  const sig = req.headers.get("X-Sploosh-Sig") ?? "";

  // Verify HMAC
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(env.IDLE_WEBHOOK_SECRET),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["verify"],
  );
  const expected = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(
    JSON.parse(body).modpack ?? ""
  ));
  const expectedHex = Array.from(new Uint8Array(expected))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");

  if (sig !== expectedHex) {
    return new Response("unauthorized", { status: 401 });
  }

  const { modpack } = JSON.parse(body);
  await env.DB.prepare(
    "UPDATE server_state SET status='stopping', instance_id=NULL, public_ip=NULL WHERE modpack=?",
  )
    .bind(modpack)
    .run();

  return new Response("ok");
}
