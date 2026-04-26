import type { Env, Modpack, ServerState, AllowlistEntry } from "./types";

export async function getModpack(env: Env, name: string): Promise<Modpack | null> {
  return env.DB.prepare("SELECT * FROM modpacks WHERE name=?").bind(name).first<Modpack>();
}

export async function listModpacks(env: Env): Promise<Modpack[]> {
  const r = await env.DB.prepare("SELECT * FROM modpacks").all<Modpack>();
  return r.results;
}

export async function getServerState(env: Env, modpack: string): Promise<ServerState | null> {
  return env.DB.prepare("SELECT * FROM server_state WHERE modpack=?")
    .bind(modpack)
    .first<ServerState>();
}

export async function setServerStatus(
  env: Env,
  modpack: string,
  status: ServerState["status"],
  instanceId?: string | null,
  publicIp?: string | null,
  fleetId?: string | null,
): Promise<void> {
  await env.DB.prepare(
    `UPDATE server_state
     SET status=?, instance_id=?, public_ip=?, fleet_id=?, last_seen=?
     WHERE modpack=?`,
  )
    .bind(status, instanceId ?? null, publicIp ?? null, fleetId ?? null, Date.now(), modpack)
    .run();
}

export async function getAllowlistEntry(
  env: Env,
  modpack: string,
  userId: string,
): Promise<AllowlistEntry | null> {
  return env.DB.prepare("SELECT * FROM allowlist WHERE modpack=? AND discord_user_id=?")
    .bind(modpack, userId)
    .first<AllowlistEntry>();
}

export async function upsertAllowlist(
  env: Env,
  modpack: string,
  userId: string,
  ip: string,
  sgRuleId: string,
  ttlDays = 7,
  minecraftUsername = "",
  minecraftUuid = "",
): Promise<void> {
  const now = Date.now();
  const expires = now + ttlDays * 24 * 60 * 60 * 1000;
  await env.DB.prepare(
    `INSERT INTO allowlist (modpack, discord_user_id, ip, sg_rule_id, added_at, expires_at, minecraft_username, minecraft_uuid)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?)
     ON CONFLICT(modpack, discord_user_id)
     DO UPDATE SET ip=excluded.ip, sg_rule_id=excluded.sg_rule_id,
                   added_at=excluded.added_at, expires_at=excluded.expires_at,
                   minecraft_username=CASE WHEN excluded.minecraft_username != '' THEN excluded.minecraft_username ELSE minecraft_username END,
                   minecraft_uuid=CASE WHEN excluded.minecraft_uuid != '' THEN excluded.minecraft_uuid ELSE minecraft_uuid END`,
  )
    .bind(modpack, userId, ip, sgRuleId, now, expires, minecraftUsername, minecraftUuid)
    .run();
}

export async function removeAllowlist(
  env: Env,
  modpack: string,
  userId: string,
): Promise<AllowlistEntry | null> {
  const entry = await getAllowlistEntry(env, modpack, userId);
  if (entry) {
    await env.DB.prepare("DELETE FROM allowlist WHERE modpack=? AND discord_user_id=?")
      .bind(modpack, userId)
      .run();
  }
  return entry;
}

export async function getExpiredAllowlist(env: Env): Promise<AllowlistEntry[]> {
  const r = await env.DB.prepare("SELECT * FROM allowlist WHERE expires_at < ?")
    .bind(Date.now())
    .all<AllowlistEntry>();
  return r.results;
}

export async function updateModpackAmi(env: Env, modpack: string, amiId: string): Promise<void> {
  await env.DB.prepare("UPDATE modpacks SET ami_id=? WHERE name=?").bind(amiId, modpack).run();
}
