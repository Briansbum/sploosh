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
  # Format + mount the data EBS volume that holds /srv/minecraft.
  #
  # Layout:
  #   /srv/mc-vol            — top of btrfs filesystem (admin / snapshot access)
  #   /srv/mc-vol/live       — subvolume holding actual world data
  #   /srv/minecraft         — bind-mount of /srv/mc-vol/live (what services see)
  #
  # All Nitro instance types in the fleet expose EBS as NVMe, so the AWS
  # device_name hint (xvdb) doesn't match the kernel name. We identify the
  # data volume by filesystem label after first-boot mkfs.
  dataVolumeScript = pkgs.writeShellApplication {
    name = "mc-data-volume";
    runtimeInputs = with pkgs; [ btrfs-progs util-linux gawk ];
    text = ''
      set -euo pipefail

      LABEL="sploosh-data"

      if [ ! -e "/dev/disk/by-label/$LABEL" ]; then
        # First boot: find a candidate block device. Heuristic: a whole disk
        # that isn't the root and has no existing filesystem signature.
        ROOT_SRC=$(findmnt -no SOURCE /)
        ROOT_DISK=$(lsblk -no PKNAME "$ROOT_SRC")

        CANDIDATE=""
        for dev in $(lsblk -dnpo NAME,TYPE | awk '$2=="disk"{print $1}'); do
          [ "$(basename "$dev")" = "$ROOT_DISK" ] && continue
          if blkid -p "$dev" >/dev/null 2>&1; then
            echo "Skipping $dev — already has a filesystem signature" >&2
            continue
          fi
          CANDIDATE="$dev"
          break
        done

        if [ -z "$CANDIDATE" ]; then
          echo "No empty data volume found — refusing to continue" >&2
          exit 1
        fi

        echo "Formatting $CANDIDATE as btrfs (label=$LABEL)"
        mkfs.btrfs -L "$LABEL" "$CANDIDATE"
        udevadm settle
      fi

      mkdir -p /srv/mc-vol
      if ! mountpoint -q /srv/mc-vol; then
        mount -t btrfs -o noatime,compress=zstd "LABEL=$LABEL" /srv/mc-vol
      fi

      if [ ! -d /srv/mc-vol/live ]; then
        btrfs subvolume create /srv/mc-vol/live
      fi

      mkdir -p /srv/minecraft
      if ! mountpoint -q /srv/minecraft; then
        mount --bind /srv/mc-vol/live /srv/minecraft
      fi
    '';
  };

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

      # Seed an empty whitelist if one wasn't restored; mc-sync-whitelist fills it.
      SVCDIR="/srv/minecraft/$MODPACK"
      mkdir -p "$SVCDIR"
      if [ ! -f "$SVCDIR/whitelist.json" ]; then
        echo "[]" > "$SVCDIR/whitelist.json"
      fi

      echo "Bootstrap complete."
    '';
  };

in
{
  # Format + mount the data EBS volume before anything else touches /srv/minecraft.
  systemd.services.mc-data-volume = {
    description = "Mount btrfs data volume at /srv/minecraft";
    wantedBy = [ "multi-user.target" ];
    before = [ "mc-bootstrap.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${dataVolumeScript}/bin/mc-data-volume";
    };
  };

  # Run bootstrap before any minecraft service starts.
  # Must run after network is up so IMDS is reachable.
  systemd.services.mc-bootstrap = {
    description = "Minecraft server bootstrap";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" "mc-data-volume.service" ];
    wants = [ "network-online.target" ];
    requires = [ "mc-data-volume.service" ];
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

  # Companion timer: merges Discord /allowlist players into whitelist.json and
  # reloads via RCON. Runs every 60s independently of the minecraft-server unit
  # so new /allowlist entries land in the running JVM without a server restart.
  # Tolerates RCON being down — failed reloads just wait for the next tick.
  systemd.services.mc-sync-whitelist = let
    syncScript = pkgs.writeShellApplication {
      name = "mc-sync-whitelist";
      runtimeInputs = [ pkgs.curl pkgs.jq pkgs.mcrcon ];
      text = ''
        MODPACK="''${SPLOOSH_MODPACK:-create-central}"
        DYNAMIC=$(curl -sf --max-time 10 "https://sploosh.freestone-alex.workers.dev/api/whitelist/$MODPACK" || echo "[]")

        echo "$DYNAMIC" | jq -r '.[].name' | while IFS= read -r player; do
          mcrcon -H 127.0.0.1 -P 25575 -p "$RCON_PASSWORD" "whitelist add $player" 2>/dev/null || true
        done
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
