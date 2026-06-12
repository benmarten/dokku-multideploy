# Server Migration Guide

This guide covers migrating Dokku applications from one server to another using dokku-multideploy's backup/restore functionality.

## Overview

The migration process involves:
1. Setting up the new server
2. Stopping apps on the old server (to prevent data changes)
3. Backing up databases and small storage from the old server
4. Restoring databases and small storage to the new server
5. Deploying all apps on the new server
6. Syncing large storage directories directly between servers

## Prerequisites

- SSH access to both old and new servers
- SSH aliases configured for both servers (e.g., `viewtlab` and `viewtlab-nonprod`)
- dokku-multideploy installed locally
- Config files prepared for new server (e.g., `config.nonprod.json`, `config.prod.json`)

## Migration Steps

### 1. Setup Fresh Server

Install Dokku, plugins, and configure the server:

```bash
CONFIG_FILE=config.nonprod.json deploy --setup
```

This will:
- Install required Dokku plugins (MySQL, PostgreSQL, Let's Encrypt, etc.)
- Configure Let's Encrypt email
- Set up Docker networks
- Configure MySQL port exposures

### 2. Stop Apps on Old Server

Prevent data changes during migration by stopping all apps:

```bash
# Stop nonprod apps
CONFIG_FILE=config.json deploy --stop --tag nonprod

# Or stop production apps
CONFIG_FILE=config.json deploy --stop --tag production
```

### 3. Backup from Old Server

Backup databases and storage (excluding large directories):

```bash
# Backup nonprod
CONFIG_FILE=config.json deploy --backup --tag nonprod \
  --backup-dir ./backups/nonprod-$(date +%Y%m%d-%H%M%S)

# Backup production
CONFIG_FILE=config.json deploy --backup --tag production \
  --backup-dir ./backups/prod-$(date +%Y%m%d-%H%M%S)
```

**Note:** The backup will automatically:
- Only backup MySQL databases used by apps matching the tag filter
- Skip storage directories larger than 100MB (configurable via `BACKUP_MAX_STORAGE_MB`)
- Show a summary of skipped paths that need manual rsync

### 4. Restore to New Server

Restore databases and storage to the new server:

```bash
# Restore nonprod (use actual timestamp from step 3)
CONFIG_FILE=config.nonprod.json deploy --restore \
  ./backups/nonprod-20260612-133147/2026-06-12_133150

# Restore production
CONFIG_FILE=config.prod.json deploy --restore \
  ./backups/prod-20260612-134042/2026-06-12_134042
```

This will:
- Create MySQL/PostgreSQL services if they don't exist
- Import database dumps
- Restore small storage directories

### 5. Deploy Apps

Deploy all applications to link databases, configure networks, and start apps:

```bash
# Deploy nonprod apps
CONFIG_FILE=config.nonprod.json deploy --tag nonprod --force

# Deploy production apps
CONFIG_FILE=config.prod.json deploy --tag production --force
```

The `--force` flag ensures deployment even if commits match, which is necessary for:
- Initial deployment to fresh server
- Linking databases to apps
- Setting up storage mounts
- Configuring environment variables
- Setting up SSL certificates

### 6. Sync Large Storage Directories

For directories that were too large to backup (listed in the backup summary), use direct server-to-server rsync:

```bash
# Server-to-server rsync (run from your local machine)
# Data transfers directly between servers, not through your machine

# Example: Nonprod uploads
ssh viewtlab "rsync -avz --progress \
  /var/lib/dokku/data/storage/test-viewtlab-com-be/uploads/ \
  viewtlab-nonprod:/var/lib/dokku/data/storage/test-viewtlab-com-be/uploads/"

ssh viewtlab "rsync -avz --progress \
  /var/lib/dokku/data/storage/staging-viewtlab-com-be/uploads/ \
  viewtlab-nonprod:/var/lib/dokku/data/storage/staging-viewtlab-com-be/uploads/"

# Example: Sentry data
ssh viewtlab "rsync -avz --progress \
  /var/lib/dokku/data/storage/sentry-viewtlab-com/ \
  viewtlab-nonprod:/var/lib/dokku/data/storage/sentry-viewtlab-com/"

# Example: Production uploads
ssh viewtlab "rsync -avz --progress \
  /var/lib/dokku/data/storage/www-viewtlab-com-be/uploads/ \
  viewtlab-prod:/var/lib/dokku/data/storage/www-viewtlab-com-be/uploads/"
```

**Why server-to-server rsync?**
- 🚀 Much faster (uses server bandwidth, not your home internet)
- 💾 Doesn't fill up your local disk
- 🔒 Direct encrypted connection between servers

## Complete Example: Nonprod Migration

```bash
# 1. Setup fresh nonprod server
CONFIG_FILE=config.nonprod.json deploy --setup

# 2. Stop all nonprod apps on OLD server
CONFIG_FILE=config.json deploy --stop --tag nonprod

# 3. Backup nonprod from old server
CONFIG_FILE=config.json deploy --backup --tag nonprod \
  --backup-dir ./backups/nonprod-$(date +%Y%m%d-%H%M%S)

# 4. Restore to new nonprod server
CONFIG_FILE=config.nonprod.json deploy --restore \
  ./backups/nonprod-20260612-133147/2026-06-12_133150

# 5. Deploy all nonprod apps
CONFIG_FILE=config.nonprod.json deploy --tag nonprod --force

# 6. Rsync large storage directories
ssh viewtlab "rsync -avz --progress \
  /var/lib/dokku/data/storage/test-viewtlab-com-be/uploads/ \
  viewtlab-nonprod:/var/lib/dokku/data/storage/test-viewtlab-com-be/uploads/"

ssh viewtlab "rsync -avz --progress \
  /var/lib/dokku/data/storage/staging-viewtlab-com-be/uploads/ \
  viewtlab-nonprod:/var/lib/dokku/data/storage/staging-viewtlab-com-be/uploads/"

ssh viewtlab "rsync -avz --progress \
  /var/lib/dokku/data/storage/sentry-viewtlab-com/ \
  viewtlab-nonprod:/var/lib/dokku/data/storage/sentry-viewtlab-com/"
```

## Verification

After migration, verify everything is working:

```bash
# List all deployed apps
CONFIG_FILE=config.nonprod.json deploy --list

# Check app status on new server
ssh viewtlab-nonprod "dokku ps:report"

# Test each application endpoint
curl https://test.viewtlab.com/api/v1/version
curl https://staging.viewtlab.com/api/v1/version
```

## Troubleshooting

### MySQL restore fails with "Permission denied"

If you get a permission error when creating MySQL services on a fresh server:

```bash
# Create the services directory manually with proper permissions
ssh viewtlab-nonprod "sudo mkdir -p /var/lib/dokku/services && sudo chown dokku:dokku /var/lib/dokku/services"
```

Then retry the restore.

### Apps not starting after deployment

Check logs:
```bash
ssh viewtlab-nonprod "dokku logs <app-name> --tail 100"
```

Common issues:
- Database not linked: `dokku mysql:link <db> <app>`
- Environment variables missing: Check config file and redeploy
- Storage mount not created: Check if rsync completed successfully

### Rsync permission issues

If rsync fails with permission errors, you may need to run it with sudo on the source server:

```bash
ssh viewtlab "sudo rsync -avz --progress \
  /var/lib/dokku/data/storage/test-viewtlab-com-be/uploads/ \
  viewtlab-nonprod:/var/lib/dokku/data/storage/test-viewtlab-com-be/uploads/"
```

## Post-Migration Cleanup

After verifying the new server is working:

1. **Update DNS** to point to the new server
2. **Monitor** the new server for 24-48 hours
3. **Keep the old server running** as a fallback for a few days
4. **Archive backups** before decommissioning the old server
5. **Start old apps again** if needed: `CONFIG_FILE=config.json deploy --start --tag nonprod`

## Environment-Specific Considerations

### Nonprod Migration

- Typically less critical, can afford brief downtime
- Good for testing the migration process before production
- May have shared services (sentry, vault) that serve both test and staging

### Production Migration

- Requires careful planning and maintenance window
- Consider blue-green deployment or gradual traffic shift
- Test extensively in nonprod first
- Have rollback plan ready
- Coordinate with team and stakeholders

## Tag Filtering

The backup/restore system respects tag filters to ensure you only backup/restore what you need:

```bash
# Only backup production databases (not nonprod or dmf databases)
CONFIG_FILE=config.json deploy --backup --tag production

# Only backup nonprod databases (not production)
CONFIG_FILE=config.json deploy --backup --tag nonprod
```

This prevents accidentally mixing production and nonprod data during migration.
