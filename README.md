# sploosh

Declarative Minecraft hosting on AWS spot instances, managed via a Discord bot. All infrastructure is code.

## Architecture

```
Discord user
    │  slash command
    ▼
Cloudflare Worker (TypeScript)
    │  starts/stops EC2 Fleet, reads/writes D1 state
    ▼
AWS EC2 Spot Fleet  ◄── NixOS AMI (built by CI)
    │  packwiz auto-installs mods on boot
    ▼
S3 bucket  (world backups via restic, every 15 min)
```

| Component | What it does |
|---|---|
| `modpacks/` | packwiz mod definitions; one directory per pack |
| `nixos/` | NixOS modules for the server AMI |
| `worker/` | Cloudflare Worker — Discord bot + EC2 lifecycle |
| `infra/` | OpenTofu — S3, EC2 Fleet, SG, IAM |
| `scripts/` | AMI registration, Discord command registration |
| `.github/workflows/` | CI: builds AMIs, mrpacks, deploys worker |

## Modpacks

| Pack | Loader | MC Version |
|---|---|---|
| Create Central | NeoForge | 1.20.1 |

Mods: Create, Crafts & Additions, Enchantment Industry, Steam 'n' Rails, Connected, Misc & Things, Big Cannons + Faithless texture pack.

## Discord commands

| Command | What it does |
|---|---|
| `/start <pack>` | Spin up a spot instance for the chosen modpack |
| `/stop` | Gracefully stop the server and save the world |
| `/status` | Show server state, IP, and player count |
| `/allowlist add <player>` | Whitelist a player |
| `/allowlist remove <player>` | Remove a player from the whitelist |
| `/modpacks` | List available modpacks and mrpack download links |

## First-time setup

### 1. Infrastructure
```bash
cd infra
tofu init && tofu apply -var-file=prod.tfvars
```

### 2. Cloudflare Worker
```bash
cd worker
wrangler d1 create sploosh           # paste database_id into wrangler.toml
wrangler d1 execute sploosh --file schema.sql
wrangler secret put AWS_ACCESS_KEY_ID
wrangler secret put AWS_SECRET_ACCESS_KEY
wrangler secret put DISCORD_PUBLIC_KEY
wrangler secret put DISCORD_APP_ID
wrangler secret put DISCORD_BOT_TOKEN
wrangler secret put ADMIN_SECRET
wrangler secret put IDLE_WEBHOOK_SECRET
wrangler deploy
```

### 3. Register Discord slash commands
```bash
DISCORD_APP_ID=... DISCORD_BOT_TOKEN=... npx tsx scripts/register-commands.ts
```

### 4. CI secrets (GitHub repo settings)
| Secret | Description |
|---|---|
| `CACHIX_AUTH_TOKEN` | Nix binary cache |
| `AWS_ROLE_ARN` | OIDC role for AMI upload |
| `CF_WORKER_URL` | Worker URL for AMI registration callback |
| `CF_WORKER_SECRET` | HMAC secret for the above |
| `CLOUDFLARE_API_TOKEN` | For `wrangler deploy` in CI |

Push to `main` → CI builds AMIs + mrpacks + deploys worker automatically.

## Development

```bash
nix develop          # drops into shell with packwiz, wrangler, tofu, mcrcon, etc.
```

### Add a mod
```bash
cd modpacks/create-central
packwiz mr add <modrinth-slug>
packwiz refresh
```

### Add a modpack
1. `mkdir modpacks/<name> && cd modpacks/<name> && packwiz init`
2. Add mods with `packwiz mr add <slug>`
3. Add entry to `modpacks/default.nix`
4. Push — CI builds the AMI and mrpack

### Build mrpack locally
```bash
nix develop --command bash -c "cd modpacks/create-central && packwiz modrinth export -o /tmp/create-central.mrpack"
```

### Apply infra changes
```bash
cd infra && tofu plan -var-file=prod.tfvars && tofu apply -var-file=prod.tfvars
```
