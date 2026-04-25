// /admin/* endpoints — called by CI to update AMI IDs after builds.
// Protected by HMAC: X-Sploosh-Sig = HMAC-SHA256(secret, "<modpack>:<ami_id>")
import { updateModpackAmi } from "./db";
import type { Env } from "./types";

export async function handleAdmin(req: Request, env: Env, _ctx: ExecutionContext): Promise<Response> {
  const url = new URL(req.url);
  const parts = url.pathname.split("/").filter(Boolean);
  // PATCH /admin/modpacks/:name
  if (parts[0] !== "admin" || parts[1] !== "modpacks" || !parts[2]) {
    return new Response("not found", { status: 404 });
  }
  const modpackName = parts[2];

  // Verify HMAC
  const body = await req.text();
  const sig = req.headers.get("X-Sploosh-Sig") ?? "";
  const { ami_id } = JSON.parse(body);

  const expected = await hmacHex(env.ADMIN_SECRET, `${modpackName}:${ami_id}`);
  if (!timingSafeEqual(sig, expected)) {
    return new Response("unauthorized", { status: 401 });
  }

  await updateModpackAmi(env, modpackName, ami_id);
  return new Response("ok");
}

async function hmacHex(secret: string, message: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(message));
  return Array.from(new Uint8Array(sig))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

// Constant-time string comparison to prevent timing attacks
function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}
