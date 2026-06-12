import { getModpack, getServerState, upsertAllowlist, getAllowlistEntry } from "../db";
import { authorizeSgIngress, revokeSgIngress } from "../aws/ec2";
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
  const ip = options?.find((o) => o.name === "ip")?.value as string | undefined;
  const mcUsername = options?.find((o) => o.name === "minecraft_username")?.value as string | undefined;

  if (!modpackName || (!ip && !mcUsername)) {
    return Response.json({
      type: 4,
      data: {
        content:
          "Usage: `/allowlist modpack:<name> [ip:<your-ip>] [minecraft_username:<ign>]`\n" +
          "At least one of `ip` or `minecraft_username` is required. You can run the command twice to set each separately.\n" +
          "Find your IP at https://sploosh.freestone-alex.workers.dev/whatismyip",
        flags: 64,
      },
    });
  }

  const modpack = await getModpack(env, modpackName);
  if (!modpack) {
    return Response.json({ type: 4, data: { content: `Unknown modpack: \`${modpackName}\``, flags: 64 } });
  }

  if (ip && !isValidIp(ip)) {
    return Response.json({ type: 4, data: { content: `\`${ip}\` doesn't look like a valid IP address.`, flags: 64 } });
  }

  // Attempt MC UUID resolution; surface errors rather than silently failing
  let mcResolved: { name: string; uuid: string } | null = null;
  let mcError: string | null = null;
  if (mcUsername) {
    const result = await lookupMinecraftUuid(mcUsername);
    if (result.data) {
      mcResolved = result.data;
    } else {
      mcError = result.error;
      if (!ip) {
        return Response.json({
          type: 4,
          data: {
            content: `Couldn't resolve Minecraft player \`${mcUsername}\`: ${mcError}\nYou can still add your IP now with \`/allowlist modpack:${modpackName} ip:<your-ip>\` and retry the username later.`,
            flags: 64,
          },
        });
      }
    }
  }

  const [existing, state] = await Promise.all([
    getAllowlistEntry(env, modpackName, userId),
    getServerState(env, modpackName),
  ]);

  // Merge new values over existing; keep existing fields when not being updated
  const finalIp = ip ?? existing?.ip ?? "";
  const finalMcUsername = mcResolved?.name ?? existing?.minecraft_username ?? "";
  const finalMcUuid = mcResolved?.uuid ?? existing?.minecraft_uuid ?? "";

  // Manage SG rule only when IP is changing
  let sgRuleId = existing?.sg_rule_id ?? "";
  if (ip && ip !== existing?.ip) {
    if (existing?.sg_rule_id && modpack.security_group_id) {
      try {
        await revokeSgIngress(env, modpack.security_group_id, existing.sg_rule_id, existing.ip);
      } catch { /* not fatal — rule may already be gone */ }
    }
    sgRuleId = "";
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
  }

  await upsertAllowlist(env, modpackName, userId, finalIp, sgRuleId, finalMcUsername, finalMcUuid);

  // Report back current stored state
  const ipLine = finalIp ? `IP: \`${finalIp}\`` : "IP: *(not set — run `/allowlist modpack:" + modpackName + " ip:<your-ip>`)*";
  const mcLine = finalMcUsername
    ? `Minecraft: \`${finalMcUsername}\``
    : "Minecraft: *(not set — run `/allowlist modpack:" + modpackName + " minecraft_username:<ign>`)*";

  const lines = [
    `**${modpack.display_name}** allowlist state for <@${userId}>:`,
    ipLine,
    mcLine,
  ];

  if (mcError) {
    lines.push(`\n⚠️ Couldn't resolve \`${mcUsername}\`: ${mcError}\nRetry with \`/allowlist modpack:${modpackName} minecraft_username:${mcUsername}\` once the Mojang API is available.`);
  }

  if (state?.status === "running" && state.public_ip) {
    lines.push(`\nConnect: \`${state.public_ip}:25565\` (whitelist syncs within ~60s)`);
  } else {
    lines.push(`\nStart the server with \`/start modpack:${modpackName}\`.`);
  }

  return Response.json({
    type: 4,
    data: { content: lines.join("\n"), flags: 64 },
  });
}

async function lookupMinecraftUuid(
  username: string,
): Promise<{ data: { name: string; uuid: string } | null; error: string }> {
  try {
    const res = await fetch(
      `https://api.mojang.com/users/profiles/minecraft/${encodeURIComponent(username)}`,
    );
    if (!res.ok) {
      const body = await res.text().catch(() => "");
      const detail = body ? `: ${body.slice(0, 200)}` : "";
      return { data: null, error: `Mojang API returned HTTP ${res.status}${detail}` };
    }
    const data = (await res.json()) as { id: string; name: string };
    const id = data.id;
    const uuid = `${id.slice(0, 8)}-${id.slice(8, 12)}-${id.slice(12, 16)}-${id.slice(16, 20)}-${id.slice(20)}`;
    return { data: { name: data.name, uuid }, error: "" };
  } catch (e) {
    return { data: null, error: String(e) };
  }
}

function isValidIp(ip: string): boolean {
  if (/^(\d{1,3}\.){3}\d{1,3}$/.test(ip)) {
    return ip.split(".").every((n) => parseInt(n) <= 255);
  }
  if (/^[0-9a-fA-F:]+$/.test(ip) && ip.includes(":")) return true;
  return false;
}
