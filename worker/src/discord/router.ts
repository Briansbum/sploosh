import { verifyDiscordRequest } from "./verify";
import { handleModpacks } from "../commands/modpacks";
import { handleStatus } from "../commands/status";
import { handleStart } from "../commands/start";
import { handleStop } from "../commands/stop";
import { handleAllowlist } from "../commands/allowlist";
import { handleRevoke } from "../commands/revoke";
import type { Env } from "../types";

const PING = 1;
const APPLICATION_COMMAND = 2;

export async function handleInteraction(
  req: Request,
  env: Env,
  ctx: ExecutionContext,
): Promise<Response> {
  const { valid, body } = await verifyDiscordRequest(req, env.DISCORD_PUBLIC_KEY);
  if (!valid) {
    return new Response("Invalid signature", { status: 401 });
  }

  const interaction = JSON.parse(body);

  // Acknowledge Discord's ping
  if (interaction.type === PING) {
    return json({ type: 1 });
  }

  if (interaction.type === APPLICATION_COMMAND) {
    const name = interaction.data?.name as string;
    const userId = interaction.member?.user?.id ?? interaction.user?.id ?? "unknown";

    switch (name) {
      case "modpacks":
        return handleModpacks(env);
      case "status":
        return handleStatus(interaction, env, userId);
      case "start":
        return handleStart(interaction, env, ctx, userId);
      case "stop":
        return handleStop(interaction, env, userId);
      case "allowlist":
        return handleAllowlist(interaction, env, ctx, userId, req);
      case "revoke":
        return handleRevoke(interaction, env, userId);
      default:
        return json({ type: 4, data: { content: "Unknown command." } });
    }
  }

  return new Response("Unhandled interaction type", { status: 400 });
}

export function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
