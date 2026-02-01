#!/bin/bash
set -euo pipefail

# Configuration
BACKUP_DIR="${1:-}"
SSH_HOST="${SSH_HOST:-co2}"
DRY_RUN="${DRY_RUN:-false}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_header() {
    echo -e "\n${BLUE}═══════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}   $1${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}\n"
}

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

run_cmd() {
    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "${YELLOW}[DRY-RUN]${NC} $1"
    else
        eval "$1"
    fi
}

run_ssh() {
    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "${YELLOW}[DRY-RUN]${NC} ssh $SSH_HOST \"$1\""
    else
        ssh "$SSH_HOST" "$1"
    fi
}

usage() {
    cat <<EOF
Usage: $0 <backup_dir> [options]

Options:
    --dry-run       Show what would be done without executing
    --host <host>   SSH host to restore to (default: co2)
    --help          Show this help message

Examples:
    $0 backups/2026-01-31_085506
    $0 backups/2026-01-31_085506 --dry-run
    SSH_HOST=co2 $0 backups/2026-01-31_085506
EOF
    exit 1
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --host)
            SSH_HOST="$2"
            shift 2
            ;;
        --help)
            usage
            ;;
        *)
            if [[ -z "$BACKUP_DIR" ]]; then
                BACKUP_DIR="$1"
            fi
            shift
            ;;
    esac
done

if [[ -z "$BACKUP_DIR" ]]; then
    log_error "Backup directory required"
    usage
fi

if [[ ! -d "$BACKUP_DIR" ]]; then
    log_error "Backup directory not found: $BACKUP_DIR"
    exit 1
fi

print_header "dokku-restore"

log_info "Backup directory: $BACKUP_DIR"
log_info "Target host: $SSH_HOST"
[[ "$DRY_RUN" == "true" ]] && log_warn "Dry run mode enabled"

# Check SSH connectivity
echo ""
log_info "Checking SSH connectivity..."
if ! ssh -o ConnectTimeout=5 "$SSH_HOST" "echo 'Connected'" &>/dev/null; then
    log_error "Cannot connect to $SSH_HOST"
    exit 1
fi
log_info "Connected to $SSH_HOST"

# Check if dokku is available
if ! ssh "$SSH_HOST" "command -v dokku" &>/dev/null; then
    log_error "Dokku not found on $SSH_HOST"
    exit 1
fi

# Restore postgres databases
print_header "Restoring Postgres Databases"

for dump_file in "$BACKUP_DIR"/*.dump.xz "$BACKUP_DIR"/*.dump; do
    [[ -f "$dump_file" ]] || continue

    filename=$(basename "$dump_file")

    # Extract db name from filename (remove .dump.xz or .dump suffix)
    db_name="${filename%.dump.xz}"
    db_name="${db_name%.dump}"

    log_info "Found database backup: $filename -> $db_name"

    # Ensure postgres plugin is installed
    if ! ssh "$SSH_HOST" "dokku plugin:list | grep -q postgres"; then
        log_info "Installing postgres plugin..."
        run_ssh "sudo dokku plugin:install https://github.com/dokku/dokku-postgres.git postgres"
    fi

    # Create database if it doesn't exist
    db_exists=$(ssh "$SSH_HOST" "dokku postgres:exists $db_name && echo yes || echo no" 2>/dev/null)
    if [[ "$db_exists" == *"yes"* ]]; then
        log_info "Database $db_name already exists, importing data..."
    else
        log_info "Creating database: $db_name"
        run_ssh "dokku postgres:create $db_name"
    fi

    # Import data
    log_info "Importing data into $db_name..."
    if [[ "$DRY_RUN" != "true" ]]; then
        if [[ "$dump_file" == *.xz ]]; then
            xz -dkc "$dump_file" | ssh "$SSH_HOST" "dokku postgres:import $db_name"
        else
            cat "$dump_file" | ssh "$SSH_HOST" "dokku postgres:import $db_name"
        fi
    else
        echo -e "${YELLOW}[DRY-RUN]${NC} xz -dkc $dump_file | ssh $SSH_HOST \"dokku postgres:import $db_name\""
    fi

    log_info "Database $db_name restored successfully"
done

# Restore storage volumes
print_header "Restoring Storage Volumes"

for storage_file in "$BACKUP_DIR"/*.tar.xz "$BACKUP_DIR"/*.tar.gz "$BACKUP_DIR"/*.tar; do
    [[ -f "$storage_file" ]] || continue

    filename=$(basename "$storage_file")

    # Extract app name from filename
    # New format: app-name-storage.tar.xz (single backup, preserves structure)
    # Old format: app-name-storage-N.tar.xz (multiple backups, no structure)
    if [[ "$filename" =~ ^(.+)-storage\.tar ]]; then
        app_name="${BASH_REMATCH[1]}"
        is_old_format=false
    elif [[ "$filename" =~ ^(.+)-storage-([0-9]+)\.tar ]]; then
        app_name="${BASH_REMATCH[1]}"
        is_old_format=true
        log_warn "Old backup format detected: $filename"
        log_warn "Files may not restore to correct mount paths"
    else
        log_warn "Unknown storage format: $filename, skipping..."
        continue
    fi

    log_info "Found storage backup: $filename -> app: $app_name"

    # Determine storage path on remote
    storage_path="/var/lib/dokku/data/storage/$app_name"

    # Create storage directory if needed
    log_info "Ensuring storage directory exists: $storage_path"
    run_ssh "mkdir -p $storage_path"

    # Extract archive (no strip-components, preserves directory structure)
    log_info "Extracting storage to $storage_path..."
    if [[ "$DRY_RUN" != "true" ]]; then
        if [[ "$storage_file" == *.xz ]]; then
            xz -dkc "$storage_file" | ssh "$SSH_HOST" "tar -xf - -C $storage_path"
        elif [[ "$storage_file" == *.gz ]]; then
            gzip -dkc "$storage_file" | ssh "$SSH_HOST" "tar -xf - -C $storage_path"
        else
            cat "$storage_file" | ssh "$SSH_HOST" "tar -xf - -C $storage_path"
        fi
    else
        echo -e "${YELLOW}[DRY-RUN]${NC} xz -dkc $storage_file | ssh $SSH_HOST \"tar -xf - -C $storage_path\""
    fi

    # Fix permissions
    log_info "Fixing permissions for $storage_path..."
    run_ssh "chown -R dokku:dokku $storage_path"

    log_info "Storage for $app_name restored successfully"
done

print_header "Restore Complete"

log_info "Summary:"
log_info "  - Databases and storage volumes have been restored"
log_info ""
log_info "Next step: Deploy apps"
log_info "  CONFIG_FILE=<config> ./deploy.sh"
log_info ""
log_info "The deploy script will automatically link databases and mount storage."
