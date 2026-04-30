import { getModpack, listModpacks } from "../db";
import type { Env } from "../types";

const PAGES_URL = "https://briansbum.github.io/sploosh";

function buildHelpText(modpackName?: string, mrpackUrl?: string, packTomlUrl?: string, displayName?: string): string {
  const installSection = modpackName && mrpackUrl && packTomlUrl
    ? `\
**Installing ${displayName ?? modpackName} (Prism Launcher)**
1. Download & install Prism Launcher: <https://prismlauncher.org>
2. In Prism, click **Add Instance → Import** and paste this link:
   \`${mrpackUrl}\`
3. Launch the instance — mods download automatically on first run.
   *(If you see an "unverified app" or security warning, just click past it.)*

**Auto-updates (recommended)**
Right-click the instance → **Edit** → **Settings** → tick **Custom commands**, then set the **Pre-launch command** to:
\`\`\`
java -jar packwiz-installer-bootstrap.jar ${packTomlUrl}
\`\`\`
*(If prompted about an unsigned jar on launch, click past the warning.)*`
    : `\
**Installing the modpack (Prism Launcher)**
1. Download & install Prism Launcher: <https://prismlauncher.org>
2. Go to the modpack page: <${PAGES_URL}>
3. Find the pack you want and copy its **Install link**
4. In Prism, click **Add Instance → Import** and paste the link
5. Launch the instance — mods download automatically on first run.
   *(If you see an "unverified app" or security warning, just click past it.)*

**Auto-updates (recommended)**
Right-click the instance → **Edit** → **Settings** → tick **Custom commands**, then set the **Pre-launch command** to the command shown for your pack on <${PAGES_URL}>.
*(If prompted about an unsigned jar on launch, click past the warning.)*`;

  return `\
**Sploosh — Minecraft server help**

${installSection}

**Commands**
\`/modpacks\` — list available packs and their download links
\`/status [modpack]\` — show whether the server is running and the IP (if you're allowlisted)
\`/start modpack:<name>\` — start the server *(admins only)*
\`/stop modpack:<name>\` — save & stop the server *(admins only)*
\`/allowlist modpack:<name> ip:<your-ip>\` — open port 25565 for your IP (7-day TTL); find your IP at <https://sploosh.workers.dev/whatismyip>
\`/revoke modpack:<name>\` — remove your IP from the allowlist
\`/help [modpack]\` — show this help, with install links for a specific pack

**Idle shutdown**
The server shuts down automatically after **15 minutes** with no players online. Your world is saved to S3 first and restored on the next \`/start\`.`;
}

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
    return Response.json({
      type: 4,
      data: { content: buildHelpText(modpack.name, modpack.mrpack_url, modpack.pack_toml_url, modpack.display_name), flags: 64 },
    });
  }

  return Response.json({ type: 4, data: { content: buildHelpText(), flags: 64 } });
}
