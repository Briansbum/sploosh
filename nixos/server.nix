# Server bootstrap: reads user-data JSON at first boot, restores the latest
# restic snapshot, and adjusts server.properties.
#
# Expected user-data JSON (base64-decoded by cloud-init):
#   {
#     "modpack":       "create-central",
#     "rcon_password": "...",
#     "s3_bucket":     "sploosh-minecraft-backups",
#     "s3_prefix":     "create-central/restic",
#     "restic_password": "..."
#   }
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

      # ── Read user-data ────────────────────────────────────────────────────

      USERDATA=$(curl -sf http://169.254.169.254/latest/user-data 2>/dev/null || echo "{}")
      RCON_PASSWORD=$(echo "$USERDATA" | jq -r '.rcon_password // ""')
      S3_BUCKET=$(echo    "$USERDATA" | jq -r '.s3_bucket // "sploosh-minecraft-backups"')
      S3_PREFIX=$(echo    "$USERDATA" | jq -r '.s3_prefix // "default/restic"')
      RESTIC_PASS=$(echo  "$USERDATA" | jq -r '.restic_password // ""')
      MODPACK=$(echo      "$USERDATA" | jq -r '.modpack // "default"')

      # Write env for downstream services (backup, watchdog)
      mkdir -p /run/minecraft
      chmod 700 /run/minecraft

      cat > /run/minecraft/env << ENV
      RCON_PASSWORD=$RCON_PASSWORD
      RESTIC_REPOSITORY=s3:s3.eu-west-2.amazonaws.com/$S3_BUCKET/$S3_PREFIX
      RESTIC_PASSWORD=$RESTIC_PASS
      SPLOOSH_MODPACK=$MODPACK
      ENV
      chmod 600 /run/minecraft/env

      # ── Replace RCON password placeholder in server.properties ───────────

      SVCDIR="/var/lib/minecraft/$MODPACK"
      PROPS="$SVCDIR/server.properties"

      if [ -f "$PROPS" ]; then
        # nix-minecraft creates server.properties as a managed symlink;
        # we need to replace it with a writable copy that has the real password.
        cp --remove-destination "$(realpath "$PROPS")" "$PROPS.rw"
        sed "s/@RCON_PASSWORD@/$RCON_PASSWORD/g" "$PROPS.rw" > "$PROPS"
        rm "$PROPS.rw"
      fi

      # ── Restore latest restic snapshot ───────────────────────────────────

      if [ -n "$RESTIC_PASS" ]; then
        export RESTIC_REPOSITORY="s3:s3.eu-west-2.amazonaws.com/$S3_BUCKET/$S3_PREFIX"
        export RESTIC_PASSWORD="$RESTIC_PASS"

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
  # Run bootstrap before any minecraft service starts
  systemd.services.mc-bootstrap = {
    description = "Minecraft server bootstrap";
    wantedBy = [ "multi-user.target" ];
    # Runs before all minecraft-server-* services
    before = [ "minecraft-server-create-central.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${bootstrapScript}/bin/mc-bootstrap";
    };
  };

  # Propagate the env file to all minecraft server services
  systemd.services."minecraft-server-create-central" = {
    after = [ "mc-bootstrap.service" ];
    requires = [ "mc-bootstrap.service" ];
    serviceConfig.EnvironmentFile = [ "-/run/minecraft/env" ];
  };
}
