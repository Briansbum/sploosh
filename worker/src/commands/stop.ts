import { getModpack, getServerState, setServerStatus } from "../db";
import { deleteFleet } from "../aws/ec2";
import { checkRateLimit } from "../ratelimit";
import type { Env } from "../types";

export async function handleStop(
  interaction: Record<string, unknown>,
  env: Env,
  userId: string,
): Promise<Response> {
  const options = (interaction.data as Record<string, unknown>)?.options as
    | Array<{ name: string; value: unknown }>
    | undefined;
  const modpackName = options?.find((o) => o.name === "modpack")?.value as string | undefined;

  if (!modpackName) {
    return Response.json({ type: 4, data: { content: "Usage: `/stop modpack:<name>`", flags: 64 } });
  }

  const rl = await checkRateLimit(env, userId, "stop");
  if (rl.limited) {
    return Response.json({
      type: 4,
      data: { content: `You're doing that too fast. Try again in ${rl.retryAfterSec}s.`, flags: 64 },
    });
  }

  const [modpack, state] = await Promise.all([
    getModpack(env, modpackName),
    getServerState(env, modpackName),
  ]);

  if (!modpack) {
    return Response.json({ type: 4, data: { content: `Unknown modpack: \`${modpackName}\``, flags: 64 } });
  }
  if (state?.status === "stopped") {
    return Response.json({ type: 4, data: { content: `**${modpack.display_name}** is already stopped.`, flags: 64 } });
  }

  if (!state?.fleet_id) {
    await setServerStatus(env, modpackName, "stopped", null, null, null);
    return Response.json({ type: 4, data: { content: `**${modpack.display_name}** has no active fleet — marked as stopped.`, flags: 64 } });
  }

  try {
    await deleteFleet(env, state.fleet_id);
  } catch (e) {
    return Response.json({
      type: 4,
      data: { content: `❌ Failed to stop **${modpack.display_name}**: ${String(e)}`, flags: 64 },
    });
  }
  await setServerStatus(env, modpackName, "stopping", null, null, null);

  return Response.json({
    type: 4,
    data: {
      content: `🟠 **${modpack.display_name}** is stopping — final backup will run before shutdown.`,
    },
  });
}
