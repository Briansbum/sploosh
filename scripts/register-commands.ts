#!/usr/bin/env -S npx tsx
// register-commands.ts — one-shot Discord slash command upsert.
// Run: DISCORD_APP_ID=... DISCORD_BOT_TOKEN=... npx tsx scripts/register-commands.ts
//
// Or: nix develop -c npx tsx scripts/register-commands.ts

const APP_ID = process.env.DISCORD_APP_ID ?? (() => { throw new Error("DISCORD_APP_ID required"); })();
const TOKEN = process.env.DISCORD_BOT_TOKEN ?? (() => { throw new Error("DISCORD_BOT_TOKEN required"); })();
const GUILD_ID = process.env.DISCORD_GUILD_ID;

const MODPACK_OPTION = {
  name: "modpack",
  description: "Modpack name (e.g. all-the-forge-10)",
  type: 3, // STRING
  required: true,
  autocomplete: true,
};

const commands = [
  {
    name: "modpacks",
    description: "List available modpacks and their download links",
  },
  {
    name: "status",
    description: "Show server status",
    options: [{ ...MODPACK_OPTION, required: false }],
  },
  {
    name: "start",
    description: "Start a Minecraft server",
    options: [MODPACK_OPTION],
    default_member_permissions: "0",  // hidden from everyone by default; grant via role in Server Settings
  },
  {
    name: "stop",
    description: "Stop a Minecraft server (saves world first)",
    options: [MODPACK_OPTION],
    default_member_permissions: "0",
  },
  {
    name: "allowlist",
    description: "Add your IP to the server allowlist (7-day TTL)",
    options: [
      MODPACK_OPTION,
      {
        name: "ip",
        description: "Your public IP (visit /whatismyip if unsure)",
        type: 3, // STRING
        required: false,
      },
      {
        name: "minecraft_username",
        description: "Your Minecraft username (adds you to the server whitelist)",
        type: 3, // STRING
        required: false,
      },
    ],
  },
  {
    name: "revoke",
    description: "Remove your IP from the server allowlist",
    options: [MODPACK_OPTION],
  },
  {
    name: "help",
    description: "How to install the modpack and use this bot",
  },
];

const endpoint = GUILD_ID
  ? `https://discord.com/api/v10/applications/${APP_ID}/guilds/${GUILD_ID}/commands`
  : `https://discord.com/api/v10/applications/${APP_ID}/commands`;

console.log(GUILD_ID ? `Registering guild commands for guild ${GUILD_ID}` : "Registering global commands");

const res = await fetch(
  endpoint,
  {
    method: "PUT",
    headers: {
      Authorization: `Bot ${TOKEN}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(commands),
  },
);

const data = await res.json();
if (!res.ok) {
  console.error("Failed:", JSON.stringify(data, null, 2));
  process.exit(1);
}

console.log(`Registered ${(data as unknown[]).length} commands.`);
for (const cmd of data as Array<{ name: string; id: string }>) {
  console.log(`  /${cmd.name} (${cmd.id})`);
}
