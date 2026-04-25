# Builds a runnable Forge server derivation.
#
# This is a fixed-output derivation (FOD): Forge's installer downloads its own
# libraries from the internet during installation, so we pin the entire output
# tree with outputHash.
#
# To compute the hash for a new Forge version:
#   nix build .#_forgeServer.all-the-forge-10 --impure  (fails with wrong hash)
#   → copy the "got:" hash into forgeServerHash in the modpack's default.nix
#
# The resulting derivation exposes:
#   $out/bin/minecraft-server   — wrapper script
#   $out/libraries/             — Forge classpath
{
  pkgs,
  lib,
  mcVersion,
  forgeVersion,
  outputHash,
  jre ? pkgs.jdk21_headless,
}:

let
  installerJar = pkgs.fetchurl {
    url = "https://maven.minecraftforge.net/net/minecraftforge/forge/${mcVersion}-${forgeVersion}/forge-${mcVersion}-${forgeVersion}-installer.jar";
    # To get this hash: nix-prefetch-url <url>
    hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
  };
in

pkgs.stdenv.mkDerivation {
  pname = "forge-server";
  version = "${mcVersion}-${forgeVersion}";

  # FOD: allows network; pin with the recursive tree hash
  outputHash = outputHash;
  outputHashAlgo = "sha256";
  outputHashMode = "recursive";

  nativeBuildInputs = [
    jre
    pkgs.makeWrapper
  ];

  dontUnpack = true;

  buildPhase = ''
    mkdir -p installdir
    cd installdir
    java -jar ${installerJar} --installServer 2>&1 | tail -5
    cd ..
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin $out/share/forge

    # Copy everything the installer produced (libraries/, minecraft_server.jar,
    # run.sh, unix_args.txt, etc.)
    cp -r installdir/. $out/share/forge/

    # Rewrite unix_args.txt so paths are absolute (Forge uses relative paths
    # assuming you run from the server dir, but we run from dataDir).
    ARGS=$(find "$out/share/forge" -name "unix_args.txt" | head -1)
    if [ -n "$ARGS" ]; then
      sed -i "s|libraries/|$out/share/forge/libraries/|g" "$ARGS"
      # Write the wrapper script
      cat > "$out/bin/minecraft-server" <<EOF
    #!/bin/sh
    exec ${jre}/bin/java @${ARGS} "\$@"
    EOF
    else
      # Fallback for older Forge versions that don't use unix_args.txt
      cat > "$out/bin/minecraft-server" <<EOF
    #!/bin/sh
    exec ${jre}/bin/java -jar "$out/share/forge/forge-${mcVersion}-${forgeVersion}-server.jar" "\$@"
    EOF
    fi

    chmod +x "$out/bin/minecraft-server"

    runHook postInstall
  '';

  meta = {
    mainProgram = "minecraft-server";
    description = "Minecraft Forge server ${mcVersion}-${forgeVersion}";
    homepage = "https://minecraftforge.net";
    # Minecraft EULA must be accepted separately
    license = lib.licenses.unfree;
  };
}
