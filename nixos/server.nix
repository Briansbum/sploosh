# Server bootstrap: reads user-data JSON at first boot, restores the latest
# restic snapshot, and writes the runtime env file for downstream services.
#
# Expected user-data JSON:
#   {
#     "modpack":          "create-central",
#     "rcon_password":    "...",
#     "s3_bucket":        "sploosh-minecraft-backups",
#     "s3_prefix":        "create-central/restic",
#     "restic_password":  "..."
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

      RCON_PASSWORD=$(echo "$USERDATA" | jq -r '.rcon_password // ""')
      S3_BUCKET=$(echo    "$USERDATA" | jq -r '.s3_bucket // "sploosh-minecraft-backups"')
      S3_PREFIX=$(echo    "$USERDATA" | jq -r '.s3_prefix // "default/restic"')
      RESTIC_PASS=$(echo  "$USERDATA" | jq -r '.restic_password // ""')
      MODPACK=$(echo      "$USERDATA" | jq -r '.modpack // "default"')

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
EOF
      chmod 600 /run/minecraft/env

      # ── Restore latest restic snapshot ───────────────────────────────────

      if [ -n "$RESTIC_PASS" ]; then
        export RESTIC_REPOSITORY="s3:s3.eu-west-2.amazonaws.com/$S3_BUCKET/$S3_PREFIX"
        export RESTIC_PASSWORD="$RESTIC_PASS"
        SVCDIR="/srv/minecraft/$MODPACK"

        if restic snapshots --json 2>/dev/null | jq -e 'length > 0' >/dev/null; then
          echo "Restoring latest snapshot to $SVCDIR..."
          mkdir -p "$SVCDIR"
          restic restore latest --target "$SVCDIR" --tag "modpack:$MODPACK"
        else
          echo "No snapshots found, starting fresh."
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
    after = [ "network-online.target" "cloud-init.service" ];
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

  # Companion service: merges Discord /allowlist players into whitelist.json after
  # the server is up, then reloads via RCON. Runs as a separate unit to avoid
  # conflicting with nix-minecraft's own ExecStartPost.
  systemd.services.mc-sync-whitelist = let
    syncScript = pkgs.writeShellApplication {
      name = "mc-sync-whitelist";
      runtimeInputs = [ pkgs.curl pkgs.jq pkgs.mcrcon ];
      text = ''
        MODPACK="''${SPLOOSH_MODPACK:-create-central}"
        WHITELIST="/srv/minecraft/$MODPACK/whitelist.json"
        DYNAMIC=$(curl -sf "https://sploosh.workers.dev/api/whitelist/$MODPACK" || echo "[]")
        if [ -f "$WHITELIST" ]; then
          MERGED=$(jq -s '.[0] + .[1] | unique_by(.uuid)' "$WHITELIST" <(echo "$DYNAMIC"))
          echo "$MERGED" > "$WHITELIST"
        fi
        # Retry until RCON is up (server takes ~10s to be ready)
        attempts=12
        while [ "$attempts" -gt 0 ]; do
          if mcrcon -H 127.0.0.1 -P 25575 -p "$RCON_PASSWORD" "whitelist reload" 2>/dev/null; then
            break
          fi
          attempts=$(( attempts - 1 ))
          sleep 5
        done
      '';
    };
  in {
    description = "Sync Discord allowlist into Minecraft whitelist";
    after = [ "minecraft-server-create-central.service" ];
    bindsTo = [ "minecraft-server-create-central.service" ];
    wantedBy = [ "minecraft-server-create-central.service" ];
    serviceConfig = {
      Type = "oneshot";
      EnvironmentFile = "/run/minecraft/env";
      ExecStart = "${syncScript}/bin/mc-sync-whitelist";
    };
  };
}
