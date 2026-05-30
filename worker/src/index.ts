import { handleInteraction } from "./discord/router";
import { handleScheduled } from "./scheduled";
import { handleAdmin } from "./admin";
import { getServerState, setServerStatus } from "./db";
import { deleteFleet } from "./aws/ec2";
import type { Env } from "./types";

export default {
  async fetch(req: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(req.url);

    // GET /idle-shutdown — called by the server watchdog before poweroff
    if (req.method === "POST" && url.pathname === "/idle-shutdown") {
      return handleIdleShutdown(req, env);
    }

    // GET /api/whitelist/:modpack — returns active allowlist entries that have a Minecraft UUID,
    // consumed by the mc-sync-whitelist ExecStartPre on instance startup
    if (req.method === "GET" && url.pathname.startsWith("/api/whitelist/")) {
      const modpack = url.pathname.slice("/api/whitelist/".length);
      const { results } = await env.DB.prepare(
        "SELECT minecraft_username, minecraft_uuid FROM allowlist WHERE modpack=? AND minecraft_uuid != '' AND expires_at > ?",
      )
        .bind(modpack, Date.now())
        .all<{ minecraft_username: string; minecraft_uuid: string }>();
      const body = JSON.stringify(results.map((r) => ({ name: r.minecraft_username, uuid: r.minecraft_uuid })));
      return new Response(body, { headers: { "Content-Type": "application/json" } });
    }

    // GET /pack/:modpack/* — serve packdir files to packwiz-installer
    if (req.method === "GET" && url.pathname.startsWith("/pack/")) {
      return handlePackFile(req, env);
    }

    // PUT /admin/pack/:modpack/* — CI uploads packdir files to R2
    if (req.method === "PUT" && url.pathname.startsWith("/admin/pack/")) {
      return handlePackUpload(req, env);
    }

    // PATCH /admin/modpacks/:name — CI updates AMI IDs / pack URLs after builds
    if (req.method === "PATCH" && url.pathname.startsWith("/admin/")) {
      return handleAdmin(req, env, ctx);
    }

    // POST / — Discord interaction webhook
    if (req.method === "POST" && url.pathname === "/") {
      return handleInteraction(req, env, ctx);
    }

    return new Response("not found", { status: 404 });
  },

  async scheduled(_event: ScheduledController, env: Env, ctx: ExecutionContext): Promise<void> {
    ctx.waitUntil(handleScheduled(env));
  },
} satisfies ExportedHandler<Env>;

async function handlePackFile(req: Request, env: Env): Promise<Response> {
  const key = new URL(req.url).pathname.slice("/pack/".length); // "create-central/pack.toml"
  const obj = await env.PACK_BUCKET.get(key);
  if (!obj) return new Response("not found", { status: 404 });
  const headers = new Headers();
  obj.writeHttpMetadata(headers);
  headers.set("etag", obj.httpEtag);
  headers.set("cache-control", "public, max-age=300");
  return new Response(obj.body, { headers });
}

async function handlePackUpload(req: Request, env: Env): Promise<Response> {
  const url = new URL(req.url);
  // /admin/pack/:modpack/:path* → key = "create-central/mods/foo.pw.toml"
  const after = url.pathname.slice("/admin/pack/".length);
  const slash = after.indexOf("/");
  if (slash === -1) return new Response("bad request", { status: 400 });
  const modpack = after.slice(0, slash);
  const filePath = after.slice(slash + 1);

  const bodyBuffer = await req.arrayBuffer();
  const bodyHashBuf = await crypto.subtle.digest("SHA-256", bodyBuffer);
  const bodyHash = Array.from(new Uint8Array(bodyHashBuf)).map((b) => b.toString(16).padStart(2, "0")).join("");

  const sig = req.headers.get("X-Sploosh-Sig") ?? "";
  const expected = await packHmac(env.ADMIN_SECRET, modpack, filePath, bodyHash);
  if (sig !== expected) return new Response("unauthorized", { status: 401 });

  await env.PACK_BUCKET.put(`${modpack}/${filePath}`, bodyBuffer, {
    httpMetadata: { contentType: "text/plain; charset=utf-8" },
  });
  return new Response("ok");
}

async function packHmac(secret: string, modpack: string, filePath: string, bodyHash: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${modpack}:${filePath}:${bodyHash}`));
  return Array.from(new Uint8Array(sig)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function handleIdleShutdown(req: Request, env: Env): Promise<Response> {
  const body = await req.text();
  const sig = req.headers.get("X-Sploosh-Sig") ?? "";

  // Verify HMAC
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(env.IDLE_WEBHOOK_SECRET),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
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
  const state = await getServerState(env, modpack);
  if (state?.fleet_id) {
    await deleteFleet(env, state.fleet_id).catch(() => {});
  }
  await setServerStatus(env, modpack, "stopping", null, null, null);

  return new Response("ok");
}
