import { getModpack, getServerState, upsertAllowlist, getAllowlistEntry } from "../db";
import { authorizeSgIngress } from "../aws/ec2";
import type { Env } from "../types";

export async function handleAllowlist(
  interaction: Record<string, unknown>,
  env: Env,
  ctx: ExecutionContext,
  userId: string,
  req: Request,
): Promise<Response> {
  const options = (interaction.data as Record<string, unknown>)?.options as
    | Array<{ name: string; value: unknown }>
    | undefined;
  const modpackName = options?.find((o) => o.name === "modpack")?.value as string | undefined;
  let ip = options?.find((o) => o.name === "ip")?.value as string | undefined;

  if (!modpackName) {
    return Response.json({ type: 4, data: { content: "Usage: `/allowlist modpack:<name> [ip:<your-ip>]`", flags: 64 } });
  }

  const modpack = await getModpack(env, modpackName);
  if (!modpack) {
    return Response.json({ type: 4, data: { content: `Unknown modpack: \`${modpackName}\``, flags: 64 } });
  }

  // If no IP provided, use CF-Connecting-IP and ask for confirmation
  if (!ip) {
    const cfIp = req.headers.get("CF-Connecting-IP");
    if (!cfIp) {
      return Response.json({
        type: 4,
        data: {
          content:
            "Could not auto-detect your IP.\nRun `/allowlist modpack:" +
            modpackName +
            " ip:<your-ip>` — visit https://sploosh.workers.dev/whatismyip to find your IP.",
          flags: 64,
        },
      });
    }
    ip = cfIp;
  }

  // Basic IPv4/IPv6 validation
  if (!isValidIp(ip)) {
    return Response.json({ type: 4, data: { content: `\`${ip}\` doesn't look like a valid IP address.`, flags: 64 } });
  }

  // Check if already allowlisted with same IP
  const existing = await getAllowlistEntry(env, modpackName, userId);
  if (existing?.ip === ip) {
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

  // Add SG rule immediately if server is running; otherwise just record it.
  // The scheduled reconciler will add the rule when the server next starts.
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

  await upsertAllowlist(env, modpackName, userId, ip, sgRuleId);

  const serverLine =
    state?.status === "running" && state.public_ip
      ? `\nConnect now: \`${state.public_ip}:25565\``
      : "\nStart the server with `/start modpack:" + modpackName + "`.";

  return Response.json({
    type: 4,
    data: {
      content:
        `✅ Added \`${ip}\` to the **${modpack.display_name}** allowlist (expires in 7 days).` +
        serverLine,
      flags: 64,
    },
  });
}

function isValidIp(ip: string): boolean {
  // IPv4
  if (/^(\d{1,3}\.){3}\d{1,3}$/.test(ip)) {
    return ip.split(".").every((n) => parseInt(n) <= 255);
  }
  // IPv6 (basic check)
  if (/^[0-9a-fA-F:]+$/.test(ip) && ip.includes(":")) return true;
  return false;
}
