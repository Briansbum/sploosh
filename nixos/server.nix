# Server bootstrap: reads user-data JSON at first boot, restores the latest
# restic snapshot, and writes the runtime env file for downstream services.
#
# Expected user-data JSON:
#   {
#     "modpack":          "create-central",
#     "rcon_password":    "...",
#     "s3_bucket":        "sploosh-minecraft-backups",
#     "s3_prefix":        "create-central/restic",
#     "restic_password":  "...",
#     "pack_toml_url":    "https://owner.github.io/repo/create-central/pack.toml"
#   }
#
# nix-minecraft substitutes @RCON_PASSWORD@ in server.properties at service
# start using the environment — no manual sed patching needed here.
{ pkgs, lib, ... }:

let
  bootstrapScript = pkgs.writeShellApplication {
    name = "mc-bootstrap";
    runtimeInputs = with pkgs; [
      restic
      awscli2
      jq
      curl
    ];
    text = ''
      set -euo pipefail

      # ── Read user-data via IMDSv2 ─────────────────────────────────────────

      TOKEN=$(curl -sf -X PUT http://169.254.169.254/latest/api/token \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
      USERDATA=$(curl -sf -H "X-aws-ec2-metadata-token: $TOKEN" \
        http://169.254.169.254/latest/user-data 2>/dev/null || echo "{}")

      RCON_PASSWORD=$(echo   "$USERDATA" | jq -r '.rcon_password // ""')
      S3_BUCKET=$(echo       "$USERDATA" | jq -r '.s3_bucket // "sploosh-minecraft-backups"')
      S3_PREFIX=$(echo       "$USERDATA" | jq -r '.s3_prefix // "default/restic"')
      RESTIC_PASS=$(echo     "$USERDATA" | jq -r '.restic_password // ""')
      MODPACK=$(echo         "$USERDATA" | jq -r '.modpack // "default"')
      IDLE_WEBHOOK=$(echo    "$USERDATA" | jq -r '.idle_webhook // ""')
      WEBHOOK_SECRET=$(echo  "$USERDATA" | jq -r '.webhook_secret // ""')
      PACK_TOML_URL=$(echo   "$USERDATA" | jq -r '.pack_toml_url // ""')

      # ── Write env for downstream services (backup, watchdog, nix-minecraft) ─
      # nix-minecraft's ExecStartPre substitutes @VARNAME@ from the environment,
      # so RCON_PASSWORD here is what fills in server.properties automatically.

      mkdir -p /run/minecraft
      chmod 700 /run/minecraft

      cat > /run/minecraft/env <<EOF
RCON_PASSWORD=$RCON_PASSWORD
RESTIC_REPOSITORY=s3:s3.eu-west-2.amazonaws.com/$S3_BUCKET/$S3_PREFIX
RESTIC_PASSWORD=$RESTIC_PASS
SPLOOSH_MODPACK=$MODPACK
WORKER_IDLE_WEBHOOK=$IDLE_WEBHOOK
WORKER_WEBHOOK_SECRET=$WEBHOOK_SECRET
PACK_TOML_URL=$PACK_TOML_URL
EOF
      chmod 600 /run/minecraft/env

      # ── Restore latest restic snapshot ───────────────────────────────────

      if [ -n "$RESTIC_PASS" ]; then
        export RESTIC_REPOSITORY="s3:s3.eu-west-2.amazonaws.com/$S3_BUCKET/$S3_PREFIX"
        export RESTIC_PASSWORD="$RESTIC_PASS"

        if ! restic snapshots --json 2>/dev/null | jq -e 'length > 0' >/dev/null 2>&1; then
          echo "No repo or no snapshots — initialising restic repository..."
          restic init || true
          echo "Starting fresh."
        else
          echo "Restoring latest snapshot..."
          SVCDIR="/srv/minecraft/$MODPACK"
          restic restore latest \
            --target / \
            --tag "modpack:$MODPACK" \
            --include "$SVCDIR/world*" \
            --include "$SVCDIR/banned-players.json" \
            --include "$SVCDIR/banned-ips.json"
        fi
      fi

      echo "Bootstrap complete."
    '';
  };

in
{
  # Run bootstrap before any minecraft service starts.
  # Must run after network is up so IMDS is reachable.
  systemd.services.mc-bootstrap = {
    description = "Minecraft server bootstrap";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    before = [ "minecraft-server-create-central.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${bootstrapScript}/bin/mc-bootstrap";
    };
  };

  # Propagate the env file to all minecraft server services.
  # nix-minecraft's ExecStartPre uses ENVIRON to substitute @VARNAME@ in
  # server.properties, so RCON_PASSWORD from the env file fills the placeholder.
  systemd.services."minecraft-server-create-central" = {
    after = [ "mc-bootstrap.service" ];
    requires = [ "mc-bootstrap.service" ];
    serviceConfig.EnvironmentFile = "/run/minecraft/env";
  };

  # Companion timer: merges Discord /allowlist players into whitelist.json every 60s.
  systemd.services.mc-sync-whitelist = let
    syncScript = pkgs.writeShellApplication {
      name = "mc-sync-whitelist";
      runtimeInputs = [ pkgs.curl pkgs.jq ];
      text = ''
        MODPACK="''${SPLOOSH_MODPACK:-create-central}"
        WHITELIST="/srv/minecraft/$MODPACK/whitelist.json"
        DYNAMIC=$(curl -sf --max-time 10 "https://sploosh.workers.dev/api/whitelist/$MODPACK" || echo "[]")

        if [ ! -f "$WHITELIST" ]; then
          # Server hasn't been initialised yet (or modpack has no whitelist file);
          # nothing to merge into. Next tick will retry.
          exit 0
        fi

        MERGED=$(jq -s '.[0] + .[1] | unique_by(.uuid)' "$WHITELIST" <(echo "$DYNAMIC"))

        # Only write if the merge changed the file.
        if ! diff -q <(echo "$MERGED") "$WHITELIST" >/dev/null 2>&1; then
          echo "$MERGED" > "$WHITELIST"
        fi
      '';
    };
  in {
    description = "Sync Discord allowlist into Minecraft whitelist";
    after = [ "network-online.target" "mc-bootstrap.service" ];
    wants = [ "network-online.target" ];
    requires = [ "mc-bootstrap.service" ];
    serviceConfig = {
      Type = "oneshot";
      EnvironmentFile = "/run/minecraft/env";
      ExecStart = "${syncScript}/bin/mc-sync-whitelist";
    };
  };

  systemd.timers.mc-sync-whitelist = {
    description = "Periodic Discord allowlist → Minecraft whitelist sync";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "30s";
      OnUnitActiveSec = "60s";
      AccuracySec = "5s";
      Unit = "mc-sync-whitelist.service";
    };
  };
}
