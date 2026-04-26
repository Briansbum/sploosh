const PACK_URL = "https://briansbum.github.io/sploosh";

const HELP_TEXT = `\
**Sploosh — Minecraft server help**

**Installing the modpack (Prism Launcher)**
1. Download & install Prism Launcher: <https://prismlauncher.org>
2. In Prism, click **Add Instance → Import** and paste the pack URL:
   \`${PACK_URL}\`
   (or browse to the modpack page and click **Install**)
3. Launch the instance — mods download automatically on first run.

**Commands**
\`/modpacks\` — list available packs and their pack URLs
\`/status [modpack]\` — show whether the server is running and the IP (if you're allowlisted)
\`/start modpack:<name>\` — start the server *(admins only)*
\`/stop modpack:<name>\` — save & stop the server *(admins only)*
\`/allowlist modpack:<name> [ip:<your-ip>]\` — open port 25565 for your IP (7-day TTL); auto-detects your IP if omitted
\`/revoke modpack:<name>\` — remove your IP from the allowlist

**Idle shutdown**
The server shuts down automatically after **15 minutes** with no players online. Your world is saved to S3 first and restored on the next \`/start\`.`;

export function handleHelp(): Response {
  return Response.json({ type: 4, data: { content: HELP_TEXT, flags: 64 } });
}
