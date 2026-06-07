# Custom amazon nixos-generators format module.
# Identical to the stock amazon format but sets memSize = 4096 for the QEMU
# build VM.  The nixpkgs default of 1 GiB is not enough for our modpack
# closure and causes a virtiofsd crash early in VM boot on GitHub Actions.
{ config, pkgs, lib, modulesPath, ... }:
let
  inherit (lib) optionalString escapeShellArg;
  cfg = config.amazonImage;
  amiBootMode = if config.ec2.efi then "uefi" else "legacy-bios";
  configFile = pkgs.writeText "configuration.nix" ''
    { modulesPath, ... }: {
      imports = [ "''${modulesPath}/virtualisation/amazon-image.nix" ];
      ${optionalString config.ec2.efi "ec2.efi = true;"}
    }
  '';
in {
  imports = [
    "${toString modulesPath}/../maintainers/scripts/ec2/amazon-image.nix"
  ];

  formatAttr = "amazonImage";
  fileExtension = ".vhd";

  system.build.amazonImage = lib.mkForce (
    import "${pkgs.path}/nixos/lib/make-disk-image.nix" {
      inherit lib config configFile pkgs;
      inherit (cfg) contents format;
      inherit (config.image) baseName;
      name = config.image.baseName;
      fsType = "ext4";
      partitionTableType = if config.ec2.efi then "efi" else "legacy+gpt";
      inherit (config.virtualisation) diskSize;
      memSize = 4096;
      postVM = ''
        mkdir -p $out/nix-support
        echo "file ${cfg.format} $diskImage" >> $out/nix-support/hydra-build-products
        ${pkgs.jq}/bin/jq -n \
          --arg system_version ${escapeShellArg config.system.nixos.version} \
          --arg system ${escapeShellArg pkgs.stdenv.hostPlatform.system} \
          --arg logical_bytes "$(${pkgs.qemu_kvm}/bin/qemu-img info --output json "$diskImage" | ${pkgs.jq}/bin/jq '."virtual-size"')" \
          --arg boot_mode "${amiBootMode}" \
          --arg file "$diskImage" \
          '{}
          | .label = $system_version
          | .boot_mode = $boot_mode
          | .system = $system
          | .logical_bytes = $logical_bytes
          | .file = $file
          | .disks.root.logical_bytes = $logical_bytes
          | .disks.root.file = $file
          ' > $out/nix-support/image-info.json
      '';
    }
  );
}
