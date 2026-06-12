import { handleInteraction } from "./discord/router";
import { handleScheduled } from "./scheduled";
import { handleAdmin } from "./admin";
import { getServerState, setServerStatus } from "./db";
import { deleteFleet } from "./aws/ec2";
import { setARecord } from "./cloudflare/dns";
import type { Env } from "./types";

export default {
  async fetch(req: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(req.url);

    if (req.method === "POST" && url.pathname === "/idle-shutdown") {
      return handleIdleShutdown(req, env);
    }

    // Called by mc-bootstrap on every instance boot to register the instance IP
    // immediately, rather than waiting up to 5 minutes for the cron reconciler.
    // Critical for spot-reclaim replacements that get a new public IP.
    if (req.method === "POST" && url.pathname === "/server-heartbeat") {
      return handleServerHeartbeat(req, env);
    }

    // GET /api/whitelist/:modpack — consumed by mc-sync-whitelist on the instance
    if (req.method === "GET" && url.pathname.startsWith("/api/whitelist/")) {
      const modpack = url.pathname.slice("/api/whitelist/".length);
      const { results } = await env.DB.prepare(
        "SELECT minecraft_username, minecraft_uuid FROM allowlist WHERE modpack=? AND minecraft_uuid != ''",
      )
        .bind(modpack)
        .all<{ minecraft_username: string; minecraft_uuid: string }>();
      const body = JSON.stringify(results.map((r) => ({ name: r.minecraft_username, uuid: r.minecraft_uuid })));
      return new Response(body, { headers: { "Content-Type": "application/json" } });
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

  async scheduled(_event: ScheduledController, env: Env, ctx: ExecutionContext): Promise<void> {
    ctx.waitUntil(handleScheduled(env));
  },
} satisfies ExportedHandler<Env>;

async function verifyHmac(env: Env, sig: string, modpack: string): Promise<boolean> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(env.IDLE_WEBHOOK_SECRET),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const expected = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(modpack));
  const expectedHex = Array.from(new Uint8Array(expected))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
  return sig === expectedHex;
}

async function handleIdleShutdown(req: Request, env: Env): Promise<Response> {
  const body = await req.text();
  const sig = req.headers.get("X-Sploosh-Sig") ?? "";
  const { modpack } = JSON.parse(body);

  if (!(await verifyHmac(env, sig, modpack ?? ""))) {
    return new Response("unauthorized", { status: 401 });
  }

  const state = await getServerState(env, modpack);
  if (state?.fleet_id) {
    await deleteFleet(env, state.fleet_id).catch(() => {});
  }
  await setServerStatus(env, modpack, "stopping", null, null, null);

  return new Response("ok");
}

async function handleServerHeartbeat(req: Request, env: Env): Promise<Response> {
  const body = await req.text();
  const sig = req.headers.get("X-Sploosh-Sig") ?? "";
  const { modpack, public_ip, instance_id } = JSON.parse(body) as {
    modpack?: string;
    public_ip?: string;
    instance_id?: string;
  };

  if (!modpack || !public_ip) {
    return new Response("missing fields", { status: 400 });
  }

  if (!(await verifyHmac(env, sig, modpack))) {
    return new Response("unauthorized", { status: 401 });
  }

  const state = await getServerState(env, modpack);
  if (!state?.fleet_id) {
    // No fleet active — stale heartbeat from a lingering instance
    return new Response("no active fleet", { status: 409 });
  }

  await setServerStatus(
    env,
    modpack,
    "running",
    instance_id ?? state.instance_id ?? null,
    public_ip,
    state.fleet_id,
  );
  await setARecord(env, modpack, public_ip).catch((e) =>
    console.error(`DNS heartbeat failed for ${modpack}:`, e),
  );

  return new Response("ok");
}
