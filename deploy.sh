#!/usr/bin/env bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script directory - use $0 to get symlink location, not resolved target
# This allows symlinking dispatch.sh to a project and having config.json there
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$SCRIPT_DIR/config.json}"

# Check for jq
if ! command -v jq &> /dev/null; then
    echo -e "${RED}Error: jq is required but not installed.${NC}"
    echo "Install with: brew install jq (macOS) or apt install jq (Linux)"
    exit 1
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

# ═══════════════════════════════════════════════════════════════════════════════
# Import Mode - Import all apps from existing Dokku server
# ═══════════════════════════════════════════════════════════════════════════════

import_from_server() {
    local import_dir="$1"
    local ssh_alias="$2"
    local import_secrets="$3"

    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}   dokku-multideploy - Import Mode${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
    echo ""

    # Check connectivity
    echo -e "${BLUE}Checking Dokku connectivity...${NC}"
    if ! ssh -o ConnectTimeout=10 "$ssh_alias" "echo 'Connection OK'" &>/dev/null; then
        echo -e "${RED}Cannot connect to Dokku at $ssh_alias${NC}"
        exit 1
    fi
    echo -e "${GREEN}Connected to Dokku${NC}"
    echo ""

    # Get SSH host for git clone (dokku@host format)
    local ssh_host
    ssh_host=$(ssh "$ssh_alias" "echo \$SSH_CONNECTION" | awk '{print $3}')
    if [ -z "$ssh_host" ]; then
        # Fallback: try to get from ssh config
        ssh_host=$(ssh -G "$ssh_alias" | grep "^hostname " | awk '{print $2}')
    fi
    echo -e "${BLUE}Dokku host: $ssh_host${NC}"

    # Create import directory
    mkdir -p "$import_dir"
    mkdir -p "$SCRIPT_DIR/.env.imported"

    # Get list of apps
    echo -e "${BLUE}Fetching app list...${NC}"
    local apps
    apps=$(ssh "$ssh_alias" "dokku apps:list" | tail -n +2)
    local app_count=$(echo "$apps" | wc -l | tr -d ' ')
    echo -e "${GREEN}Found $app_count apps${NC}"
    echo ""

    # Initialize config structure
    local config_json='{"ssh_alias": "'$ssh_alias'", "ssh_host": "dokku@'$ssh_host'"}'

    # Process each app
    local count=0
    for app in $apps; do
        count=$((count + 1))
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${GREEN}[$count/$app_count] Processing: $app${NC}"
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

        local app_dir="$import_dir/$app"

        # Clone git repo
        echo -e "  ${BLUE}Cloning git repo...${NC}"
        if [ -d "$app_dir" ]; then
            echo -e "  ${YELLOW}Directory exists, pulling latest...${NC}"
            git -C "$app_dir" pull --ff-only 2>/dev/null || true
        else
            if ! git clone "dokku@$ssh_host:$app" "$app_dir" 2>/dev/null; then
                echo -e "  ${YELLOW}No git repo (app may not have been deployed yet)${NC}"
                mkdir -p "$app_dir"
            fi
        fi

        # Get primary domain
        # Prefer custom domains over auto-generated ones (domains starting with app-name)
        local domains
        domains=$(ssh "$ssh_alias" "dokku domains:report $app" 2>/dev/null | grep "Domains app vhosts:" | sed 's/.*Domains app vhosts:[[:space:]]*//')

        # Find custom domain (one that doesn't start with the app name)
        local primary_domain=""
        local extra_domains=""
        local app_prefix="${app}."

        # First pass: look for a domain that doesn't start with app name (custom domain)
        for domain in $domains; do
            if [[ "$domain" != ${app_prefix}* ]]; then
                if [ -z "$primary_domain" ]; then
                    primary_domain="$domain"
                else
                    extra_domains="$extra_domains $domain"
                fi
            fi
        done

        # Second pass: add auto-generated domains to extra_domains
        for domain in $domains; do
            if [[ "$domain" == ${app_prefix}* ]]; then
                extra_domains="$extra_domains $domain"
            fi
        done
        extra_domains=$(echo "$extra_domains" | xargs)  # trim whitespace

        # If no custom domain found, use first domain
        if [ -z "$primary_domain" ]; then
            primary_domain=$(echo "$domains" | awk '{print $1}')
            extra_domains=$(echo "$domains" | awk '{for(i=2;i<=NF;i++) print $i}' | xargs)
        fi

        if [ -z "$primary_domain" ] || [ "$primary_domain" = "$app" ]; then
            primary_domain="$app"
        fi
        echo -e "  Domain: $primary_domain"

        # Get ports
        local ports_raw
        ports_raw=$(ssh "$ssh_alias" "dokku ports:report $app" 2>/dev/null | grep "Ports map:" | sed 's/.*Ports map:[[:space:]]*//')
        local ports_json="[]"
        if [ -n "$ports_raw" ] && [ "$ports_raw" != "" ]; then
            ports_json=$(echo "$ports_raw" | tr ' ' '\n' | grep -v '^$' | while read port_map; do
                scheme=$(echo "$port_map" | cut -d: -f1)
                host_port=$(echo "$port_map" | cut -d: -f2)
                container_port=$(echo "$port_map" | cut -d: -f3)
                echo "{\"scheme\":\"$scheme\",\"host\":$host_port,\"container\":$container_port}"
            done | jq -s '.')
        fi

        # Get storage mounts
        local storage_raw
        storage_raw=$(ssh "$ssh_alias" "dokku storage:report $app" 2>/dev/null | grep "Storage bind mounts:" | sed 's/.*Storage bind mounts:[[:space:]]*//')
        local storage_json="[]"
        if [ -n "$storage_raw" ] && [ "$storage_raw" != "" ] && [ "$storage_raw" != "none" ]; then
            storage_json=$(echo "$storage_raw" | tr ' ' '\n' | grep -v '^$' | while read mount; do
                host_path=$(echo "$mount" | cut -d: -f1)
                container_path=$(echo "$mount" | cut -d: -f2)
                echo "{\"host\":\"$host_path\",\"container\":\"$container_path\"}"
            done | jq -s '.')
        fi

        # Check PostgreSQL
        local postgres="false"
        if ssh "$ssh_alias" "dokku postgres:info $app" &>/dev/null; then
            postgres="true"
            echo -e "  PostgreSQL: linked"
        fi

        # Check Let's Encrypt
        local letsencrypt="false"
        if ssh "$ssh_alias" "dokku letsencrypt:active $app" &>/dev/null 2>&1; then
            letsencrypt="true"
            echo -e "  Let's Encrypt: active"
        fi

        # Get deploy branch
        local branch
        branch=$(ssh "$ssh_alias" "dokku git:report $app" 2>/dev/null | grep "Git deploy branch:" | awk '{print $NF}')
        [ -z "$branch" ] && branch="master"

        # Export env vars
        if [ "$import_secrets" = true ]; then
            echo -e "  ${BLUE}Exporting env vars...${NC}"
            local env_vars
            env_vars=$(ssh "$ssh_alias" "dokku config:export $app" 2>/dev/null || true)
            if [ -n "$env_vars" ]; then
                echo "$env_vars" > "$SCRIPT_DIR/.env.imported/$primary_domain"
                echo -e "  ${GREEN}Saved to .env.imported/$primary_domain${NC}"
            fi
        fi

        # Build extra domains array
        local extra_domains_json="[]"
        if [ -n "$extra_domains" ]; then
            extra_domains_json=$(echo "$extra_domains" | tr ' ' '\n' | grep -v '^$' | jq -R . | jq -s '.')
        fi

        # Add to config using parent key based on app name
        # Use the app name (with dashes converted to underscores) as the parent key
        local parent_key=$(echo "$app" | tr '-' '_')

        # Build deployment config
        local deployment_config=$(jq -n \
            --arg domain "$primary_domain" \
            --arg source_dir "$app" \
            --arg branch "$branch" \
            --arg postgres "$postgres" \
            --arg letsencrypt "$letsencrypt" \
            --argjson ports "$ports_json" \
            --argjson storage "$storage_json" \
            --argjson extra_domains "$extra_domains_json" \
            '{
                source_dir: $source_dir,
                branch: $branch,
                postgres: ($postgres == "true"),
                letsencrypt: ($letsencrypt == "true"),
                ports: (if $ports == [] then null else $ports end),
                storage_mounts: (if $storage == [] then null else $storage end),
                extra_domains: (if $extra_domains == [] then null else $extra_domains end),
                deployments: {
                    ($domain): {
                        tags: ["imported"]
                    }
                }
            } | with_entries(select(.value != null))')

        # Add to main config
        config_json=$(echo "$config_json" | jq --arg key "$parent_key" --argjson config "$deployment_config" '.[$key] = $config')

        echo ""
    done

    # Write config.imported.json (don't overwrite existing config.json)
    local config_path="$SCRIPT_DIR/config.imported.json"
    echo "$config_json" | jq '.' > "$config_path"

    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}Import complete!${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  Apps cloned to:   ${BLUE}$import_dir/${NC}"
    echo -e "  Config saved to:  ${BLUE}$config_path${NC}"
    if [ "$import_secrets" = true ]; then
        echo -e "  Secrets saved to: ${BLUE}$SCRIPT_DIR/.env.imported/${NC}"
    fi
    echo ""

    # Show diff if existing config.json exists
    if [ -f "$SCRIPT_DIR/config.json" ]; then
        echo -e "${YELLOW}Existing config.json found. To compare:${NC}"
        echo "  diff config.json config.imported.json"
        echo ""
        echo -e "${YELLOW}To use imported config:${NC}"
        echo "  mv config.imported.json config.json"
    else
        echo -e "${YELLOW}To activate:${NC}"
        echo "  mv config.imported.json config.json"
    fi
    echo ""
}

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

