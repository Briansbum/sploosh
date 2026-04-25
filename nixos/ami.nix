# Base NixOS configuration for the EC2 Minecraft spot AMI.
# This is imported by nixos-generators when building the amazon image.
# Modpack-specific settings come from the modpack's nixosModule.
{ pkgs, lib, ... }:

{
  imports = [
    ./server.nix
    ./backup.nix
    ./watchdog.nix
  ];

  # ── EC2 basics ─────────────────────────────────────────────────────────────

  # Use GRUB to boot (required for Amazon Linux AMIs)
  boot.loader.grub.device = lib.mkForce "/dev/xvda";

  # EC2 metadata and cloud-init
  services.cloud-init.enable = true;

  # SSM agent (optional but useful for emergency shell without SSH key)
  services.amazon-ssm-agent.enable = true;

  # ── Networking ─────────────────────────────────────────────────────────────

  networking.useDHCP = true;
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 25565 ];
  };

  # ── System ─────────────────────────────────────────────────────────────────

  time.timeZone = "UTC";
  system.stateVersion = "24.05";

  # Minimal set of runtime tools
  environment.systemPackages = with pkgs; [
    restic
    mcrcon
    awscli2
    jq
    curl
  ];

  # Passwordless sudo for the default ec2-user / ubuntu user
  users.users.ec2-user = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
  };
  security.sudo.wheelNeedsPassword = false;
}
