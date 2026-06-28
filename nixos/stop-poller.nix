# Discord /stop poller: polls the CF worker for this modpack's desired state.
#
# Discord /stop no longer terminates the EC2 fleet directly — that raced the
# final save (an external EC2 termination SIGKILLs the JVM before its shutdown
# hooks flush). Instead /stop only flips D1 status to "stopping"; this service
# observes that, saves the world to completion *in-instance* (no external
# deadline), and only then asks the worker to terminate the fleet.
#
# Flow on observing "stopping":
#   1. systemctl start mc-backup-final.service — blocks until the world is saved
#      (JVM shutdown hooks flush) and the restic snapshot is taken.
#   2. POST /idle-shutdown — worker deletes the fleet now that the save is
#      durable; TerminateInstances is safe at this point.
#   3. systemctl poweroff — the fleet deletion will also terminate us.
{ pkgs, lib, ... }:

let
  pollerScript = pkgs.writeShellApplication {
    name = "mc-stop-poller";
    runtimeInputs = with pkgs; [ curl jq openssl gawk coreutils ];
    text = ''
      set -euo pipefail
      # shellcheck source=/dev/null
      source /run/minecraft/env

      POLL_SECONDS=15

      # The worker base URL is derived from the idle-shutdown webhook, matching
      # the heartbeat URL derivation in mc-bootstrap.
      BASE="''${WORKER_IDLE_WEBHOOK%/idle-shutdown}"
      STATE_URL="$BASE/api/server-state/$SPLOOSH_MODPACK"

      while true; do
        sleep "$POLL_SECONDS"

        # HMAC over the modpack name — same scheme as the idle/heartbeat webhooks.
        HMAC=$(printf '%s' "$SPLOOSH_MODPACK" | \
          openssl dgst -sha256 -hmac "$WORKER_WEBHOOK_SECRET" | \
          awk '{print $2}')

        status=$(curl -sf --max-time 10 -H "X-Sploosh-Sig: $HMAC" "$STATE_URL" \
          | jq -r '.status // ""' 2>/dev/null || echo "")

        if [ "$status" = "stopping" ]; then
          echo "Stop requested via Discord — saving world before shutdown."

          # 1. Save to completion. Blocks; no external deadline since nothing is
          #    terminating us yet. flock inside the unit serialises with any
          #    concurrent watchdog/spot trigger.
          systemctl start mc-backup-final.service || true

          # 2. Save is durable — ask the worker to terminate the fleet.
          curl -sf --max-time 10 -X POST "$WORKER_IDLE_WEBHOOK" \
            -H "Content-Type: application/json" \
            -H "X-Sploosh-Sig: $HMAC" \
            -d "{\"modpack\":\"$SPLOOSH_MODPACK\"}" || true

          # 3. Power off (fleet deletion above also terminates us).
          systemctl poweroff
        fi
      done
    '';
  };

in
{
  systemd.services.mc-stop-poller = {
    description = "Discord /stop poller";
    wantedBy = [ "multi-user.target" ];
    after = [ "mc-bootstrap.service" "network.target" ];
    serviceConfig = {
      Type = "simple";
      Restart = "always";
      RestartSec = "15s";
      # Brief delay so a fresh boot doesn't act on a stale "stopping" before
      # /start has flipped the status to starting/running.
      ExecStartPre = "${pkgs.coreutils}/bin/sleep 60";
      ExecStart = "${pollerScript}/bin/mc-stop-poller";
    };
  };
}
