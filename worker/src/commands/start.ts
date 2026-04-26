import { getModpack, getServerState, setServerStatus } from "../db";
import { createFleet, deleteFleet, getFleetInstance } from "../aws/ec2";
import { checkRateLimit } from "../ratelimit";
import type { Env } from "../types";

// Discord deferred response — we return immediately and patch later
const DEFERRED_CHANNEL_MESSAGE = 5;
const PATCH_URL = (appId: string, token: string) =>
  `https://discord.com/api/v10/webhooks/${appId}/${token}/messages/@original`;

export async function handleStart(
  interaction: Record<string, unknown>,
  env: Env,
  ctx: ExecutionContext,
  userId: string,
): Promise<Response> {
  const options = (interaction.data as Record<string, unknown>)?.options as
    | Array<{ name: string; value: unknown }>
    | undefined;
  const modpackName = options?.find((o) => o.name === "modpack")?.value as string | undefined;

  if (!modpackName) {
    return Response.json({ type: 4, data: { content: "Usage: `/start modpack:<name>`", flags: 64 } });
  }

  const rl = await checkRateLimit(env, userId, "start");
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
    return Response.json({
      type: 4,
      data: { content: `Unknown modpack: \`${modpackName}\``, flags: 64 },
    });
  }

  if (state?.status === "running" || state?.status === "starting") {
    const ip = state.public_ip ? `\nConnect: \`${state.public_ip}:25565\`` : "";
    return Response.json({
      type: 4,
      data: { content: `**${modpack.display_name}** is already ${state.status}.${ip}`, flags: 64 },
    });
  }

  // Defer immediately — EC2 fleet start can take 2-4 min
  const token = (interaction as Record<string, string>).token;
  ctx.waitUntil(doStart(env, modpack.launch_template_id, modpackName, modpack.display_name, token));

  return Response.json({ type: DEFERRED_CHANNEL_MESSAGE });
}

async function doStart(
  env: Env,
  launchTemplateId: string,
  modpackName: string,
  displayName: string,
  token: string,
): Promise<void> {
  let fleetId: string | undefined;
  try {
    const fleet = await createFleet(env, launchTemplateId);
    fleetId = fleet.fleetId;
    await setServerStatus(env, modpackName, "starting", null, null, fleetId);

    // Poll for the instance to come up (max 10 minutes)
    let instance: { instanceId: string; publicIp: string } | null = null;
    for (let i = 0; i < 60; i++) {
      await sleep(10_000);
      instance = await getFleetInstance(env, fleetId);
      if (instance?.publicIp) break;
    }

    if (!instance?.publicIp) {
      try { await deleteFleet(env, fleetId); } catch {}
      await setServerStatus(env, modpackName, "stopped", null, null, null);
      await patchReply(env, token, `❌ **${displayName}** failed to start (timeout waiting for instance).`);
      return;
    }

    await setServerStatus(env, modpackName, "running", instance.instanceId, instance.publicIp, fleetId);

    await patchReply(
      env,
      token,
      `🟢 **${displayName}** is starting up!\nConnect: \`${instance.publicIp}:25565\`\n(May take 3-5 min for the world to load)`,
    );
  } catch (e) {
    if (fleetId) {
      try { await deleteFleet(env, fleetId); } catch {}
      await setServerStatus(env, modpackName, "stopped", null, null, null);
    }
    await patchReply(env, token, `❌ Failed to start **${displayName}**: ${String(e)}`);
  }
}

async function patchReply(env: Env, token: string, content: string): Promise<void> {
  await fetch(PATCH_URL(env.DISCORD_APP_ID, token), {
    method: "PATCH",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bot ${env.DISCORD_BOT_TOKEN}`,
    },
    body: JSON.stringify({ content }),
  });
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
