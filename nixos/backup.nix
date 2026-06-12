# restic-based backups: incremental every 15 min + final snapshot on shutdown.
# Also handles spot interruption detection via IMDS.
#
# Incremental backup flow:
#   1. save-off     — disables MC autosave timer (near-instant)
#   2. save-all     — queues all loaded chunks for IO workers
#   3. sleep 2      — lets IO workers drain to page cache
#   4. btrfs filesystem sync — flushes dirty page cache → complete on-disk state
#   5. btrfs subvolume snapshot -r /srv/mc-vol/live /srv/mc-vol/snap-<ts>
#   6. save-on      — server unfrozen; players see ~<1s pause total
#   7. restic backup against the frozen snapshot (slow, doesn't block server)
#   8. btrfs subvolume delete the snapshot
#
# Final backup flow (clean shutdown / spot reclaim):
#   1. warn players via RCON
#   2. systemctl stop minecraft-server-create-central — JVM shutdown hooks flush
#      everything to disk, including Create contraptions
#   3. btrfs filesystem sync + snapshot
#   4. restic backup against the frozen snapshot
#   5. btrfs subvolume delete the snapshot
#
# /srv/mc-vol is the top-level btrfs mount; /srv/minecraft is a bind of /srv/mc-vol/live.
# Both are set up by mc-data-volume.service before bootstrap runs.
{ pkgs, lib, ... }:

