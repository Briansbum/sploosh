import { listModpacks } from "../db";
import { getServerState } from "../db";
import type { Env } from "../types";

export async function handleModpacks(env: Env): Response {
  const packs = await listModpacks(env);
  if (packs.length === 0) {
    return Response.json({ type: 4, data: { content: "No modpacks configured yet." } });
  }

  const lines = await Promise.all(
    packs.map(async (p) => {
      const state = await getServerState(env, p.name);
      const status = state?.status ?? "unknown";
      const emoji = { stopped: "⚫", starting: "🟡", running: "🟢", stopping: "🟠" }[status] ?? "❓";
      const links: string[] = [];
      if (p.mrpack_url) links.push(`[Download pack](${p.mrpack_url})`);
      if (p.pack_toml_url) links.push(`[pack.toml](${p.pack_toml_url})`);
      return `${emoji} **${p.display_name}** (\`${p.name}\`) — ${status}${links.length ? "\n  " + links.join(" · ") : ""}`;
    }),
  );

  return Response.json({
    type: 4,
    data: {
      content: "## Modpacks\n" + lines.join("\n"),
      flags: 64, // ephemeral
    },
  });
}
