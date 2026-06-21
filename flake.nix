{
  description = "sploosh — declarative Minecraft hosting on AWS spot";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    flake-utils.url = "github:numtide/flake-utils";

    nix-minecraft = {
      url = "github:Infinidoge/nix-minecraft";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    packwiz.url = "github:packwiz/packwiz";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      nix-minecraft,
      nixos-generators,
      packwiz,
    }:
    let
      lib = nixpkgs.lib;

      # Modpack definitions (loader, mc version, forge version)
      modpackDefs = import ./modpacks;

    in
    # Per-system outputs: devShell, packages (mrpack + packDir per modpack)
    flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-linux" ] (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ nix-minecraft.overlays.default ];
          config.allowUnfree = true;
        };

        mkModpack = import ./modpacks/_lib.nix { inherit pkgs lib nix-minecraft; };

        modpacks = lib.mapAttrs (name: def: mkModpack ({ inherit name; } // def)) modpackDefs;

        packwizPkg = packwiz.packages.${system}.default.override {
          vendorHash = "sha256-ChUE4hWl+UyPpbzK0GbJTD0AoBCogI7qGstga4+WujI=";
        };

        # Shared rehash implementation — single source of truth, referenced by
        # both `apps.rehash` and `apps.update-mods` so they cannot drift.
        rehashApp = pkgs.writeShellApplication {
          name = "rehash";
          runtimeInputs = [ pkgs.gnused pkgs.jq ];
          text = ''
            NIXFILE="$(git rev-parse --show-toplevel)/modpacks/default.nix"
            PACKS=(${lib.concatStringsSep " " (builtins.attrNames modpackDefs)})
            FAKE="sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
            FAILED=0

            for PACK in "''${PACKS[@]}"; do
              echo "=== Rehashing $PACK ==="
              sed -i "/^  $PACK = /,/^  }/ s|modpackHash = \"sha256-[^\"]*\";|modpackHash = \"$FAKE\";|" "$NIXFILE"

              HASH=$(nix build ".#''${PACK}-modpack" --no-link 2>&1 | grep "got:" | awk '{print $NF}' || true)

              if [ -z "$HASH" ]; then
                echo "ERROR: could not extract hash for $PACK" >&2
                FAILED=1
              else
                sed -i "/^  $PACK = /,/^  }/ s|modpackHash = \"$FAKE\";|modpackHash = \"$HASH\";|" "$NIXFILE"
                echo "Updated $PACK → $HASH"
              fi
            done

            if [ "$FAILED" -ne 0 ]; then
              echo "One or more packs failed — check output above" >&2
              exit 1
            fi
          '';
        };

      in
      {
        # nix develop  →  packwiz, wrangler, mcrcon, awscli, tofu, tsx
        devShells.default = pkgs.mkShell {
          buildInputs = [
            packwizPkg
          ] ++ (with pkgs; [
            wrangler
            nodejs_22
            mcrcon
            awscli2
            opentofu
            jdk21_headless
            curl
            jq
            openssl
          ]);
          shellHook = ''
            # npm ci for worker types/build tooling (non-global, stays in worker/)
            if [ -f worker/package.json ] && [ ! -d worker/node_modules ]; then
              echo "Installing worker npm deps..."
              (cd worker && npm install --silent)
            fi

            # D1 helpers — run SQL against the remote sploosh database
            # Usage: d1q "SELECT * FROM modpacks"
            d1q() { wrangler d1 execute sploosh --remote --config worker/wrangler.toml --command "$*"; }
            # Usage: d1f worker/schema.sql
            d1f() { wrangler d1 execute sploosh --remote --config worker/wrangler.toml --file "$1"; }

            # Worker helpers
            alias wtail='(cd worker && wrangler tail)'
            alias wdev='(cd worker && wrangler dev)'
            alias register-commands='(cd worker && npx tsx ../scripts/register-commands.ts)'

            # Infra shortcut (always needs var file)
            alias tofu-plan='tofu -chdir=infra plan -var-file=prod.tfvars'
            alias tofu-apply='tofu -chdir=infra apply -var-file=prod.tfvars'
          '';
        };

        # nix run .#rehash  — for every modpack: builds with fakeHash, captures
        # the "got:" hash, and writes it back into modpacks/default.nix.
        apps.rehash = {
          type = "app";
          program = "${rehashApp}/bin/rehash";
        };

        # nix run .#update-mods [pack...]  — update modpack metadata in batches of
        # 50, pausing when the Modrinth ratelimit is nearly exhausted, then rehash
        # so modpacks/default.nix can never fall out of sync with the updates.
        apps.update-mods = {
          type = "app";
          program = toString (pkgs.writeShellApplication {
            name = "update-mods";
            runtimeInputs = [
              packwizPkg
              rehashApp
              pkgs.git
              pkgs.curl
              pkgs.findutils
              pkgs.gnused
              pkgs.gnugrep
              pkgs.gawk
              pkgs.coreutils
            ];
            text = ''
              ROOT="$(git rev-parse --show-toplevel)"
              BATCH=50          # mods updated per batch
              THRESHOLD=100     # pause when fewer than this many requests remain

              PACKS=(${lib.concatStringsSep " " (builtins.attrNames modpackDefs)})
              if [ "$#" -gt 0 ]; then
                PACKS=("$@")
              fi

              # Query Modrinth's ratelimit headers; if we are running low, sleep
              # until the window resets. Modrinth allows 300 requests/min per IP.
              check_ratelimit() {
                local headers remaining reset
                headers=$(curl -s -o /dev/null -D - "https://api.modrinth.com/v2/tag/loader") || true
                remaining=$(printf '%s' "$headers" | grep -i '^x-ratelimit-remaining:' | tr -d '\r' | awk '{print $2}') || true
                reset=$(printf '%s' "$headers" | grep -i '^x-ratelimit-reset:' | tr -d '\r' | awk '{print $2}') || true
                if [ -n "$remaining" ] && [ "$remaining" -lt "$THRESHOLD" ]; then
                  echo "  ratelimit low (remaining=$remaining); sleeping $((reset + 1))s until reset..."
                  sleep "$((reset + 1))"
                else
                  echo "  ratelimit ok (remaining=''${remaining:-unknown})"
                fi
              }

              for PACK in "''${PACKS[@]}"; do
                PACKDIR="$ROOT/modpacks/$PACK"
                if [ ! -f "$PACKDIR/pack.toml" ]; then
                  echo "=== skipping $PACK (no pack.toml) ==="
                  continue
                fi
                echo "=== Updating $PACK ==="
                cd "$PACKDIR" || exit 1

                mapfile -t MODS < <(find . -name '*.pw.toml' | sort)
                TOTAL=''${#MODS[@]}
                echo "  $TOTAL metadata files to check"

                i=0
                while [ "$i" -lt "$TOTAL" ]; do
                  echo "  --- batch starting at file $((i + 1)) of $TOTAL ---"
                  check_ratelimit
                  for (( j = i; j < i + BATCH && j < TOTAL; j++ )); do
                    FILE="''${MODS[j]}"
                    SLUG=$(basename "$FILE" .pw.toml)
                    # Pinned direct downloads have no [update] section and no update
                    # system; packwiz errors on them, so skip rather than fail loud.
                    if ! grep -q '^\[update' "$FILE"; then
                      echo "  skipping $SLUG (no update system)"
                      continue
                    fi
                    if ! packwiz update "$SLUG" -y; then
                      echo "ERROR: update failed for $SLUG" >&2
                      exit 1
                    fi
                  done
                  i=$((i + BATCH))
                done

                echo "  refreshing index for $PACK"
                packwiz refresh
              done

              echo "=== Rehashing (keeps default.nix in sync) ==="
              rehash
            '';
          } + "/bin/update-mods");
        };

        # nix build .#all-the-forge-10-mrpack
        # nix build .#all-the-forge-10-packdir
        packages = lib.foldlAttrs (
          acc: name: mp:
          acc
          // {
            "${name}-mrpack" = mp.packages.mrpack;
            "${name}-packdir" = mp.packages.packDir;
            "${name}-modpack" = mp.packages.modpack;
          }
        ) { } modpacks;
      }
    )
    # System-independent outputs: NixOS AMIs (always x86_64 for EC2)
    // {
      # nix build .#amis.all-the-forge-10
      amis = lib.mapAttrs (
        name: def:
        let
          pkgs = import nixpkgs {
            system = "x86_64-linux";
            overlays = [ nix-minecraft.overlays.default ];
            config.allowUnfree = true;
          };
          mkModpack = import ./modpacks/_lib.nix { inherit pkgs lib nix-minecraft; };
          mp = mkModpack ({ inherit name; } // def);
        in
        nixos-generators.nixosGenerate {
          system = "x86_64-linux";
          format = "amazon-hm";
          customFormats = { "amazon-hm" = ./nixos/amazon-format.nix; };
          modules = [
            ./nixos/ami.nix
            mp.nixosModule
          ];
        }
      ) modpackDefs;

      # Expose raw nixosModules for composing elsewhere
      nixosModules = lib.mapAttrs (
        name: def:
        let
          pkgs = import nixpkgs {
            system = "x86_64-linux";
            overlays = [ nix-minecraft.overlays.default ];
            config.allowUnfree = true;
          };
          mkModpack = import ./modpacks/_lib.nix { inherit pkgs lib nix-minecraft; };
        in
        (mkModpack ({ inherit name; } // def)).nixosModule
      ) modpackDefs;
    };
}