let
  rconArgs = ''-H 127.0.0.1 -P 25575 -p "$RCON_PASSWORD"'';

  # ── Snapshot + restic backup logic (shared between incremental and final) ──
  #
  # The snapshot is mounted at /srv/minecraft inside a private mount namespace
  # (PrivateMounts=yes on both services) so restic captures paths as
  # /srv/minecraft/... — matching what mc-bootstrap restores to.

  # mcrcon wrapped with a timeout so a hung server thread (e.g. Sable's
  # ChunkMap serialisation mixin deadlocking on save-all flush) never blocks
  # the backup service indefinitely.
  rconCmd = cmd: "timeout 10 mcrcon ${rconArgs} \"${cmd}\" 2>/dev/null || true";

  backupBody = tag: ''
    set -euo pipefail

    set -a
    # shellcheck source=/dev/null
    source /run/minecraft/env
    set +a

    SNAP="/srv/mc-vol/snap-$(date +%s)"

    # On any exit (success or error): re-enable autosave, unmount the snapshot
    # from our private namespace, and delete the subvolume if it still exists.
    trap '${rconCmd "save-on"}; umount /srv/minecraft 2>/dev/null || true; [ -e "$SNAP" ] && btrfs subvolume delete "$SNAP" 2>/dev/null || true' EXIT

    # Disable autosave and issue a normal (non-flush) save-all.
    # save-all flush deadlocks with Sable's ChunkMap serialisation mixin.
    # Instead: save-all queues all loaded chunks for the IO workers, sleep 2
    # gives those workers time to drain to page cache, then btrfs filesystem
    # sync commits the full btrfs transaction (flushing dirty page cache) so
    # the snapshot captures a complete on-disk state.
    ${rconCmd "save-off"}
    ${rconCmd "save-all"}
    sleep 2
    btrfs filesystem sync /srv/mc-vol
    btrfs subvolume snapshot -r /srv/mc-vol/live "$SNAP"

    # Shadow /srv/minecraft with the frozen snapshot for this process only.
    # PrivateMounts=yes on the unit keeps this mount private to the service.
    mount --bind "$SNAP" /srv/minecraft

    restic backup "/srv/minecraft/$SPLOOSH_MODPACK" \
      --cache-dir /var/cache/restic \
      --tag "modpack:$SPLOOSH_MODPACK" \
      --tag "${tag}" \
      --exclude "/srv/minecraft/$SPLOOSH_MODPACK/mods" \
      --exclude "/srv/minecraft/$SPLOOSH_MODPACK/config" \
      --exclude "/srv/minecraft/$SPLOOSH_MODPACK/defaultconfigs" \
      --exclude "/srv/minecraft/$SPLOOSH_MODPACK/logs" \
      --exclude "/srv/minecraft/$SPLOOSH_MODPACK/crash-reports" \
      --exclude "/srv/minecraft/$SPLOOSH_MODPACK/libraries" \
      --exclude "/srv/minecraft/$SPLOOSH_MODPACK/versions" \
      --exclude "/srv/minecraft/$SPLOOSH_MODPACK/cache" \
      --exclude "/srv/minecraft/$SPLOOSH_MODPACK/*.jar"

    # Explicit cleanup on success path; trap handles the error path.
    # Must unmount before delete — btrfs refuses to delete a mounted subvolume.
    umount /srv/minecraft
    btrfs subvolume delete "$SNAP"
  '';

  # ── Incremental backup ─────────────────────────────────────────────────────

  backupScript = pkgs.writeShellApplication {
    name = "mc-backup";
    runtimeInputs = with pkgs; [ restic mcrcon btrfs-progs util-linux ];
    text = ''
      ${backupBody "incremental"}

      # Prune old snapshots (cheap: only runs after backup)
      restic forget \
        --cache-dir /var/cache/restic \
        --tag "modpack:$SPLOOSH_MODPACK" \
        --keep-hourly 24 \
        --keep-daily 7 \
        --keep-weekly 4 \
        --prune
    '';
  };

  # ── Final backup (clean shutdown / spot reclaim) ───────────────────────────
  #
  # Stops the server cleanly instead of using save-all + sleep, so that JVM
  # shutdown hooks flush everything — including Create contraptions — before
  # we snapshot. The incremental path cannot do this (players would disconnect),
  # but the final path runs only when the server is idle or reclaimed.

  finalBackupScript = pkgs.writeShellApplication {
    name = "mc-backup-final";
    runtimeInputs = with pkgs; [ restic mcrcon btrfs-progs util-linux ];
    text = ''
      set -euo pipefail

      # Serialise concurrent calls (watchdog + halt.target can both fire).
      # The loser exits immediately; it does not queue behind the winner.
      LOCK=/run/minecraft/final-backup.lock
      exec 200>"$LOCK"
      flock -n 200 || { echo "mc-backup-final already running — skipping."; exit 0; }

      set -a
      # shellcheck source=/dev/null
      source /run/minecraft/env
      set +a

      SNAP="/srv/mc-vol/snap-$(date +%s)"

      trap 'umount /srv/minecraft 2>/dev/null || true; [ -e "$SNAP" ] && btrfs subvolume delete "$SNAP" 2>/dev/null || true' EXIT

      # Warn players, then stop the server so JVM shutdown hooks flush
      # all pending data (including Create contraptions) before snapshotting.
      ${rconCmd "say §eServer shutting down — saving world..."}
      systemctl stop minecraft-server-create-central.service || true

      btrfs filesystem sync /srv/mc-vol
      btrfs subvolume snapshot -r /srv/mc-vol/live "$SNAP"

      mount --bind "$SNAP" /srv/minecraft

      restic backup "/srv/minecraft/$SPLOOSH_MODPACK" \
        --cache-dir /var/cache/restic \
        --tag "modpack:$SPLOOSH_MODPACK" \
        --tag "final" \
        --exclude "/srv/minecraft/$SPLOOSH_MODPACK/mods" \
        --exclude "/srv/minecraft/$SPLOOSH_MODPACK/config" \
        --exclude "/srv/minecraft/$SPLOOSH_MODPACK/defaultconfigs" \
        --exclude "/srv/minecraft/$SPLOOSH_MODPACK/logs" \
        --exclude "/srv/minecraft/$SPLOOSH_MODPACK/crash-reports" \
        --exclude "/srv/minecraft/$SPLOOSH_MODPACK/libraries" \
        --exclude "/srv/minecraft/$SPLOOSH_MODPACK/versions" \
        --exclude "/srv/minecraft/$SPLOOSH_MODPACK/cache" \
        --exclude "/srv/minecraft/$SPLOOSH_MODPACK/*.jar"

      umount /srv/minecraft
      btrfs subvolume delete "$SNAP"
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
        action=$(imds_get "spot/instance-action" | jq -r '.action // ""' 2>/dev/null || echo "")

        if [ "$action" = "terminate" ]; then
          echo "Spot termination notice received, saving..."
          # start blocks until ExecStart (the backup) completes, then poweroff.
          systemctl start mc-backup-final.service || true
          systemctl poweroff
        fi

        sleep 5
      done
    '';
  };

in
{
  # Incremental backup every 15 minutes while the server is running.
  # PrivateMounts=yes: the bind-mount of the snapshot over /srv/minecraft
  # is private to this unit and doesn't affect the live server.
  systemd.services.mc-backup = {
    description = "Minecraft incremental backup";
    after = [ "mc-bootstrap.service" "mc-data-volume.service" ];
    requires = [ "mc-data-volume.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${backupScript}/bin/mc-backup";
      PrivateMounts = true;
    };
  };

  systemd.timers.mc-backup = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnUnitActiveSec = "15m";
      OnBootSec = "15m";
    };
  };

  # Final backup — systemd starts this as part of halt/poweroff/reboot, and
  # the watchdog/spot handler also call `systemctl start` directly.  The flock
  # in the script prevents concurrent runs; whoever fires second skips silently.
  systemd.services.mc-backup-final = {
    description = "Minecraft final backup (shutdown)";
    after = [ "mc-bootstrap.service" ];
    requires = [ "mc-bootstrap.service" ];
    before = [ "shutdown.target" "reboot.target" "halt.target" ];
    wantedBy = [ "halt.target" "reboot.target" "poweroff.target" ];
    unitConfig.DefaultDependencies = false;
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${finalBackupScript}/bin/mc-backup-final";
      TimeoutStartSec = "600";
      PrivateMounts = true;
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
