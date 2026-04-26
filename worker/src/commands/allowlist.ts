import { getModpack, getServerState, upsertAllowlist, getAllowlistEntry } from "../db";
import { authorizeSgIngress } from "../aws/ec2";
import type { Env } from "../types";

export async function handleAllowlist(
  interaction: Record<string, unknown>,
  env: Env,
  ctx: ExecutionContext,
  userId: string,
): Promise<Response> {
  const options = (interaction.data as Record<string, unknown>)?.options as
    | Array<{ name: string; value: unknown }>
    | undefined;
  const modpackName = options?.find((o) => o.name === "modpack")?.value as string | undefined;
  let ip = options?.find((o) => o.name === "ip")?.value as string | undefined;
  const mcUsername = options?.find((o) => o.name === "minecraft_username")?.value as string | undefined;

  if (!modpackName) {
    return Response.json({ type: 4, data: { content: "Usage: `/allowlist modpack:<name> [ip:<your-ip>] [minecraft_username:<name>]`", flags: 64 } });
  }

  const modpack = await getModpack(env, modpackName);
  if (!modpack) {
    return Response.json({ type: 4, data: { content: `Unknown modpack: \`${modpackName}\``, flags: 64 } });
  }

  if (!ip) {
    return Response.json({
      type: 4,
      data: {
        content: `IP is required. Find yours at https://sploosh.workers.dev/whatismyip then run:\n\`/allowlist modpack:${modpackName} ip:<your-ip>\``,
        flags: 64,
      },
    });
  }

  if (!isValidIp(ip)) {
    return Response.json({ type: 4, data: { content: `\`${ip}\` doesn't look like a valid IP address.`, flags: 64 } });
  }

  // Look up Minecraft UUID if username provided
  let minecraftUsername = "";
  let minecraftUuid = "";
  if (mcUsername) {
    const result = await lookupMinecraftUuid(mcUsername);
    if (!result) {
      return Response.json({ type: 4, data: { content: `Minecraft player \`${mcUsername}\` not found.`, flags: 64 } });
    }
    minecraftUsername = result.name;
    minecraftUuid = result.uuid;
  }

  // Check if already allowlisted with same IP and username
  const existing = await getAllowlistEntry(env, modpackName, userId);
  if (existing?.ip === ip && (!mcUsername || existing.minecraft_uuid === minecraftUuid)) {
    const expiresIn = Math.round((existing.expires_at - Date.now()) / 1000 / 3600 / 24);
    return Response.json({
      type: 4,
      data: {
        content: `✅ Your IP \`${ip}\` is already allowlisted for **${modpack.display_name}** (expires in ~${expiresIn}d).`,
        flags: 64,
      },
    });
  }

  const state = await getServerState(env, modpackName);

  let sgRuleId = "";
  if (state?.status === "running" && modpack.security_group_id) {
    try {
      sgRuleId = await authorizeSgIngress(env, modpack.security_group_id, ip);
    } catch (e) {
      return Response.json({
        type: 4,
        data: { content: `Failed to add SG rule: ${String(e)}`, flags: 64 },
      });
    }
  }

  await upsertAllowlist(env, modpackName, userId, ip, sgRuleId, 7, minecraftUsername, minecraftUuid);

  const serverLine =
    state?.status === "running" && state.public_ip
      ? `\nConnect now: \`${state.public_ip}:25565\``
      : "\nStart the server with `/start modpack:" + modpackName + "`.";

  const mcLine = minecraftUsername
    ? `\nMinecraft player: \`${minecraftUsername}\` — will be added to the server whitelist on next start.`
    : "\n_Tip: run `/allowlist minecraft_username:<your-ign>` to be whitelisted on the server automatically._";

  return Response.json({
    type: 4,
    data: {
      content:
        `✅ Added \`${ip}\` to the **${modpack.display_name}** allowlist (expires in 7 days).` +
        mcLine +
        serverLine,
      flags: 64,
    },
  });
}

async function lookupMinecraftUuid(username: string): Promise<{ name: string; uuid: string } | null> {
  try {
    const res = await fetch(`https://api.mojang.com/users/profiles/minecraft/${encodeURIComponent(username)}`);
    if (!res.ok) return null;
    const data = await res.json() as { id: string; name: string };
    // Mojang returns UUID without dashes — insert them
    const id = data.id;
    const uuid = `${id.slice(0,8)}-${id.slice(8,12)}-${id.slice(12,16)}-${id.slice(16,20)}-${id.slice(20)}`;
    return { name: data.name, uuid };
  } catch {
    return null;
  }
}

function isValidIp(ip: string): boolean {
  if (/^(\d{1,3}\.){3}\d{1,3}$/.test(ip)) {
    return ip.split(".").every((n) => parseInt(n) <= 255);
  }
  if (/^[0-9a-fA-F:]+$/.test(ip) && ip.includes(":")) return true;
  return false;
}
