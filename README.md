# dokku-multideploy

Deploy multiple applications to a single Dokku server with centralized configuration. Import existing apps from a server, migrate between servers, or set up fresh deployments.

## Features

- **Multi-app orchestration** - Deploy multiple independent repos from one config
- **Hierarchical configuration** - Parent settings cascade to deployments, child overrides parent
- **Smart deployment** - Skips unchanged apps (compares git commits)
- **Secrets management** - Hierarchical `.env` files, gitignored
- **Pre/post deploy hooks** - Run scripts before/after deployment
- **Tag-based filtering** - Deploy subsets by tag (`--tag staging`, `--tag api`)
- **PostgreSQL auto-setup** - Opt-in automatic database provisioning
- **Let's Encrypt SSL** - Opt-in automatic SSL certificate provisioning
- **Storage mounts, ports, domains** - Full Dokku configuration support
- **Server import/migration** - Import all apps from existing server, migrate to new server
- **Backup & Restore** - Backup/restore PostgreSQL databases and storage mounts with xz compression

## Prerequisites

Configure your Dokku server in `~/.ssh/config`:

```
Host <ssh-alias>
  HostName <your-server-ip>
  User root
  IdentityFile ~/.ssh/<your-key>
  IdentitiesOnly yes
```

Then use `<ssh-alias>` as the `ssh_alias` in your config.json.

## Global Install

You can run this from any project by symlinking it into your `PATH`:

```bash
mkdir -p ~/bin
ln -sf /absolute/path/to/dokku-multideploy/deploy.sh ~/bin/deploy
chmod +x /absolute/path/to/dokku-multideploy/deploy.sh
```

Then use it inside any app folder that has `config.json`:

```bash
deploy --dry-run
deploy --sync
```

Notes:
- If you use fish shell and `deploy` is not found, add `~/bin` to fish paths:
  `set -Ux fish_user_paths ~/bin $fish_user_paths`
  Then restart your shell and verify with:
  `command -v deploy`
- By default, `deploy` looks for `config.json` next to the invoked script/symlink, then falls back to `$PWD/config.json`.
- You can always override explicitly:
  `CONFIG_FILE=$PWD/config.json deploy --dry-run`

## Quick Start

### Migrate existing Dokku server (most common)

```bash
# 1. Clone this repo
git clone https://github.com/benmarten/dokku-multideploy.git

# 2. Import all apps from your existing server to a separate directory
./dokku-multideploy/deploy.sh --import ./apps --ssh <ssh-alias>

# 3. Backup databases and storage mounts
cd apps
ln -s ../dokku-multideploy/deploy.sh .
./deploy.sh --backup

# 4. Update config.json with new server details
#    Change ssh_host and ssh_alias to new server

# 5. Deploy everything to new server
./deploy.sh --dry-run  # Preview first
./deploy.sh

# 6. Restore backups on new server
SSH_HOST=<new-server> ./restore.sh backups/<timestamp>
```

### Fresh setup

```bash
# 1. Clone and set up your project
git clone https://github.com/benmarten/dokku-multideploy.git
cd <your-project>
ln -s <path-to>/dokku-multideploy/deploy.sh .
cp <path-to>/dokku-multideploy/config.example.json config.json
# Edit config.json with your apps

# 2. Add secrets (optional)
mkdir -p .env
echo "DATABASE_PASSWORD=secret" > .env/api.example.com

# 3. Deploy!
./deploy.sh
```

## Import from Existing Server

Already have apps running on a Dokku server? Import everything:

```bash
# Import all apps from your Dokku server
./deploy.sh --import ./apps --ssh <ssh-alias>

# Import without secrets (env vars)
./deploy.sh --import ./apps --ssh <ssh-alias> --no-secrets
```

