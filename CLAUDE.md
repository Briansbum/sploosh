# Sploosh

Declarative Minecraft hosting: NixOS spot instances on AWS, managed via a Discord bot (Cloudflare Worker), all infra as code.

## Repo map

| Path | What it is |
|---|---|
| `flake.nix` | Root flake; exports `packages`, `amis`, `devShells`, `nixosModules` |
| `modpacks/` | One directory per modpack; `_lib.nix` is the shared helper |
| `modpacks/default.nix` | Registry: add new packs here |
| `nixos/` | NixOS modules: `ami.nix`, `server.nix`, `backup.nix`, `watchdog.nix` |
| `worker/` | Cloudflare Worker (TypeScript); Discord bot + D1 state |
| `infra/` | OpenTofu: S3, EC2 Fleet, SG, IAM |
| `scripts/` | `import-mods.sh`, `register-ami.sh`, `register-commands.ts` |

## Common tasks

### Enter dev shell
```
nix develop
```

### Add a modpack
1. `mkdir modpacks/<name>`
2. `cd modpacks/<name> && packwiz init`
3. `packwiz mr add <slug>` for each mod; `packwiz refresh`
4. Add entry to `modpacks/default.nix`
5. Push → CI builds AMI + .mrpack

### Import mods from a backup
```
nix develop
./scripts/import-mods.sh ~/minecraft-backup/alf10/AllTheForge10/mods modpacks/all-the-forge-10
```

### Add a mod to an existing pack
```
nix develop
cd modpacks/<name>
packwiz mr add <modrinth-slug>   # or: packwiz cf add <curseforge-slug>
packwiz refresh
# Commit the new .pw.toml and updated index.toml
```

### Build the mrpack locally
```
nix build .#modpacks.all-the-forge-10.mrpack
ls result/
```

### Build the NixOS AMI locally
```
nix build .#amis.all-the-forge-10
# Requires x86_64-linux and qemu-kvm for the VM build step
```

### Deploy the Worker
```
cd worker && npx wrangler deploy
```

### Register Discord slash commands
```
DISCORD_APP_ID=... DISCORD_BOT_TOKEN=... npx tsx scripts/register-commands.ts
```

### Apply infra
```
cd infra
tofu init
tofu plan -var-file=prod.tfvars
tofu apply -var-file=prod.tfvars
```

## First-time setup sequence

1. Run `tofu apply` in `infra/` — creates S3, SG, IAM, Fleet (target=0)
2. Create D1 database: `wrangler d1 create sploosh` → update `worker/wrangler.toml`
3. Apply schema: `wrangler d1 execute sploosh --file worker/schema.sql`
4. Add worker secrets: `wrangler secret put AWS_ACCESS_KEY_ID` etc.
5. Deploy worker: `wrangler deploy`
6. Register commands: `npx tsx scripts/register-commands.ts`
7. Import mods: `./scripts/import-mods.sh ...`
8. Push to trigger AMI build + modpack publish CI

## Modpack hash workflow

When you add mods or change the pack, `nix build` will fail with:
```
error: hash mismatch in fixed-output derivation
  got:    sha256-XXXX...
```
Copy the `got:` hash into the `modpackHash` field in `modpacks/default.nix`.
