import { getModpack, removeAllowlist } from "../db";
import { revokeSgIngress } from "../aws/ec2";
import type { Env } from "../types";

export async function handleRevoke(
  interaction: Record<string, unknown>,
  env: Env,
  userId: string,
): Promise<Response> {
  const options = (interaction.data as Record<string, unknown>)?.options as
    | Array<{ name: string; value: unknown }>
    | undefined;
  const modpackName = options?.find((o) => o.name === "modpack")?.value as string | undefined;

  if (!modpackName) {
    return Response.json({ type: 4, data: { content: "Usage: `/revoke modpack:<name>`", flags: 64 } });
  }

  const modpack = await getModpack(env, modpackName);
  if (!modpack) {
    return Response.json({ type: 4, data: { content: `Unknown modpack: \`${modpackName}\``, flags: 64 } });
  }

  const entry = await removeAllowlist(env, modpackName, userId);
  if (!entry) {
    return Response.json({
      type: 4,
      data: { content: `You don't have an allowlist entry for **${modpack.display_name}**.`, flags: 64 },
    });
  }

  if (entry.sg_rule_id && modpack.security_group_id) {
    try {
      await revokeSgIngress(env, modpack.security_group_id, entry.sg_rule_id, entry.ip);
    } catch {
      // Not fatal — SG rule may already be gone
    }
  }

  return Response.json({
    type: 4,
    data: {
      content: `🗑️ Removed \`${entry.ip}\` from the **${modpack.display_name}** allowlist.`,
      flags: 64,
    },
  });
}
