// Cloudflare DNS helpers — upserts an A record for a modpack subdomain.
import type { Env } from "../types";

const CF_API = "https://api.cloudflare.com/client/v4";

function headers(env: Env) {
  return {
    "Content-Type": "application/json",
    Authorization: `Bearer ${env.CF_API_TOKEN}`,
  };
}

export function modpackHostname(env: Env, modpackName: string): string {
  return `${modpackName}.${env.CF_DOMAIN}`;
}

export async function setARecord(env: Env, modpackName: string, ip: string): Promise<void> {
  const name = modpackHostname(env, modpackName);
  const zoneId = env.CF_ZONE_ID;

  const listRes = await fetch(
    `${CF_API}/zones/${zoneId}/dns_records?type=A&name=${encodeURIComponent(name)}`,
    { headers: headers(env) },
  );
  const listJson = await listRes.json<{ success: boolean; errors: unknown[]; result: Array<{ id: string }> }>();
  if (!listJson.success) {
    throw new Error(`CF DNS list failed: ${JSON.stringify(listJson.errors)}`);
  }
  const existing = listJson.result?.[0];

  if (existing) {
    const patchRes = await fetch(`${CF_API}/zones/${zoneId}/dns_records/${existing.id}`, {
      method: "PATCH",
      headers: headers(env),
      body: JSON.stringify({ content: ip, ttl: 60 }),
    });
    const patchJson = await patchRes.json<{ success: boolean; errors: unknown[] }>();
    if (!patchJson.success) {
      throw new Error(`CF DNS patch failed: ${JSON.stringify(patchJson.errors)}`);
    }
  } else {
    const postRes = await fetch(`${CF_API}/zones/${zoneId}/dns_records`, {
      method: "POST",
      headers: headers(env),
      body: JSON.stringify({ type: "A", name, content: ip, ttl: 60, proxied: false }),
    });
    const postJson = await postRes.json<{ success: boolean; errors: unknown[] }>();
    if (!postJson.success) {
      throw new Error(`CF DNS post failed: ${JSON.stringify(postJson.errors)}`);
    }
  }
}
