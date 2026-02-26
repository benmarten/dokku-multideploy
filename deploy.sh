#!/usr/bin/env bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Resolve the real script location (follow symlinks) so modules load correctly
SCRIPT_SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SCRIPT_SOURCE" ]; do
    SCRIPT_DIR_TMP="$(cd -P "$(dirname "$SCRIPT_SOURCE")" && pwd)"
    SCRIPT_TARGET="$(readlink "$SCRIPT_SOURCE")"
    if [[ "$SCRIPT_TARGET" != /* ]]; then
        SCRIPT_SOURCE="$SCRIPT_DIR_TMP/$SCRIPT_TARGET"
    else
        SCRIPT_SOURCE="$SCRIPT_TARGET"
    fi
done

# Script location and config resolution
# Priority:
# 1) CONFIG_FILE env var (if provided)
# 2) config.json next to invoked script/symlink
# 3) config.json in current working directory (for global `deploy` command)
SCRIPT_HOME="$(cd -P "$(dirname "$SCRIPT_SOURCE")" && pwd)"
SCRIPT_DIR="$SCRIPT_HOME"
if [ -n "${CONFIG_FILE:-}" ]; then
    if [[ "$CONFIG_FILE" != /* ]]; then
        CONFIG_FILE="$PWD/$CONFIG_FILE"
    fi
    SCRIPT_DIR="$(cd "$(dirname "$CONFIG_FILE")" && pwd)"
elif [ -f "$SCRIPT_DIR/config.json" ]; then
    CONFIG_FILE="$SCRIPT_DIR/config.json"
elif [ -f "$PWD/config.json" ]; then
    SCRIPT_DIR="$PWD"
    CONFIG_FILE="$PWD/config.json"
else
    CONFIG_FILE="$SCRIPT_DIR/config.json"
fi

# Check for jq
if ! command -v jq &> /dev/null; then
    echo -e "${RED}Error: jq is required but not installed.${NC}"
    echo "Install with: brew install jq (macOS) or apt install jq (Linux)"
    exit 1
fi

# Check for xz (needed for backup mode)
if ! command -v xz &> /dev/null; then
    XZ_AVAILABLE=false
else
    XZ_AVAILABLE=true
fi

# Parse options
DRY_RUN=false
NO_PROD=false
YES_TO_ALL=false
FORCE_DEPLOY=false
CONFIG_ONLY=false
IMPORT_MODE=false
IMPORT_DIR=""
IMPORT_SECRETS=true
IMPORT_SSH=""
IMPORT_NO_CLONE=false
BACKUP_MODE=false
BACKUP_DIR=""
RESTORE_MODE=false
RESTORE_DIR=""
SETUP_MODE=false
SETUP_EMAIL=""
SYNC_MODE=false
SYNC_DIR=""
SYNC_REFRESH=false
SYNC_RESET=false
FILTER_TAGS=()
SELECTED_DEPLOYMENTS=()

show_help() {
    echo "Usage: $0 [OPTIONS] [DEPLOYMENTS...]"
    echo ""
    echo "Deploy multiple applications to Dokku"
    echo ""
    echo "Options:"
    echo "  --dry-run           Show what would be deployed without deploying"
    echo "  --force             Force deployment even if commits match (for config changes)"
    echo "  --config-only       Only update env vars and restart (no code deploy)"
    echo "  --no-prod           Skip production deployments"
    echo "  --yes               Skip confirmation prompts (use with caution)"
    echo "  --tag <tag>         Deploy only apps with this tag (can be used multiple times)"
    echo "  --import <dir>      Import all apps from Dokku server to <dir>"
    echo "  --ssh <alias>       SSH alias for Dokku server (use with --import)"
    echo "  --no-secrets        Skip importing env vars (use with --import)"
    echo "  --no-clone          Skip cloning repos, only generate config.json and .env files (use with --import)"
    echo "  --backup            Backup PostgreSQL/MySQL databases and storage mounts"
    echo "  --restore <dir>     Restore PostgreSQL/MySQL databases and storage from backup dir"
    echo "  --backup-dir <dir>  Backup directory (default: ./backups)"
    echo "  --setup             Setup a fresh Dokku server (install plugins, configure)"
    echo "  --email <email>     Let's Encrypt email (use with --setup)"
    echo "  --sync              Compare local config against live Dokku state"
    echo "  --sync-dir <dir>    Directory to store/reuse imported sync state"
    echo "  --refresh-sync      Re-import Dokku state before sync check"
    echo "  --reset-sync        Clear sync cache directory before importing"
    echo "  --help              Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0                               # Deploy all"
    echo "  $0 --dry-run                     # Show what would be deployed"
    echo "  $0 --force                       # Force deploy (for config/env changes)"
    echo "  $0 --config-only api.example.com # Update config only, restart"
    echo "  $0 --no-prod                     # Deploy all except production"
    echo "  $0 --tag api                     # Deploy only apps tagged 'api'"
    echo "  $0 --tag staging --tag api       # Deploy apps tagged 'staging' OR 'api'"
    echo "  $0 api.example.com               # Deploy specific app"
    echo "  $0 api.example.com www.example.com  # Deploy multiple apps"
    echo ""
    echo "Import from existing Dokku server:"
    echo "  $0 --import ./apps --ssh co     # Clone all apps, generate config.json"
    echo "  $0 --import ./apps --ssh co --no-secrets # Import without env vars"
    echo ""
    echo "Backup databases and storage:"
    echo "  $0 --backup                              # Backup all apps to ./backups"
    echo "  $0 --backup --backup-dir ~/my-backups   # Backup to custom directory"
    echo "  $0 --backup --tag production            # Backup only production apps"
    echo "  $0 --backup api.example.com             # Backup specific app"
    echo "  $0 --restore ./backups/2026-02-25_125435 # Restore from backup directory"
    echo ""
    echo "Setup a fresh Dokku server:"
    echo "  $0 --setup --email admin@example.com   # Setup server from config.json"
    echo "  $0 --setup --ssh co-new --email a@b.c  # Setup specific server"
    echo "  $0 --setup                              # Interactive setup (prompts for email)"
    echo "  $0 --sync                               # Check config drift against Dokku"
    echo "  $0 --sync --refresh-sync                # Force refresh live state first"
    echo "  $0 --sync --sync-dir .sync-cache        # Reuse specific sync cache dir"
    echo ""
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --force)
            FORCE_DEPLOY=true
            shift
            ;;
        --config-only)
            CONFIG_ONLY=true
            shift
            ;;
        --no-prod)
            NO_PROD=true
            shift
            ;;
        --yes|-y)
            YES_TO_ALL=true
            shift
            ;;
        --tag)
            FILTER_TAGS+=("$2")
            shift 2
            ;;
        --import)
            IMPORT_MODE=true
            IMPORT_DIR="$2"
            shift 2
            ;;
        --ssh)
            IMPORT_SSH="$2"
            shift 2
            ;;
        --no-secrets)
            IMPORT_SECRETS=false
            shift
            ;;
        --no-clone)
            IMPORT_NO_CLONE=true
            shift
            ;;
        --backup)
            BACKUP_MODE=true
            BACKUP_DIR="$SCRIPT_DIR/backups"
            shift
            ;;
        --restore)
            if [ $# -lt 2 ] || [[ "$2" == -* ]]; then
                echo -e "${RED}Error: --restore requires a directory argument${NC}"
                echo "Example: $0 --restore ./backups/2026-02-25_125435"
                exit 1
            fi
            RESTORE_MODE=true
            RESTORE_DIR="$2"
            shift 2
            ;;
        --backup-dir)
            BACKUP_DIR="$2"
            shift 2
            ;;
        --setup)
            SETUP_MODE=true
            shift
            ;;
        --email)
            SETUP_EMAIL="$2"
            shift 2
            ;;
        --sync)
            SYNC_MODE=true
            shift
            ;;
        --sync-dir)
            if [ $# -lt 2 ] || [[ "$2" == -* ]]; then
                echo -e "${RED}Error: --sync-dir requires a directory argument${NC}"
                exit 1
            fi
            SYNC_DIR="$2"
            shift 2
            ;;
        --refresh-sync)
            SYNC_REFRESH=true
            shift
            ;;
        --reset-sync)
            SYNC_RESET=true
            shift
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
        -*)
            echo -e "${RED}Unknown option: $1${NC}"
            show_help
            exit 1
            ;;
        *)
            SELECTED_DEPLOYMENTS+=("$1")
            shift
            ;;
    esac
done

if [ "$SYNC_MODE" = true ] && { [ "$IMPORT_MODE" = true ] || [ "$SETUP_MODE" = true ] || [ "$BACKUP_MODE" = true ] || [ "$RESTORE_MODE" = true ] || [ "$CONFIG_ONLY" = true ]; }; then
    echo -e "${RED}Error: --sync cannot be combined with --import, --setup, --backup, --restore, or --config-only${NC}"
    exit 1
fi

if [ "$SYNC_MODE" = false ] && { [ -n "$SYNC_DIR" ] || [ "$SYNC_REFRESH" = true ] || [ "$SYNC_RESET" = true ]; }; then
    echo -e "${RED}Error: --sync-dir, --refresh-sync, and --reset-sync require --sync${NC}"
    exit 1
fi

# Load modular function groups
for module in \
    "$SCRIPT_HOME/lib/import_setup.sh" \
    "$SCRIPT_HOME/lib/backup_restore.sh" \
    "$SCRIPT_HOME/lib/helpers.sh" \
    "$SCRIPT_HOME/lib/sync.sh" \
    "$SCRIPT_HOME/lib/deploy_ops.sh"; do
    if [ ! -f "$module" ]; then
        echo -e "${RED}Error: required module not found: $module${NC}"
        exit 1
    fi
    # shellcheck source=/dev/null
    . "$module"
done

# ═══════════════════════════════════════════════════════════════════════════════
# Import Mode - Import all apps from existing Dokku server
# ═══════════════════════════════════════════════════════════════════════════════


# Handle import mode
if [ "$IMPORT_MODE" = true ]; then
    if [ -z "$IMPORT_DIR" ]; then
        echo -e "${RED}Error: --import requires a target directory${NC}"
        show_help
        exit 1
    fi
    if [ -z "$IMPORT_SSH" ]; then
        echo -e "${RED}Error: --import requires --ssh <alias>${NC}"
        show_help
        exit 1
    fi
    import_from_server "$IMPORT_DIR" "$IMPORT_SSH" "$IMPORT_SECRETS"
    exit 0
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Setup Mode - Setup a fresh Dokku server with required plugins
# ═══════════════════════════════════════════════════════════════════════════════


# Handle setup mode
if [ "$SETUP_MODE" = true ]; then
    # Get SSH alias from config or --ssh flag
    if [ -n "$IMPORT_SSH" ]; then
        SETUP_SSH="$IMPORT_SSH"
    elif [ -f "$CONFIG_FILE" ]; then
        SETUP_SSH=$(jq -r '.ssh_alias // .ssh_host' "$CONFIG_FILE" 2>/dev/null | sed 's/dokku@//')
    else
        echo -e "${RED}Error: No SSH target specified${NC}"
        echo "Use --ssh <alias> or ensure config.json exists with ssh_alias"
        exit 1
    fi
    setup_server "$SETUP_SSH" "$SETUP_EMAIL"
    exit 0
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Backup Mode - Backup PostgreSQL/MySQL databases and storage mounts
# ═══════════════════════════════════════════════════════════════════════════════


# Check if config file exists (only for non-import mode)
if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}Error: $CONFIG_FILE not found${NC}"
    echo "Copy config.example.json to config.json and configure your deployments."
    echo "Or use --import to import from an existing Dokku server."
    exit 1
fi

# Get SSH host and alias from config (export for hooks)
export SSH_HOST=$(jq -r '.ssh_host' "$CONFIG_FILE")
export SSH_ALIAS=$(jq -r '.ssh_alias // .ssh_host' "$CONFIG_FILE")

echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
echo -e "${BLUE}   dokku-multideploy${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
echo ""

# Check SSH connectivity
echo -e "${BLUE}Checking Dokku connectivity...${NC}"
if ! ssh -o ConnectTimeout=10 $SSH_ALIAS "echo 'Connection OK'" &>/dev/null; then
    echo -e "${RED}Cannot connect to Dokku at $SSH_ALIAS${NC}"
    echo -e "${RED}Please check your SSH configuration and network connection${NC}"
    exit 1
fi
echo -e "${GREEN}Connected to Dokku${NC}"
echo ""

if [ "$DRY_RUN" = true ]; then
    echo -e "${YELLOW}DRY RUN MODE - No actual deployments will occur${NC}"
    echo ""
fi

if [ "$FORCE_DEPLOY" = true ]; then
    echo -e "${YELLOW}FORCE MODE - Will deploy even if commits match${NC}"
    echo ""
fi

if [ "$CONFIG_ONLY" = true ]; then
    echo -e "${YELLOW}CONFIG ONLY MODE - Will update env vars and restart (no code deploy)${NC}"
    echo ""
fi

# Parse hierarchical config and flatten to deployments array
DEPLOYMENTS=()

# Process each parent type (only keys whose values are objects with deployments)
for parent_type in $(jq -r 'to_entries[] | select(.value | type == "object" and has("deployments")) | .key' "$CONFIG_FILE"); do
    # Get parent config
    parent_config=$(jq -c ".[\"${parent_type}\"]" "$CONFIG_FILE")
    parent_source_dir=$(echo "$parent_config" | jq -r '.source_dir // ""')
    parent_branch=$(echo "$parent_config" | jq -r '.branch // ""')
    parent_env_vars=$(echo "$parent_config" | jq -c '.env_vars // {}')
    parent_build_args=$(echo "$parent_config" | jq -c '.build_args // {}')
    parent_storage_mounts=$(echo "$parent_config" | jq -c '.storage_mounts // []')
    parent_ports=$(echo "$parent_config" | jq -c '.ports // []')
    parent_docker_options=$(echo "$parent_config" | jq -c '.docker_options // []')
    parent_extra_domains=$(echo "$parent_config" | jq -c '.extra_domains // []')
    parent_plugins=$(echo "$parent_config" | jq -c '.plugins // []')
    parent_postgres=$(echo "$parent_config" | jq -r '.postgres // false')
    parent_letsencrypt=$(echo "$parent_config" | jq -r '.letsencrypt // false')

    # Process each deployment under this parent
    for domain in $(echo "$parent_config" | jq -r '.deployments | keys[]'); do
        child_config=$(echo "$parent_config" | jq -c ".deployments[\"$domain\"]")

        # Merge parent and child configs (child overrides parent)
        merged=$(jq -n \
            --arg domain "$domain" \
            --arg source_dir "$parent_source_dir" \
            --arg branch "$parent_branch" \
            --arg postgres "$parent_postgres" \
            --arg letsencrypt "$parent_letsencrypt" \
            --argjson parent_env_vars "$parent_env_vars" \
            --argjson parent_build_args "$parent_build_args" \
            --argjson parent_storage_mounts "$parent_storage_mounts" \
            --argjson parent_ports "$parent_ports" \
            --argjson parent_docker_options "$parent_docker_options" \
            --argjson parent_extra_domains "$parent_extra_domains" \
            --argjson parent_plugins "$parent_plugins" \
            --argjson child "$child_config" \
            '{
                domain: $domain,
                source_dir: (if ($child.source_dir // $source_dir) == "" then "." else ($child.source_dir // $source_dir) end),
                branch: (if ($child.branch // $branch) == "" then null else ($child.branch // $branch) end),
                tags: ($child.tags // []),
                postgres: (($child.postgres // $postgres) == "true" or ($child.postgres // $postgres) == true),
                letsencrypt: (($child.letsencrypt // $letsencrypt) == "true" or ($child.letsencrypt // $letsencrypt) == true),
                env_vars: ($parent_env_vars + ($child.env_vars // {})),
                build_args: ($parent_build_args + ($child.build_args // {})),
                storage_mounts: (($child.storage_mounts // []) + $parent_storage_mounts),
                ports: (($child.ports // $parent_ports) // []),
                docker_options: (($child.docker_options // []) + $parent_docker_options),
                extra_domains: (($child.extra_domains // []) + $parent_extra_domains),
                plugins: (($child.plugins // []) + $parent_plugins)
            }')

        DEPLOYMENTS+=("$merged")
    done
done

# Filter deployments
FILTERED_DEPLOYMENTS=()
for deployment in "${DEPLOYMENTS[@]}"; do
    domain=$(echo "$deployment" | jq -r '.domain')
    tags=$(echo "$deployment" | jq -r '.tags[]' 2>/dev/null || true)

    # Skip if specific deployments selected and this isn't one of them
    if [ ${#SELECTED_DEPLOYMENTS[@]} -gt 0 ]; then
        skip=true
        for selected in "${SELECTED_DEPLOYMENTS[@]}"; do
            if [ "$domain" = "$selected" ]; then
                skip=false
                break
            fi
        done
        if [ "$skip" = true ]; then
            continue
        fi
    fi

    # Skip production if --no-prod
    if [ "$NO_PROD" = true ] && echo "$tags" | grep -q "production"; then
        echo -e "${YELLOW}Skipping production: $domain${NC}"
        continue
    fi

    # Apply tag filters
    if [ ${#FILTER_TAGS[@]} -gt 0 ]; then
        has_tag=false
        for filter_tag in "${FILTER_TAGS[@]}"; do
            if echo "$tags" | grep -q "$filter_tag"; then
                has_tag=true
                break
            fi
        done
        if [ "$has_tag" = false ]; then
            continue
        fi
    fi

    FILTERED_DEPLOYMENTS+=("$deployment")
done

if [ ${#FILTERED_DEPLOYMENTS[@]} -eq 0 ]; then
    echo -e "${YELLOW}No deployments match the specified filters${NC}"
    exit 0
fi

echo -e "${GREEN}Deployments to process: ${#FILTERED_DEPLOYMENTS[@]}${NC}"
HAS_PRODUCTION=false
for deployment in "${FILTERED_DEPLOYMENTS[@]}"; do
    domain=$(echo "$deployment" | jq -r '.domain')
    source_dir=$(echo "$deployment" | jq -r '.source_dir')
    tags=$(echo "$deployment" | jq -r '.tags | join(", ")' 2>/dev/null || echo "")
    if [ -n "$tags" ]; then
        echo -e "  ${BLUE}•${NC} $domain ${BLUE}($source_dir)${NC} [$tags]"
    else
        echo -e "  ${BLUE}•${NC} $domain ${BLUE}($source_dir)${NC}"
    fi

    # Check if this is production
    if echo "$deployment" | jq -r '.tags[]' 2>/dev/null | grep -q "production"; then
        HAS_PRODUCTION=true
    fi
done
echo ""

# Handle backup mode
if [ "$BACKUP_MODE" = true ]; then
    # Check xz is available
    if [ "$XZ_AVAILABLE" = false ]; then
        echo -e "${RED}Error: xz is required for backup mode but not installed.${NC}"
        echo "Install with: brew install xz (macOS) or apt install xz-utils (Linux)"
        exit 1
    fi

    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}   dokku-multideploy - Backup Mode${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
    echo ""

    # Create backup directory with timestamp subfolder
    BACKUP_TIMESTAMP=$(date +%Y-%m-%d_%H%M%S)
    BACKUP_DIR="$BACKUP_DIR/$BACKUP_TIMESTAMP"
    mkdir -p "$BACKUP_DIR"
    echo -e "${BLUE}Backup directory: $BACKUP_DIR${NC}"
    echo ""

    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}DRY RUN MODE - No actual backups will be created${NC}"
        echo ""
    fi

    # Backup MySQL services globally (not necessarily app-name derived)
    backup_mysql_services "$BACKUP_DIR"

    # Backup each app
    for deployment in "${FILTERED_DEPLOYMENTS[@]}"; do
        backup_app "$deployment" "$BACKUP_DIR"
    done

    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}Backup complete!${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "Files saved to: ${BLUE}$BACKUP_DIR${NC}"
    if [ "$DRY_RUN" = false ]; then
        ls -lh "$BACKUP_DIR"/*.xz 2>/dev/null || echo "  (no backups created)"
        echo ""
        total_size=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)
        if [ -n "$total_size" ]; then
            echo -e "Total backup size: ${GREEN}$total_size${NC} (xz -9 compressed)"
        fi
    fi
    echo ""
    exit 0
fi

# Handle restore mode
if [ "$RESTORE_MODE" = true ]; then
    if [ "$XZ_AVAILABLE" = false ]; then
        echo -e "${RED}Error: xz is required for restore mode but not installed.${NC}"
        echo "Install with: brew install xz (macOS) or apt install xz-utils (Linux)"
        exit 1
    fi

    if [ -z "$RESTORE_DIR" ] || [ ! -d "$RESTORE_DIR" ]; then
        echo -e "${RED}Error: --restore requires an existing backup directory${NC}"
        echo "Example: $0 --restore ./backups/2026-02-25_125435"
        exit 1
    fi

    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}   dokku-multideploy - Restore Mode${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${BLUE}Restore directory: $RESTORE_DIR${NC}"
    echo ""

    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}DRY RUN MODE - No actual restores will occur${NC}"
        echo ""
    fi

    if [ "$DRY_RUN" = false ] && [ "$YES_TO_ALL" = false ]; then
        echo -e "${RED}WARNING: Restore may overwrite current database/storage state on target host.${NC}"
        read -p "Continue restore? (yes/no): " confirm_restore
        if [ "$confirm_restore" != "yes" ]; then
            echo -e "${YELLOW}Restore cancelled.${NC}"
            exit 0
        fi
        echo ""
    fi

    restore_failed=false
    restore_mysql_services "$RESTORE_DIR" || restore_failed=true

    for deployment in "${FILTERED_DEPLOYMENTS[@]}"; do
        restore_app "$deployment" "$RESTORE_DIR" || restore_failed=true
    done

    if [ "$restore_failed" = true ]; then
        echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${RED}Restore finished with errors.${NC}"
        echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        exit 1
    fi

    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}Restore complete!${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    exit 0
fi

# Confirmation prompt for production deployments
if [ "$HAS_PRODUCTION" = true ] && [ "$DRY_RUN" = false ] && [ "$YES_TO_ALL" = false ] && [ "$SYNC_MODE" = false ]; then
    echo -e "${RED}WARNING: This will deploy to PRODUCTION environments!${NC}"
    read -p "Are you sure you want to continue? (yes/no): " confirm
    if [ "$confirm" != "yes" ]; then
        echo -e "${YELLOW}Deployment cancelled.${NC}"
        exit 0
    fi
    echo ""
fi

# Handle sync mode (after function definitions)
if [ "$SYNC_MODE" = true ]; then
    if run_sync_check; then
        exit 0
    else
        exit 1
    fi
fi

# Deploy or update config for each app
for deployment in "${FILTERED_DEPLOYMENTS[@]}"; do
    if [ "$CONFIG_ONLY" = true ]; then
        apply_config_only "$deployment"
    else
        deploy_app "$deployment"
    fi
done

echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}All deployments complete!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
