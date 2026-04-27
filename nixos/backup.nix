# restic-based backups: incremental every 10 min + final snapshot on shutdown.
# Also handles spot interruption detection via IMDS.
{ pkgs, lib, ... }:

let
  # ── Incremental backup timer ───────────────────────────────────────────────

  backupScript = pkgs.writeShellApplication {
    name = "mc-backup";
    runtimeInputs = with pkgs; [ restic mcrcon jq curl ];
    text = ''
      set -euo pipefail

      # shellcheck source=/dev/null
      source /run/minecraft/env

      SVCDIR="/srv/minecraft/$SPLOOSH_MODPACK"
      RCON_PORT=25575

      # Flush world to disk before snapshotting
      mcrcon -H 127.0.0.1 -P "$RCON_PORT" -p "$RCON_PASSWORD" "save-off" || true
      mcrcon -H 127.0.0.1 -P "$RCON_PORT" -p "$RCON_PASSWORD" "save-all flush" || true

      restic backup "$SVCDIR" \
        --tag "modpack:$SPLOOSH_MODPACK" \
        --tag "incremental" \
        --exclude "$SVCDIR/logs" \
        --exclude "$SVCDIR/crash-reports"

      # Re-enable autosave
      mcrcon -H 127.0.0.1 -P "$RCON_PORT" -p "$RCON_PASSWORD" "save-on" || true

      # Prune old snapshots (cheap: only runs after backup)
      restic forget \
        --tag "modpack:$SPLOOSH_MODPACK" \
        --keep-hourly 12 \
        --keep-daily 14 \
        --keep-weekly 8 \
        --prune
    '';
  };

  # ── Final backup (clean shutdown / spot reclaim) ───────────────────────────

  finalBackupScript = pkgs.writeShellApplication {
    name = "mc-backup-final";
    runtimeInputs = with pkgs; [ restic mcrcon ];
    text = ''
      set -euo pipefail
      # shellcheck source=/dev/null
      source /run/minecraft/env

      SVCDIR="/srv/minecraft/$SPLOOSH_MODPACK"

      mcrcon -H 127.0.0.1 -P 25575 -p "$RCON_PASSWORD" "save-off" || true
      mcrcon -H 127.0.0.1 -P 25575 -p "$RCON_PASSWORD" "save-all flush" || true

      restic backup "$SVCDIR" \
        --tag "modpack:$SPLOOSH_MODPACK" \
        --tag "final" \
        --exclude "$SVCDIR/logs" \
        --exclude "$SVCDIR/crash-reports"

      mcrcon -H 127.0.0.1 -P 25575 -p "$RCON_PASSWORD" "save-on" || true
    '';
  };

  # ── Spot interruption handler ──────────────────────────────────────────────

  spotHandlerScript = pkgs.writeShellApplication {
    name = "mc-spot-handler";
    runtimeInputs = with pkgs; [ curl jq mcrcon ];
    text = ''
      set -euo pipefail
      # shellcheck source=/dev/null
      source /run/minecraft/env 2>/dev/null || true

      IMDS_TOKEN=$(curl -sf -X PUT \
        "http://169.254.169.254/latest/api/token" \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" || echo "")

      imds_get() {
        if [ -n "$IMDS_TOKEN" ]; then
          curl -sf -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
            "http://169.254.169.254/latest/meta-data/$1" 2>/dev/null || echo ""
        else
          curl -sf "http://169.254.169.254/latest/meta-data/$1" 2>/dev/null || echo ""
        fi
      }

      while true; do
        # Check for spot termination notice
        action=$(imds_get "spot/instance-action" | jq -r '.action // ""' 2>/dev/null || echo "")

        if [ "$action" = "terminate" ]; then
          echo "Spot termination notice received, saving..."
          mcrcon -H 127.0.0.1 -P 25575 -p "$RCON_PASSWORD" \
            "say §cSpot reclaim in 2 minutes — saving world now" || true
          systemctl start mc-backup-final.service
          sleep 90
          systemctl poweroff
        fi

        # Also check rebalance recommendation (pre-emptive backup)
        rebalance=$(imds_get "events/recommendations/rebalance" | jq -r '.noticeTime // ""' 2>/dev/null || echo "")
        if [ -n "$rebalance" ]; then
          echo "Rebalance recommendation received, taking backup..."
          systemctl start mc-backup.service || true
        fi

        sleep 5
      done
    '';
  };

in
{
  # Incremental backup every 10 minutes while the server is running
  systemd.services.mc-backup = {
    description = "Minecraft incremental backup";
    after = [ "mc-bootstrap.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${backupScript}/bin/mc-backup";
      # Run as root so it can read the server's data dir
    };
  };

  systemd.timers.mc-backup = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnUnitActiveSec = "10m";
      OnBootSec = "15m"; # first backup 15 min after boot
    };
  };

  # Final backup — runs before system shutdown
  systemd.services.mc-backup-final = {
    description = "Minecraft final backup (shutdown)";
    after = [ "mc-bootstrap.service" ];
    # Ensure this runs before the minecraft service stops
    before = [ "shutdown.target" "reboot.target" "halt.target" ];
    wantedBy = [ "shutdown.target" "reboot.target" "halt.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${finalBackupScript}/bin/mc-backup-final";
      TimeoutStartSec = "300"; # 5 minutes max for final backup
    };
  };

  # Spot interruption poller (runs continuously in the background)
  systemd.services.mc-spot-handler = {
    description = "EC2 spot interruption handler";
    wantedBy = [ "multi-user.target" ];
    after = [ "mc-bootstrap.service" "network.target" ];
    serviceConfig = {
      Type = "simple";
      Restart = "always";
      RestartSec = "5s";
      ExecStart = "${spotHandlerScript}/bin/mc-spot-handler";
    };
  };
}
