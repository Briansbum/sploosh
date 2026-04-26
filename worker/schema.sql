-- D1 schema for sploosh Cloudflare Worker
-- Apply with: wrangler d1 execute sploosh --file schema.sql

CREATE TABLE IF NOT EXISTS modpacks (
  name              TEXT PRIMARY KEY,
  display_name      TEXT NOT NULL,
  ami_id            TEXT NOT NULL DEFAULT '',
  launch_template_id TEXT NOT NULL DEFAULT '',
  security_group_id TEXT NOT NULL DEFAULT '',
  s3_prefix         TEXT NOT NULL,
  mrpack_url        TEXT NOT NULL DEFAULT '',
  pack_toml_url     TEXT NOT NULL DEFAULT ''
);

CREATE TABLE IF NOT EXISTS server_state (
  modpack     TEXT PRIMARY KEY REFERENCES modpacks(name),
  status      TEXT NOT NULL DEFAULT 'stopped', -- stopped|starting|running|stopping
  instance_id TEXT,
  public_ip   TEXT,
  fleet_id    TEXT, -- ephemeral; set on /start, cleared on /stop
  last_seen   INTEGER
);

CREATE TABLE IF NOT EXISTS allowlist (
  modpack            TEXT NOT NULL,
  discord_user_id    TEXT NOT NULL,
  ip                 TEXT NOT NULL,
  sg_rule_id         TEXT NOT NULL DEFAULT '',
  added_at           INTEGER NOT NULL,
  expires_at         INTEGER NOT NULL,
  minecraft_username TEXT NOT NULL DEFAULT '',
  minecraft_uuid     TEXT NOT NULL DEFAULT '',
  PRIMARY KEY (modpack, discord_user_id)
);

CREATE TABLE IF NOT EXISTS rate_limits (
  user_id      TEXT NOT NULL,
  command      TEXT NOT NULL,
  attempts     INTEGER NOT NULL DEFAULT 1,
  window_start INTEGER NOT NULL,
  PRIMARY KEY (user_id, command)
);

-- Seed modpacks (update ami_id/fleet_id/sg_id after tofu apply)
INSERT OR IGNORE INTO modpacks (name, display_name, s3_prefix, mrpack_url, pack_toml_url)
VALUES ('create-central', 'Create Central', 'create-central/restic', '', '');

INSERT OR IGNORE INTO server_state (modpack, status) VALUES ('create-central', 'stopped');
