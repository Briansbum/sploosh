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

  // Find existing record
  const listRes = await fetch(
    `${CF_API}/zones/${zoneId}/dns_records?type=A&name=${encodeURIComponent(name)}`,
    { headers: headers(env) },
  );
  const listJson = await listRes.json<{ result: Array<{ id: string }> }>();
  const existing = listJson.result?.[0];

  if (existing) {
    await fetch(`${CF_API}/zones/${zoneId}/dns_records/${existing.id}`, {
      method: "PATCH",
      headers: headers(env),
      body: JSON.stringify({ content: ip, ttl: 60 }),
    });
  } else {
    await fetch(`${CF_API}/zones/${zoneId}/dns_records`, {
      method: "POST",
      headers: headers(env),
      body: JSON.stringify({ type: "A", name, content: ip, ttl: 60, proxied: false }),
    });
  }
}
