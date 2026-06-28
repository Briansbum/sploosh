# Idle shutdown watchdog: polls RCON `list` every 60s.
# After IDLE_MINUTES (default 15) consecutive empty polls, takes a final backup
# and powers off the instance.
{ pkgs, lib, ... }:

let
  watchdogScript = pkgs.writeShellApplication {
    name = "mc-watchdog";
    runtimeInputs = with pkgs; [ mcrcon curl jq coreutils openssl gawk ];
    text = ''
      set -euo pipefail
      # shellcheck source=/dev/null
      source /run/minecraft/env

      IDLE_MINUTES=''${IDLE_MINUTES:-15}
      POLL_SECONDS=60
      IDLE_THRESHOLD=$(( IDLE_MINUTES * 60 / POLL_SECONDS ))

      STATE_FILE=/run/minecraft/idle-count

      mkdir -p /run/minecraft
      echo 0 > "$STATE_FILE"

      while true; do
        sleep "$POLL_SECONDS"

        # Query player count via RCON
        response=$(mcrcon -H 127.0.0.1 -P 25575 -p "$RCON_PASSWORD" list 2>/dev/null || echo "")
        # Expected: "There are N of a max of M players online: ..."
        count=$(echo "$response" | grep -oP 'There are \K[0-9]+' || echo "0")

        if [ "$count" -gt 0 ]; then
          echo 0 > "$STATE_FILE"
        else
          idle=$(cat "$STATE_FILE")
          idle=$(( idle + 1 ))
          echo "$idle" > "$STATE_FILE"
          echo "Empty server poll $idle/$IDLE_THRESHOLD"

          if [ "$idle" -ge "$IDLE_THRESHOLD" ]; then
            echo "Server idle for $IDLE_MINUTES minutes — shutting down."

            # Save the world to completion FIRST — blocks until the JVM shutdown
            # hooks flush and the restic snapshot is taken. Only after the save
            # is durable do we notify the worker to terminate the fleet; doing it
            # the other way round races an external EC2 termination against the
            # save (SIGKILLing the JVM mid-flush), the same bug /stop had.
            systemctl start mc-backup-final.service || true

            # Notify the CF worker — deletes the fleet (safe now) and marks
            # the server stopped.
            if [ -n "$WORKER_IDLE_WEBHOOK" ]; then
              HMAC=$(echo -n "$SPLOOSH_MODPACK" | \
                openssl dgst -sha256 -hmac "$WORKER_WEBHOOK_SECRET" | \
                awk '{print $2}')
              curl -sf -X POST "$WORKER_IDLE_WEBHOOK" \
                -H "Content-Type: application/json" \
                -H "X-Sploosh-Sig: $HMAC" \
                -d "{\"modpack\":\"$SPLOOSH_MODPACK\"}" || true
            fi

            systemctl poweroff
          fi
        fi
      done
    '';
  };

in
{
  systemd.services.mc-watchdog = {
    description = "Minecraft idle shutdown watchdog";
    wantedBy = [ "multi-user.target" ];
    after = [
      "mc-bootstrap.service"
      "network.target"
      # Start after the server has had time to initialise
    ];
    # 5-minute startup delay so the server has time to load before we start polling
    serviceConfig = {
      Type = "simple";
      Restart = "on-failure";
      RestartSec = "30s";
      TimeoutStartSec = "360s";
      ExecStartPre = "${pkgs.coreutils}/bin/sleep 300";
      ExecStart = "${watchdogScript}/bin/mc-watchdog";
    };
  };
}
