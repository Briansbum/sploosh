import { getModpack, getServerState, getAllowlistEntry } from "../db";
import type { Env } from "../types";

export async function handleStatus(
  interaction: Record<string, unknown>,
  env: Env,
  userId: string,
): Promise<Response> {
  const options = (interaction.data as Record<string, unknown>)?.options as
    | Array<{ name: string; value: unknown }>
    | undefined;
  const modpackName = options?.find((o) => o.name === "modpack")?.value as string | undefined;

  if (!modpackName) {
    // Show all servers
    const { listModpacks, getServerState: gss } = await import("../db");
    const packs = await listModpacks(env);
    const lines = await Promise.all(
      packs.map(async (p) => {
        const state = await gss(env, p.name);
        return formatStatus(p.name, state?.status ?? "unknown", state?.public_ip ?? null, false);
      }),
    );
    return Response.json({ type: 4, data: { content: lines.join("\n"), flags: 64 } });
  }

  const modpack = await getModpack(env, modpackName);
  if (!modpack) {
    return Response.json({
      type: 4,
      data: { content: `Unknown modpack: \`${modpackName}\``, flags: 64 },
    });
  }

  const state = await getServerState(env, modpackName);
  const allowlisted = (await getAllowlistEntry(env, modpackName, userId)) !== null;
  const content = formatStatus(modpackName, state?.status ?? "unknown", state?.public_ip ?? null, allowlisted);

  return Response.json({ type: 4, data: { content, flags: 64 } });
}

function formatStatus(
  name: string,
  status: string,
  ip: string | null,
  showIp: boolean,
): string {
  const emoji = { stopped: "⚫", starting: "🟡", running: "🟢", stopping: "🟠" }[status] ?? "❓";
  let msg = `${emoji} **${name}** — ${status}`;
  if (status === "running" && showIp && ip) {
    msg += `\nConnect: \`${ip}:25565\``;
  } else if (status === "running" && !showIp) {
    msg += "\n(run \`/allowlist\` to see the IP)";
  }
  return msg;
}
