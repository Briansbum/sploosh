import { getModpack, getServerState, setServerStatus } from "../db";
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

  // Don't terminate the fleet here — an external EC2 termination SIGKILLs the
  // JVM before its shutdown hooks flush the world. Instead just flip status to
  // "stopping"; the in-instance mc-stop-poller observes this, saves the world
  // to completion, then calls /idle-shutdown to terminate the fleet once the
  // save is durable. Preserve fleet/IP fields so that callback can find the
  // fleet to delete.
  await setServerStatus(
    env,
    modpackName,
    "stopping",
    state.instance_id,
    state.public_ip,
    state.fleet_id,
  );

  return Response.json({
    type: 4,
    data: {
      content: `🟠 **${modpack.display_name}** is stopping — saving the world, then shutting down.`,
    },
  });
}
