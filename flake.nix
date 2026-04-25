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
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      nix-minecraft,
      nixos-generators,
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

      in
      {
        # nix develop  →  packwiz, wrangler, mcrcon, awscli, tofu, tsx
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            packwiz
            wrangler
            nodejs_22
            mcrcon
            awscli2
            opentofu
            jdk21_headless
            curl
            jq
            openssl
          ];
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

        # nix build .#all-the-forge-10-mrpack
        # nix build .#all-the-forge-10-packdir
        packages = lib.foldlAttrs (
          acc: name: mp:
          acc
          // {
            "${name}-mrpack" = mp.packages.mrpack;
            "${name}-packdir" = mp.packages.packDir;
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
          format = "amazon";
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