# Check if config file exists (only for non-import mode)
if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}Error: $CONFIG_FILE not found${NC}"
    echo "Copy config.example.json to config.json and configure your deployments."
    echo "Or use --import to import from an existing Dokku server."
    exit 1
fi

# Get SSH host and alias from config
SSH_HOST=$(jq -r '.ssh_host' "$CONFIG_FILE")
SSH_ALIAS=$(jq -r '.ssh_alias // .ssh_host' "$CONFIG_FILE")

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

# Process each parent type
for parent_type in $(jq -r 'keys[] | select(. != "ssh_host" and . != "ssh_alias")' "$CONFIG_FILE"); do
    # Get parent config
    parent_config=$(jq -c ".[\"${parent_type}\"]" "$CONFIG_FILE")
    parent_source_dir=$(echo "$parent_config" | jq -r '.source_dir // ""')
    parent_branch=$(echo "$parent_config" | jq -r '.branch // ""')
    parent_env_vars=$(echo "$parent_config" | jq -c '.env_vars // {}')
    parent_build_args=$(echo "$parent_config" | jq -c '.build_args // {}')
    parent_storage_mounts=$(echo "$parent_config" | jq -c '.storage_mounts // []')
    parent_ports=$(echo "$parent_config" | jq -c '.ports // []')
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

