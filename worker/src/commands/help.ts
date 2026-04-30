import { getModpack, listModpacks } from "../db";
import type { Env } from "../types";

function packInstallSection(displayName: string, mrpackUrl: string, packTomlUrl: string): string {
  return `\
**Installing ${displayName} (Prism Launcher)**
1. Download & install Prism Launcher: <https://prismlauncher.org>
2. In Prism, click **Add Instance → Import** and paste this link:
   \`${mrpackUrl}\`
3. Right-click the instance → **Edit** → **Settings** → tick **Custom commands**, then set the **Pre-launch command** to:
   \`"$INST_JAVA" -jar "$INST_MC_DIR/mods/packwiz-installer-bootstrap.jar" ${packTomlUrl}\`
4. Launch — mods will update automatically on every launch.
   *(If you see a warning about a mod on launch, click the button to go to the main menu.)*`;
}

const COMMANDS = `\
**Commands**
\`/modpacks\` — list available packs and their download links
\`/status [modpack]\` — show whether the server is running and the IP (if you're allowlisted)
\`/start modpack:<name>\` — start the server *(admins only)*
\`/stop modpack:<name>\` — save & stop the server *(admins only)*
\`/allowlist modpack:<name> ip:<your-ip>\` — open port 25565 for your IP (7-day TTL); find your IP by searching "what is my ip" on Google
\`/revoke modpack:<name>\` — remove your IP from the allowlist
\`/help [modpack]\` — show this help, with install links for a specific pack

**Idle shutdown**
The server shuts down automatically after **15 minutes** with no players online. Your world is saved to S3 first and restored on the next \`/start\`.`;

export async function handleHelp(interaction: Record<string, unknown>, env: Env): Promise<Response> {
  const options = (interaction.data as Record<string, unknown>)?.options as
    | Array<{ name: string; value: unknown }>
    | undefined;
  const modpackName = options?.find((o) => o.name === "modpack")?.value as string | undefined;

  if (modpackName) {
    const modpack = await getModpack(env, modpackName);
    if (!modpack) {
      return Response.json({ type: 4, data: { content: `Unknown modpack: \`${modpackName}\``, flags: 64 } });
    }
    const content = `**Sploosh — Minecraft server help**\n\n${packInstallSection(modpack.display_name, modpack.mrpack_url, modpack.pack_toml_url)}\n\n${COMMANDS}`;
    return Response.json({ type: 4, data: { content, flags: 64 } });
  }

  // Generic help — list all packs with their install links
  const packs = await listModpacks(env);
  const packList = packs.length > 0
    ? packs.map((p) => `• **${p.display_name}** (\`${p.name}\`) — \`${p.mrpack_url}\``).join("\n")
    : "No packs configured yet.";

  const content = `\
**Sploosh — Minecraft server help**

**Installing a modpack (Prism Launcher)**
1. Download & install Prism Launcher: <https://prismlauncher.org>
2. In Prism, click **Add Instance → Import** and paste the install link for your pack:
${packList}
3. Right-click the instance → **Edit** → **Settings** → tick **Custom commands**, then set the **Pre-launch command** — run \`/help modpack:<name>\` to get the exact command for your pack.
4. Launch — mods will update automatically on every launch.
   *(If you see a warning about a mod on launch, click the button to go to the main menu.)*

${COMMANDS}`;

  return Response.json({ type: 4, data: { content, flags: 64 } });
}
