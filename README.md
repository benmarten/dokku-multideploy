# dokku-multideploy

Deploy multiple applications to a single Dokku server with centralized configuration.

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
- **Import from existing server** - Pull all apps and config from a Dokku server

## Prerequisites

Configure your Dokku server in `~/.ssh/config`:

```
Host dokku
  HostName your-server-ip
  User root
  IdentityFile ~/.ssh/id_rsa
  IdentitiesOnly yes
```

Then use `dokku` as the `ssh_alias` in your config.json.

## Quick Start

```bash
# 1. Clone this repo (or copy files to your project)
git clone https://github.com/benmarten/dokku-multideploy.git
cd dokku-multideploy

# 2. Create your config
cp config.example.json config.json
# Edit config.json with your apps

# 3. Add secrets (optional)
mkdir -p .env
echo "DATABASE_PASSWORD=secret" > .env/api.example.com

# 4. Deploy!
./deploy.sh
```

## Import from Existing Server

Already have apps running on a Dokku server? Import everything:

```bash
# Import all apps from your Dokku server
./deploy.sh --import ./apps --ssh your-ssh-alias

# Import without secrets (env vars)
./deploy.sh --import ./apps --ssh your-ssh-alias --no-secrets
```

This will:
1. Clone all app git repos to `./apps/<domain>/`
2. Generate `config.json` with settings (domains, ports, storage, postgres, letsencrypt)
3. Export all env vars to `.env/` files (not config.json, since we can't distinguish secrets)

Then symlink deploy.sh and you're ready:
```bash
cd ./apps
ln -s /path/to/dokku-multideploy/deploy.sh .
./deploy.sh --dry-run
```

## Server Migration

Migrate all apps to a new server:

```bash
# 1. Import from current server (if not already done)
./deploy.sh --import ./apps --ssh old-server

# 2. Set up new server with Dokku
ssh new-server "wget -NP . https://dokku.com/install/v0.34.4/bootstrap.sh && sudo bash bootstrap.sh"

# 3. Update SSH config for new server
#    Edit ~/.ssh/config to add new-server alias

# 4. Update config.json
#    Change ssh_host and ssh_alias to new server

# 5. Deploy everything to new server
./deploy.sh
```

The script will create all apps, configure domains, env vars, storage mounts, ports, postgres, and letsencrypt on the new server.

## Directory Structure

```
your-project/
├── deploy.sh              # Main deployment script
├── config.json              # Your deployment configuration
├── .env/                    # Secret environment variables (gitignored)
│   ├── _api                 # Shared secrets for all "api" source_dir apps
│   ├── api.example.com      # Secrets specific to api.example.com
│   └── api-staging.example.com
├── certs/                   # Custom SSL certificates (optional)
│   └── api-example-com/
│       ├── server.crt
│       └── server.key
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
  "ssh_host": "dokku@your-server.com",
  "ssh_alias": "dokku",

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
| `storage_mounts` | Array of storage mounts (`"host:container"`) |
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

## SSH Configuration

Add to `~/.ssh/config`:

```
Host dokku
    HostName your-server.com
    User dokku
    IdentityFile ~/.ssh/your-key
```

Then set `"ssh_alias": "dokku"` in config.json.

## License

MIT