This will:
1. Clone all app git repos to `./apps/<domain>/`
2. Generate `config.json` with settings (domains, ports, storage, postgres, letsencrypt)
3. Export all env vars to `.env/` files (not config.json, since we can't distinguish secrets)

Then symlink deploy.sh and you're ready:
```bash
cd ./apps
ln -s <path-to>/dokku-multideploy/deploy.sh .
./deploy.sh --dry-run
```

## Server Migration

Migrate all apps to a new server:

```bash
# 1. Import from current server (if not already done)
./deploy.sh --import ./apps --ssh <old-server>

# 2. Set up new server with Dokku
ssh <new-server> "wget -NP . https://dokku.com/install/v0.34.4/bootstrap.sh && sudo bash bootstrap.sh"

# 3. Update SSH config for new server
#    Edit ~/.ssh/config to add <new-server> alias

# 4. Update config.json
#    Change ssh_host and ssh_alias to new server

# 5. Deploy everything to new server
./deploy.sh
```

The script will create all apps, configure domains, env vars, storage mounts, ports, postgres, and letsencrypt on the new server.

## Directory Structure

```
your-project/
├── deploy.sh              # Symlink to dokku-multideploy/deploy.sh
├── restore.sh             # Symlink to dokku-multideploy/restore.sh
├── config.json              # Your deployment configuration
├── .env/                    # Secret environment variables (gitignored)
│   ├── _api                 # Shared secrets for all "api" source_dir apps
│   ├── api.example.com      # Secrets specific to api.example.com
│   └── api-staging.example.com
├── certs/                   # Custom SSL certificates (optional)
│   └── api-example-com/
│       ├── server.crt
│       └── server.key
├── backups/                 # Backup files (gitignored)
│   └── 2026-01-06_143022/   # Timestamped backup folder
│       ├── api-example-com-db.dump.xz
│       └── api-example-com-storage-1.tar.xz
├── api/                     # Your API source code
│   ├── Dockerfile
│   ├── pre-deploy.sh        # Runs before deploy (e.g., migrations)
│   └── post-deploy.sh       # Runs after deploy (e.g., seed data)
└── web/                     # Your web app source code
    └── Dockerfile
```

## Configuration

### config.json

```json
{
  "ssh_host": "dokku@<your-server-ip>",
  "ssh_alias": "<ssh-alias>",

  "api": {
    "source_dir": "api",
    "branch": "main",
    "postgres": true,
    "letsencrypt": true,
    "env_vars": {
      "NODE_ENV": "production"
    },
    "deployments": {
      "api.example.com": {
        "tags": ["production", "api"],
        "env_vars": {
          "LOG_LEVEL": "warn"
        }
      },
      "api-staging.example.com": {
        "tags": ["staging", "api"],
        "env_vars": {
          "LOG_LEVEL": "debug"
        }
      }
    }
  }
}
```

### Configuration Options

#### Root Level
| Key | Description |
|-----|-------------|
| `ssh_host` | Full SSH host for git push (e.g., `dokku@1.2.3.4`) |
| `ssh_alias` | SSH alias for commands (e.g., `dokku` if configured in `~/.ssh/config`) |

#### Parent Level (e.g., "api", "web")
| Key | Description |
|-----|-------------|
| `source_dir` | Directory containing the source code and Dockerfile. Supports relative paths (`api`, `../sibling-repo`) or absolute paths (`/path/to/project`) |
| `branch` | Git branch to deploy (auto-detects if not set) |
| `postgres` | Auto-create and link PostgreSQL database (`true`/`false`) |
| `letsencrypt` | Auto-provision Let's Encrypt SSL (`true`/`false`) |
| `env_vars` | Environment variables (set at runtime) |
| `build_args` | Docker build arguments (set at build time) |
| `storage_mounts` | Array of storage mounts - string `"host:container"` or object `{"mount": "host:container", "backup": false}` |
| `ports` | Array of port mappings (`"http:80:3000"`) |
| `extra_domains` | Additional domains to add |
| `plugins` | Dokku plugins to install |

#### Deployment Level
Same options as parent level, plus:
| Key | Description |
|-----|-------------|
| `tags` | Array of tags for filtering (`["production", "api"]`) |

Child settings override parent settings.

### Secrets (.env files)

Secrets are loaded hierarchically:
1. `.env/_<source_dir>` - Shared secrets for all apps with that source_dir
2. `.env/<domain>` - Domain-specific secrets (overrides shared)

```bash
# .env/_api (shared by all api deployments)
DATABASE_PASSWORD=shared-secret
API_KEY=common-key

# .env/api.example.com (production-specific)
DATABASE_PASSWORD=production-secret
```

## Usage

```bash
# Deploy all apps
./deploy.sh

# Deploy specific app(s)
./deploy.sh api.example.com
./deploy.sh api.example.com www.example.com

# Deploy by tag
./deploy.sh --tag staging
./deploy.sh --tag api
./deploy.sh --tag staging --tag api  # OR logic

# Skip production
./deploy.sh --no-prod

# Dry run (see what would happen)
./deploy.sh --dry-run

# Force deploy (even if no code changes)
./deploy.sh --force

# Update config only (no code deploy, just env vars + restart)
./deploy.sh --config-only api.example.com

# Skip confirmation prompts
./deploy.sh --yes
```

## Sync Check

Compare local `config.json` against live Dokku state without deploying:

```bash
# Check all selected deployments
./deploy.sh --sync

# Check only a subset
./deploy.sh --sync --tag staging
./deploy.sh --sync api.example.com

# Re-import live state before checking
./deploy.sh --sync --refresh-sync

# Clear cache and re-import
./deploy.sh --sync --reset-sync
```

`--sync` behavior:
1. Imports current Dokku app config to `.sync-cache/` (no git clone, no env secret export)
2. Compares local vs remote by domain
3. Reports:
   - `✓ In sync`
   - `✗ Missing on Dokku`
   - `⚠ Drift` with per-field differences

Cache options:
- `--refresh-sync`: refresh `.sync-cache/config.json` before comparing
- `--reset-sync`: clear the sync cache directory, then import fresh
- `--sync-dir <dir>`: use a custom cache directory

Exit codes:
- `0`: all selected deployments are in sync
- `1`: drift/missing detected or sync check failed

## Backup

Backup PostgreSQL databases and storage mounts to compressed `.xz` files:

```bash
# Backup all apps
./deploy.sh --backup

# Backup to custom directory
./deploy.sh --backup --backup-dir ~/dokku-backups

# Backup specific app
./deploy.sh --backup api.example.com

# Backup by tag
./deploy.sh --backup --tag production

# Dry run (see what would be backed up)
./deploy.sh --backup --dry-run
```

This creates timestamped backup folders:
```
./backups/2026-01-06_143022/
├── api-example-com-db.dump.xz       # PostgreSQL dump (pg_dump custom format)
└── api-example-com-storage-1.tar.xz # Storage mount contents
```

Backups are saved to `./backups/<timestamp>/` by default (gitignored).

## Restore

Restore PostgreSQL databases and storage mounts from a backup:

```bash
# Restore to default server (from config.json ssh_alias)
./restore.sh backups/2026-01-31_085506

# Restore to specific server
SSH_HOST=co2 ./restore.sh backups/2026-01-31_085506

# Dry run (see what would be restored)
./restore.sh backups/2026-01-31_085506 --dry-run
```

The restore script will:
1. Install postgres plugin if needed
2. Create databases if they don't exist, or import into existing ones
3. Extract storage archives to `/var/lib/dokku/data/storage/<app>/`
4. Fix permissions for Dokku

**Workflow for server migration:**
```bash
# 1. Deploy apps to new server (creates apps, empty DBs, storage mounts)
CONFIG_FILE=config-newserver.json ./deploy.sh

# 2. Restore data from backup
SSH_HOST=newserver ./restore.sh backups/2026-01-31_085506
```

## Deploy Hooks

Create `pre-deploy.sh` or `post-deploy.sh` in your source directory:

```bash
# api/pre-deploy.sh
#!/bin/bash
echo "Running migrations..."
npm run db:migrate

# api/post-deploy.sh
#!/bin/bash
echo "Seeding database..."
npm run db:seed
```

The `APP_NAME` environment variable is available in hooks.

## How It Works

1. **Parse config** - Reads `config.json`, merges parent/child settings
2. **Filter** - Applies tag filters and deployment selection
3. **For each app:**
   - Sync with git origin
   - Check if deployment needed (compare commits)
   - Create Dokku app if needed
   - Configure PostgreSQL if enabled
   - Set domains
   - Mount storage
   - Set port mappings
   - Load secrets from `.env` files
   - Set env vars and build args
   - Run pre-deploy hook
   - Git push to Dokku
   - Run post-deploy hook
   - Health check
   - Enable Let's Encrypt if configured

## Requirements

- `bash` 4.0+
- `jq` - JSON processor (`brew install jq` or `apt install jq`)
- `git`
- `ssh` access to your Dokku server
- `curl` (for health checks)
- `xz` (for backup mode - usually pre-installed)

## SSH Configuration

Add to `~/.ssh/config`:

```
Host <ssh-alias>
    HostName <your-server-ip>
    User dokku
    IdentityFile ~/.ssh/<your-key>
```

Then set `"ssh_alias": "<ssh-alias>"` in config.json.

## License

MIT