# Confirmation prompt for production deployments
if [ "$HAS_PRODUCTION" = true ] && [ "$DRY_RUN" = false ] && [ "$YES_TO_ALL" = false ]; then
    echo -e "${RED}WARNING: This will deploy to PRODUCTION environments!${NC}"
    read -p "Are you sure you want to continue? (yes/no): " confirm
    if [ "$confirm" != "yes" ]; then
        echo -e "${YELLOW}Deployment cancelled.${NC}"
        exit 0
    fi
    echo ""
fi

# Function to parse env file and return properly escaped key=value pairs
parse_env_file() {
    local file=$1
    local result=""

    if [ ! -f "$file" ]; then
        echo ""
        return
    fi

    while IFS= read -r line || [ -n "$line" ]; do
        # Skip empty lines and comments
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

        # Parse key=value (handle quotes and special chars)
        if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            local key="${BASH_REMATCH[1]}"
            local value="${BASH_REMATCH[2]}"

            # Remove surrounding quotes if present
            if [[ "$value" =~ ^\"(.*)\"$ ]] || [[ "$value" =~ ^\'(.*)\'$ ]]; then
                value="${BASH_REMATCH[1]}"
            fi

            # Properly escape the value for shell
            local escaped_value=$(printf '%q' "$value")
            result="$result ${key}=${escaped_value}"
        fi
    done < "$file"

    echo "$result"
}

# Function to apply config only (env vars + restart)
apply_config_only() {
    local deployment=$1
    local domain=$(echo "$deployment" | jq -r '.domain')
    local source_dir=$(echo "$deployment" | jq -r '.source_dir')
    local app_name=$(echo "$domain" | tr '.' '-')

    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}Updating config: $domain${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "   App name: $app_name"
    echo ""

    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}   [DRY RUN] Would update config for this app${NC}"
        echo ""
        return
    fi

    # Check if app exists
    if ! ssh $SSH_ALIAS "dokku apps:exists $app_name" 2>/dev/null; then
        echo -e "${RED}App $app_name does not exist on Dokku${NC}"
        echo -e "${RED}Run a full deploy first to create the app${NC}"
        return 1
    fi

    # Load secrets from .env files
    local shared_file="$SCRIPT_DIR/.env/_$source_dir"
    local domain_file="$SCRIPT_DIR/.env/$domain"
    local secrets=""

    if [ -f "$shared_file" ]; then
        echo -e "${BLUE}Loading shared secrets from .env/_$source_dir${NC}"
        secrets="$(parse_env_file "$shared_file")"
    fi

    if [ -f "$domain_file" ]; then
        echo -e "${BLUE}Loading secrets from .env/$domain${NC}"
        secrets="$secrets $(parse_env_file "$domain_file")"
    fi

    if [ -n "$secrets" ]; then
        ssh $SSH_ALIAS "dokku config:set --no-restart $app_name $secrets" || true
    fi

    # Set environment variables from config.json (properly escaped)
    if echo "$deployment" | jq -e '.env_vars' > /dev/null 2>&1; then
        local env_count=$(echo "$deployment" | jq '.env_vars | length')
        if [ "$env_count" -gt 0 ]; then
            echo -e "${BLUE}Setting environment variables from config.json...${NC}"
            # Build properly escaped env vars string
            local escaped_vars=""
            while IFS= read -r line; do
                [[ -z "$line" ]] && continue
                local key=$(echo "$line" | jq -r '.key')
                local value=$(echo "$line" | jq -r '.value')
                local escaped_value=$(printf '%q' "$value")
                escaped_vars="$escaped_vars ${key}=${escaped_value}"
            done < <(echo "$deployment" | jq -c '.env_vars | to_entries[]')
            ssh $SSH_ALIAS "dokku config:set --no-restart $app_name $escaped_vars" || true
        fi
    fi

    # Restart the app to apply changes
    echo -e "${BLUE}Restarting app...${NC}"
    ssh $SSH_ALIAS "dokku ps:restart $app_name"

    echo -e "${GREEN}Config updated: $domain${NC}"
    echo ""
}

# Function to deploy a single app
deploy_app() {
    local deployment=$1
    local domain=$(echo "$deployment" | jq -r '.domain')
    local source_dir=$(echo "$deployment" | jq -r '.source_dir')
    local app_name=$(echo "$domain" | tr '.' '-')
    local dockerfile="Dockerfile"
    # Support absolute paths (starting with /) or relative paths
    local source_path
    if [[ "$source_dir" == /* ]]; then
        source_path="$source_dir"
    else
        source_path="$SCRIPT_DIR/$source_dir"
    fi
    local enable_postgres=$(echo "$deployment" | jq -r '.postgres')
    local enable_letsencrypt=$(echo "$deployment" | jq -r '.letsencrypt')

    # Export APP_NAME for use in deploy hooks
    export APP_NAME="$app_name"

    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}Deploying: $domain${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "   App name:   $app_name"
    echo -e "   Source dir: $source_dir"
    echo -e "   Dockerfile: $dockerfile"
    echo ""

    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}   [DRY RUN] Would deploy this app${NC}"
        echo ""
        return
    fi

    # Change to source directory to check git status
    cd "$source_path" || {
        echo -e "${RED}Error: Cannot access $source_path${NC}"
        return 1
    }

    # Determine which branch to use for deployment
    echo -e "${BLUE}Syncing with origin...${NC}"

    # Get current local branch
    local current_branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo "")

    git fetch origin 2>/dev/null || {
        echo -e "${YELLOW}Warning: Could not fetch from origin${NC}"
    }

    # Try to get configured branch, or auto-detect
    local repo_branch=$(echo "$deployment" | jq -r '.branch // empty')
    if [ -z "$repo_branch" ] || [ "$repo_branch" = "null" ]; then
        # Use current branch if it exists and looks reasonable
        if [ -n "$current_branch" ] && [[ "$current_branch" =~ ^(main|master|dev|develop)$ ]]; then
            repo_branch="$current_branch"
        else
            # Auto-detect from origin
            repo_branch=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
            if [ -z "$repo_branch" ]; then
                # Fallback: check what exists on origin
                if git rev-parse --verify origin/main >/dev/null 2>&1; then
                    repo_branch="main"
                elif git rev-parse --verify origin/master >/dev/null 2>&1; then
                    repo_branch="master"
                elif [ -n "$current_branch" ]; then
                    # Last resort: use current branch
                    repo_branch="$current_branch"
                else
                    echo -e "${RED}Error: Cannot determine default branch${NC}"
                    cd "$SCRIPT_DIR"
                    return 1
                fi
            fi
        fi
    fi

    # Checkout branch if not already on it
    if [ "$current_branch" != "$repo_branch" ]; then
        if ! git checkout "$repo_branch" 2>/dev/null; then
            echo -e "${RED}Error: Cannot checkout branch '$repo_branch'${NC}"
            cd "$SCRIPT_DIR"
            return 1
        fi
    fi

    # Try to pull from origin if the branch exists there
    if git rev-parse --verify origin/$repo_branch >/dev/null 2>&1; then
        # Ensure branch tracks origin
        git branch --set-upstream-to=origin/$repo_branch $repo_branch 2>/dev/null || true

        # Pull latest changes
        if ! git pull origin "$repo_branch" 2>/dev/null; then
            echo -e "${YELLOW}Warning: Could not pull latest changes${NC}"
            echo -e "${YELLOW}This may fail if you have uncommitted changes${NC}"
            echo -e "${YELLOW}Continuing with local version...${NC}"
        else
            echo -e "${GREEN}Synced with origin/$repo_branch${NC}"
        fi
    else
        echo -e "${YELLOW}Branch '$repo_branch' not found on origin, using local version${NC}"
    fi
    echo ""

    # Create remote if doesn't exist (needed for fetch)
    # Use app-specific remote name to avoid conflicts when deploying multiple apps from same repo
    local remote_name="dokku-$app_name"
    if ! git remote | grep -q "^${remote_name}$"; then
        echo -e "${BLUE}Adding git remote: $remote_name${NC}"
        git remote add "$remote_name" "$SSH_HOST:$app_name"
    else
        git remote set-url "$remote_name" "$SSH_HOST:$app_name"
    fi

    # Check if deployment is needed by comparing local and remote commits
    echo -e "${BLUE}Checking if deployment is needed...${NC}"

    # Detect Dokku's deploy branch for this app (defaults to master)
    local dokku_branch=$(ssh $SSH_ALIAS "dokku git:report $app_name 2>/dev/null | grep 'Git deploy branch:' | awk '{print \$NF}'" || echo "master")
    if [ -z "$dokku_branch" ] || [ "$dokku_branch" = "deploy" ]; then
        dokku_branch="master"
    fi

    # Fetch remote state quietly
    git fetch "$remote_name" "$dokku_branch" 2>/dev/null || true

    local local_commit=$(git rev-parse "$repo_branch" 2>/dev/null)
    local remote_commit=$(git rev-parse "$remote_name/$dokku_branch" 2>/dev/null || echo "")

    if [ "$FORCE_DEPLOY" = false ] && [ -n "$remote_commit" ] && [ "$local_commit" = "$remote_commit" ]; then
        echo -e "${GREEN}Remote is already up-to-date (${local_commit:0:8}), skipping deployment${NC}"
        echo -e "${BLUE}Note: Use --force to deploy config/env changes without code changes${NC}"
        echo -e "${GREEN}No deployment needed: $domain${NC}"
        echo ""
        cd "$SCRIPT_DIR"
        return 0
    fi

    if [ -n "$remote_commit" ]; then
        echo -e "${BLUE}   Local:  ${local_commit:0:8}${NC}"
        echo -e "${BLUE}   Remote: ${remote_commit:0:8}${NC}"
    else
        echo -e "${BLUE}   Remote: (new app)${NC}"
    fi
    echo -e "${YELLOW}Changes detected, proceeding with deployment${NC}"
    echo ""

    # Return to script directory for configuration steps
    cd "$SCRIPT_DIR"

    # Create app if doesn't exist
    echo -e "${BLUE}Ensuring app exists on Dokku...${NC}"
    ssh $SSH_ALIAS "dokku apps:exists $app_name || dokku apps:create $app_name" || true

    # Install plugins if configured
    if echo "$deployment" | jq -e '.plugins' > /dev/null 2>&1; then
        local plugins=$(echo "$deployment" | jq -r '.plugins[]' 2>/dev/null)
        if [ -n "$plugins" ]; then
            echo -e "${BLUE}Installing plugins...${NC}"
            while IFS= read -r plugin; do
                echo -e "${BLUE}   Installing $plugin${NC}"
                ssh $SSH_ALIAS "dokku plugin:install $plugin || true" 2>/dev/null
            done <<< "$plugins"
        fi
    fi

    # Create and link Postgres database if enabled
    if [ "$enable_postgres" = "true" ]; then
        # Check if postgres plugin is installed
        if ! ssh $SSH_ALIAS "dokku plugin:list" 2>/dev/null | grep -q "postgres"; then
            echo -e "${YELLOW}PostgreSQL plugin not installed on Dokku${NC}"
            echo -e "${YELLOW}Install with: ssh $SSH_ALIAS sudo dokku plugin:install https://github.com/dokku/dokku-postgres.git${NC}"
            echo -e "${YELLOW}Make sure to set DATABASE_URL manually in .env/$domain${NC}"
        else
            # Check if DATABASE_URL or DB_HOST is already set (from .env files or config)
            local has_database_config=false

            # Check in shared .env file
            if [ -f "$SCRIPT_DIR/.env/_$source_dir" ] && grep -qE "^(DATABASE_URL|DB_HOST)=" "$SCRIPT_DIR/.env/_$source_dir"; then
                has_database_config=true
            fi

            # Check in domain-specific .env file
            if [ -f "$SCRIPT_DIR/.env/$domain" ] && grep -qE "^(DATABASE_URL|DB_HOST)=" "$SCRIPT_DIR/.env/$domain"; then
                has_database_config=true
            fi

            if [ "$has_database_config" = false ]; then
                local db_name="${app_name}-db"
                echo -e "${BLUE}Setting up PostgreSQL database: $db_name${NC}"

                # Create database if doesn't exist
                if ! ssh $SSH_ALIAS "dokku postgres:exists $db_name" 2>/dev/null; then
                    echo -e "${BLUE}   Creating new database...${NC}"
                    ssh $SSH_ALIAS "dokku postgres:create $db_name" || true
                else
                    echo -e "${GREEN}   Database already exists${NC}"
                fi

                # Link database to app (sets DATABASE_URL automatically)
                echo -e "${BLUE}   Linking database to app...${NC}"
                ssh $SSH_ALIAS "dokku postgres:link $db_name $app_name" || true
            else
                echo -e "${GREEN}Database configuration found (DATABASE_URL or DB_HOST), skipping automatic database setup${NC}"
            fi
        fi
    fi

    # Set domain (only if not already configured)
    echo -e "${BLUE}Setting domain: $domain${NC}"
    if ! ssh $SSH_ALIAS "dokku domains:report $app_name 2>/dev/null | grep -Fq '$domain'"; then
        echo -e "${BLUE}   Adding domain $domain...${NC}"
        ssh $SSH_ALIAS "dokku domains:add $app_name $domain" || true
    else
        echo -e "${GREEN}   Domain already configured${NC}"
    fi

    # Add extra domains if configured
    if echo "$deployment" | jq -e '.extra_domains' > /dev/null 2>&1; then
        local extra_domains=$(echo "$deployment" | jq -r '.extra_domains[]' 2>/dev/null)
        if [ -n "$extra_domains" ]; then
            echo -e "${BLUE}Adding extra domains...${NC}"
            while IFS= read -r extra_domain; do
                if [ -z "$extra_domain" ]; then
                    continue
                fi
                # Escape special regex chars and match exact domain (space-separated)
                local escaped_domain="${extra_domain//./\\.}"
                escaped_domain="${escaped_domain//\*/\\*}"
                local domain_exists=$(ssh -n $SSH_ALIAS "dokku domains:report $app_name 2>/dev/null | grep -E '(^|[[:space:]])${escaped_domain}([[:space:]]|\$)'" || true)
                if [ -z "$domain_exists" ]; then
                    echo -e "${BLUE}   Adding $extra_domain...${NC}"
                    ssh -n $SSH_ALIAS "dokku domains:add $app_name '$extra_domain'" || true
                else
                    echo -e "${GREEN}   $extra_domain already configured${NC}"
                fi
            done <<< "$extra_domains"
        fi
    fi

    # Configure SSL certificate if available locally
    local cert_dir="$SCRIPT_DIR/certs/$app_name"
    if [ -d "$cert_dir" ] && [ -f "$cert_dir/server.crt" ] && [ -f "$cert_dir/server.key" ]; then
        echo -e "${BLUE}Checking SSL certificate...${NC}"
        local ssl_enabled=$(ssh $SSH_ALIAS "dokku certs:report $app_name 2>/dev/null | grep 'Ssl enabled' | awk '{print \$NF}'" || echo "false")
        if [ "$ssl_enabled" != "true" ] || [ "$FORCE_DEPLOY" = true ]; then
            echo -e "${BLUE}   Installing SSL certificate from $cert_dir${NC}"
            tar cf - -C "$cert_dir" server.crt server.key | ssh $SSH_ALIAS "dokku certs:add $app_name"
            echo -e "${GREEN}SSL certificate installed${NC}"
        else
            echo -e "${GREEN}   SSL already enabled${NC}"
        fi
    fi

    # Configure storage mounts if specified
    if echo "$deployment" | jq -e '.storage_mounts' > /dev/null 2>&1; then
        local mounts=$(echo "$deployment" | jq -r '.storage_mounts[]' 2>/dev/null)
        if [ -n "$mounts" ]; then
            echo -e "${BLUE}Configuring storage mounts...${NC}"
            while IFS= read -r mount; do
                echo -e "${BLUE}   Mounting $mount${NC}"
                ssh $SSH_ALIAS "dokku storage:mount $app_name $mount" || true
            done <<< "$mounts"
        fi
    fi

    # Configure port mappings if specified
    if echo "$deployment" | jq -e '.ports' > /dev/null 2>&1; then
        local ports=$(echo "$deployment" | jq -r '.ports | join(" ")' 2>/dev/null)
        if [ -n "$ports" ]; then
            echo -e "${BLUE}Configuring port mappings...${NC}"
            echo -e "${BLUE}   Ports: $ports${NC}"
            ssh $SSH_ALIAS "dokku ports:set $app_name $ports" || true
        fi
    fi

    # Load secrets hierarchically: shared file first, then domain-specific
    local shared_file="$SCRIPT_DIR/.env/_$source_dir"
    local domain_file="$SCRIPT_DIR/.env/$domain"
    local secrets=""

    # Load shared secrets for this deployment type (e.g., _server or _client)
    if [ -f "$shared_file" ]; then
        echo -e "${BLUE}Loading shared secrets from .env/_$source_dir${NC}"
        secrets="$(parse_env_file "$shared_file")"
    fi

    # Load domain-specific secrets (overrides shared)
    if [ -f "$domain_file" ]; then
        echo -e "${BLUE}Loading environment secrets from .env/$domain${NC}"
        secrets="$secrets $(parse_env_file "$domain_file")"
    fi

    # Apply all secrets
    if [ -n "$secrets" ]; then
        ssh $SSH_ALIAS "dokku config:set --no-restart $app_name $secrets" || true
    else
        echo -e "${YELLOW}No secrets found${NC}"
        echo -e "${YELLOW}Create .env/_$source_dir and/or .env/$domain${NC}"
    fi

    # Set environment variables (runtime) - properly escaped
    if echo "$deployment" | jq -e '.env_vars' > /dev/null 2>&1; then
        local env_count=$(echo "$deployment" | jq '.env_vars | length')
        if [ "$env_count" -gt 0 ]; then
            echo -e "${BLUE}Setting environment variables...${NC}"
            # Build properly escaped env vars string
            local escaped_vars=""
            while IFS= read -r line; do
                [[ -z "$line" ]] && continue
                local key=$(echo "$line" | jq -r '.key')
                local value=$(echo "$line" | jq -r '.value')
                local escaped_value=$(printf '%q' "$value")
                escaped_vars="$escaped_vars ${key}=${escaped_value}"
            done < <(echo "$deployment" | jq -c '.env_vars | to_entries[]')
            ssh $SSH_ALIAS "dokku config:set --no-restart $app_name $escaped_vars" || true
        fi
    fi

    # Set build args (build-time) - handled via docker-options
    if echo "$deployment" | jq -e '.build_args' > /dev/null 2>&1; then
        echo -e "${BLUE}Setting build arguments...${NC}"

        # Clear existing build args first
        ssh $SSH_ALIAS "dokku docker-options:clear $app_name build" || true

        # Add build args from config.json
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            # Each line is already "key=value" format from jq
            ssh $SSH_ALIAS "dokku docker-options:add $app_name build --build-arg $(printf '%q' "$line")" || true
        done < <(echo "$deployment" | jq -r '.build_args | to_entries[] | "\(.key)=\(.value)"')

        # Also load secrets from .env files as build args (shared first, then domain-specific)
        for file in "$shared_file" "$domain_file"; do
            if [ -f "$file" ]; then
                # Parse the file and add each build arg individually
                while IFS= read -r line || [ -n "$line" ]; do
                    # Skip empty lines and comments
                    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

                    # Parse key=value
                    if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
                        local key="${BASH_REMATCH[1]}"
                        local value="${BASH_REMATCH[2]}"

                        # Remove surrounding quotes if present
                        if [[ "$value" =~ ^\"(.*)\"$ ]] || [[ "$value" =~ ^\'(.*)\'$ ]]; then
                            value="${BASH_REMATCH[1]}"
                        fi

                        # Add this build arg individually - properly quoted
                        ssh $SSH_ALIAS "dokku docker-options:add $app_name build --build-arg $(printf '%q' "${key}=${value}")" || true
                    fi
                done < "$file"
            fi
        done
    fi

    # Change to source directory for git push
    cd "$source_path" || {
        echo -e "${RED}Error: Cannot access $source_path${NC}"
        return 1
    }

    # Run pre-deploy hook if it exists
    if [ -f "./pre-deploy.sh" ]; then
        echo -e "${BLUE}Running pre-deploy hook...${NC}"
        chmod +x ./pre-deploy.sh
        if ./pre-deploy.sh; then
            echo -e "${GREEN}Pre-deploy hook completed${NC}"
        else
            echo -e "${YELLOW}Pre-deploy hook exited with error (continuing anyway)${NC}"
        fi
        echo ""
    fi

    echo -e "${BLUE}Deploying branch: $repo_branch${NC}"

    # Deploy
    echo -e "${GREEN}Pushing to Dokku...${NC}"
    echo ""

    # Try to push without force first
    if git push "$remote_name" "$repo_branch:refs/heads/$dokku_branch"; then
        echo ""
        echo -e "${GREEN}Pushed successfully${NC}"
    else
        # If that fails, it's likely a new app or history diverged
        echo ""
        echo -e "${YELLOW}Normal push failed, attempting force push...${NC}"
        git push "$remote_name" "$repo_branch:refs/heads/$dokku_branch" -f
    fi

    # Run post-deploy hook if it exists
    if [ -f "./post-deploy.sh" ]; then
        echo ""
        echo -e "${BLUE}Running post-deploy hook...${NC}"
        chmod +x ./post-deploy.sh
        if ./post-deploy.sh; then
            echo -e "${GREEN}Post-deploy hook completed${NC}"
        else
            echo -e "${YELLOW}Post-deploy hook exited with error${NC}"
        fi
    fi

    # Health check
    echo -e "${BLUE}Running health check...${NC}"
    local max_attempts=12
    local attempt=0
    local health_check_passed=false

    while [ $attempt -lt $max_attempts ]; do
        attempt=$((attempt + 1))

        # Try HTTPS first (preferred), then fall back to HTTP
        local https_code=$(curl -s -o /dev/null -w "%{http_code}" "https://$domain" --max-time 5 2>/dev/null || echo "000")
        if [ -n "$https_code" ] && [ "$https_code" -ge 200 ] && [ "$https_code" -lt 400 ]; then
            health_check_passed=true
            echo -e "${GREEN}Health check passed via HTTPS (status: $https_code, attempt $attempt/$max_attempts)${NC}"
            break
        fi

        local http_code=$(curl -s -o /dev/null -w "%{http_code}" "http://$domain" --max-time 5 2>/dev/null || echo "000")
        if [ -n "$http_code" ] && [ "$http_code" -ge 200 ] && [ "$http_code" -lt 400 ]; then
            health_check_passed=true
            echo -e "${GREEN}Health check passed via HTTP (status: $http_code, attempt $attempt/$max_attempts)${NC}"
            break
        fi

        if [ $attempt -lt $max_attempts ]; then
            echo -e "${YELLOW}Waiting for app to be ready (attempt $attempt/$max_attempts)...${NC}"
            sleep 5
        fi
    done

    if [ "$health_check_passed" = false ]; then
        echo -e "${YELLOW}Health check did not pass within expected time${NC}"
        echo -e "${YELLOW}The deployment may still be building or starting up${NC}"
        echo -e "${YELLOW}Check logs with: ssh $SSH_ALIAS dokku logs $app_name -t${NC}"
    fi

    # Enable Let's Encrypt SSL if configured and not already enabled
    if [ "$enable_letsencrypt" = "true" ]; then
        echo -e "${BLUE}Checking SSL configuration...${NC}"

        # Check if letsencrypt plugin is installed
        if ! ssh $SSH_ALIAS "dokku plugin:list" 2>/dev/null | grep -q "letsencrypt"; then
            echo -e "${YELLOW}Let's Encrypt plugin not installed on Dokku${NC}"
            echo -e "${YELLOW}Install with: ssh $SSH_ALIAS sudo dokku plugin:install https://github.com/dokku/dokku-letsencrypt.git${NC}"
            echo -e "${YELLOW}Then configure: ssh $SSH_ALIAS dokku letsencrypt:set --global email your-email@example.com${NC}"
        elif ssh $SSH_ALIAS "dokku letsencrypt:list" 2>/dev/null | grep -q "$app_name"; then
            echo -e "${GREEN}SSL already configured${NC}"
        else
            echo -e "${BLUE}Enabling Let's Encrypt SSL certificate...${NC}"
            local ssl_output
            ssl_output=$(ssh $SSH_ALIAS "dokku letsencrypt:enable $app_name" 2>&1)
            local ssl_exit_code=$?

            if [ $ssl_exit_code -eq 0 ]; then
                echo -e "${GREEN}SSL certificate provisioned successfully${NC}"

                # Enable auto-renewal if not already enabled
                if ! ssh $SSH_ALIAS "dokku letsencrypt:cron-job --list" 2>/dev/null | grep -q "letsencrypt"; then
                    echo -e "${BLUE}Enabling auto-renewal for all SSL certificates...${NC}"
                    if ssh $SSH_ALIAS "dokku letsencrypt:cron-job --add" 2>&1; then
                        echo -e "${GREEN}Auto-renewal enabled (certificates will renew automatically)${NC}"
                    fi
                fi
            else
                echo -e "${YELLOW}SSL setup failed${NC}"

                # Check for specific error messages and provide helpful hints
                if echo "$ssl_output" | grep -q "e-mail"; then
                    echo -e "${YELLOW}   Missing email configuration. Set it with:${NC}"
                    echo -e "${YELLOW}   ssh $SSH_ALIAS dokku letsencrypt:set --global email your-email@example.com${NC}"
                elif echo "$ssl_output" | grep -q "rate"; then
                    echo -e "${YELLOW}   Let's Encrypt rate limit reached. Try again later.${NC}"
                elif echo "$ssl_output" | grep -q "DNS\|domain"; then
                    echo -e "${YELLOW}   DNS may not be configured or propagated yet${NC}"
                fi

                echo -e "${YELLOW}   You can enable it manually later with:${NC}"
                echo -e "${YELLOW}   ssh $SSH_ALIAS dokku letsencrypt:enable $app_name${NC}"
            fi
        fi
    fi

    echo -e "${GREEN}Deployment complete: $domain${NC}"
    echo ""

    # Return to parent directory
    cd "$SCRIPT_DIR"
}

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
