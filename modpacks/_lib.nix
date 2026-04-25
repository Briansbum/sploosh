# mkModpack: produces a modpack record from a definition.
#
# Returns:
#   packages.mrpack    — .mrpack artifact  (nix build .#modpacks.<name>.mrpack)
#   packages.packDir   — static pack.toml tree for GitHub Pages
#   nixosModule        — NixOS module that runs this server
{
  pkgs,
  lib,
  nix-minecraft,
}:

{
  name,
  displayName,
  mcVersion,
  loader, # "neoforge" | "fabric" | "paper" | "vanilla"
  # sha256 hash of the entire fetched modpack tree.
  # Workflow: set to lib.fakeHash first, run nix build, copy the "got:" hash.
  modpackHash ? lib.fakeHash,
  jvmOpts ? "-Xms2048M -Xmx8192M -XX:+UseG1GC",
}:

let
  # Copy the pack source (pack.toml + mods/*.pw.toml) into the nix store so we
  # can use a file:// URL with fetchPackwizModpack for local-first development.
  packSrc = builtins.path {
    path = ./. + "/${name}";
    name = "${name}-pack-src";
  };

  # ── Server package ──────────────────────────────────────────────────────────
  # nix-minecraft supports: neoforge, fabric, quilt, paper, purpur, vanilla
  # (Forge is not supported; NeoForge is compatible with 1.20.1 Forge mods)

  mcVersionKey = lib.replaceStrings [ "." ] [ "_" ] mcVersion;

  serverPackage =
    if loader == "neoforge" then
      pkgs.minecraftServers."neoforge-${mcVersionKey}"
    else if loader == "fabric" then
      pkgs.minecraftServers."fabric-${mcVersionKey}"
    else if loader == "paper" then
      pkgs.minecraftServers."paper-${mcVersionKey}"
    else
      pkgs.minecraftServers."vanilla-${mcVersionKey}";

  # ── Packwiz modpack (downloads all mods as a fixed-output derivation) ───────

  modpack = pkgs.fetchPackwizModpack {
    url = "file://${packSrc}/pack.toml";
    packHash = modpackHash;
  };

  # ── Client artifact ──────────────────────────────────────────────────────────

  mrpackDrv = pkgs.stdenv.mkDerivation {
    pname = "${name}-mrpack";
    version = mcVersion;
    src = packSrc;
    nativeBuildInputs = [ pkgs.packwiz ];
    buildPhase = ''
      export HOME=$TMPDIR
      export XDG_CACHE_HOME=$TMPDIR/cache
      packwiz modrinth export -o ${name}.mrpack
    '';
    installPhase = ''
      install -Dm644 ${name}.mrpack "$out/${name}.mrpack"
    '';
  };

  packDirDrv = pkgs.stdenv.mkDerivation {
    pname = "${name}-packdir";
    version = mcVersion;
    src = packSrc;
    installPhase = ''
      cp -r . "$out"
    '';
  };

  # ── NixOS module ─────────────────────────────────────────────────────────────

  nixosModule =
    { ... }:
    {
      imports = [ nix-minecraft.nixosModules.minecraft-servers ];

      services.minecraft-servers = {
        enable = true;
        eula = true;

        servers.${name} = {
          enable = true;
          package = serverPackage;
          jvmOpts = jvmOpts;

          serverProperties = {
            server-port = 25565;
            enable-rcon = true;
            "rcon.port" = 25575;
            # Populated at boot by nixos/server.nix's mc-bootstrap.service
            "rcon.password" = "@RCON_PASSWORD@";
            online-mode = true;
            white-list = true;
            enforce-whitelist = true;
            difficulty = "normal";
            max-players = 20;
            view-distance = 10;
            simulation-distance = 8;
            motd = displayName;
          };

          # Mods + config are symlinked from the packwiz-resolved store path.
          symlinks = {
            "mods" = "${modpack}/mods";
          };
          files = lib.optionalAttrs (builtins.pathExists (./. + "/${name}/config")) {
            "config" = "${modpack}/config";
          };
        };
      };
    };

in
{
  inherit nixosModule;
  packages = {
    mrpack = mrpackDrv;
    packDir = packDirDrv;
  };
}
