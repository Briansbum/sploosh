export interface Env {
  DB: D1Database;

  // AWS credentials for EC2 Fleet + SG management
  AWS_ACCESS_KEY_ID: string;
  AWS_SECRET_ACCESS_KEY: string;
  AWS_REGION: string;

  // Discord
  DISCORD_PUBLIC_KEY: string;
  DISCORD_APP_ID: string;
  DISCORD_BOT_TOKEN: string;

  // Internal security
  ADMIN_SECRET: string;
  IDLE_WEBHOOK_SECRET: string;

  // Comma-separated list of Discord guild IDs permitted to use this bot
  ALLOWED_GUILD_IDS: string;
}

export interface Modpack {
  name: string;
  display_name: string;
  ami_id: string;
  launch_template_id: string;
  security_group_id: string;
  s3_prefix: string;
  mrpack_url: string;
  pack_toml_url: string;
}

export interface ServerState {
  modpack: string;
  status: "stopped" | "starting" | "running" | "stopping";
  instance_id: string | null;
  public_ip: string | null;
  fleet_id: string | null;
  last_seen: number | null;
}

export interface AllowlistEntry {
  modpack: string;
  discord_user_id: string;
  ip: string;
  sg_rule_id: string;
  added_at: number;
  expires_at: number;
  minecraft_username: string;
  minecraft_uuid: string;
}
