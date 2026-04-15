apply_dokku_settings() {
    local app_name=$1
    local dokku_settings_json="$2"

    if ! echo "$dokku_settings_json" | jq -e 'type == "object" and length > 0' > /dev/null 2>&1; then
        return
    fi

    echo -e "${BLUE}Applying Dokku plugin settings...${NC}"

    local plugin
    while IFS= read -r plugin; do
        [ -z "$plugin" ] && continue

        if ! [[ "$plugin" =~ ^[a-z0-9-]+$ ]]; then
            echo -e "${YELLOW}   Skipping invalid plugin namespace: $plugin${NC}"
            continue
        fi

        while IFS=$'\t' read -r setting_key setting_value; do
            [ -z "$setting_key" ] && continue

            if ! [[ "$setting_key" =~ ^[a-z0-9-]+$ ]]; then
                echo -e "${YELLOW}   Skipping invalid setting key for $plugin: $setting_key${NC}"
                continue
            fi

            if [ -z "$setting_value" ] || [ "$setting_value" = "null" ]; then
                continue
            fi

            local escaped_setting_value="${setting_value//\'/\'\\\'\'}"
            echo -e "${BLUE}   dokku $plugin:set $app_name $setting_key [REDACTED]${NC}"
            ssh $SSH_ALIAS "dokku $plugin:set $app_name $setting_key '$escaped_setting_value'" >/dev/null 2>&1 || true
        done < <(echo "$dokku_settings_json" | jq -r --arg plugin "$plugin" '
            .[$plugin] // {}
            | to_entries[]
            | "\(.key)\t\(.value|tostring)"
        ')
    done < <(echo "$dokku_settings_json" | jq -r '
        to_entries[]
        | select(.value | type == "object")
        | .key
    ')
}

apply_mysql_expose_config() {
    local config_file="$1"
    local mysql_expose_json

    if [ ! -f "$config_file" ]; then
        echo -e "${RED}apply_mysql_expose_config: config file not found: $config_file${NC}"
        return 1
    fi
    if ! jq -e '.' "$config_file" > /dev/null 2>&1; then
        echo -e "${RED}apply_mysql_expose_config: config file is not valid JSON: $config_file${NC}"
        return 1
    fi

    mysql_expose_json=$(jq -c '.mysql_expose // {}' "$config_file")
    if ! echo "$mysql_expose_json" | jq -e 'type == "object" and length > 0' > /dev/null 2>&1; then
        return 0
    fi

    echo -e "${BLUE}Ensuring MySQL service exposure...${NC}"

    local had_failure=false
    local service_name
    local bind_address
    while IFS=$'\t' read -r service_name bind_address; do
        [ -z "$service_name" ] && continue

        if ! [[ "$service_name" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
            echo -e "${RED}Invalid mysql_expose service name: $service_name${NC}"
            return 1
        fi

        if ! [[ "$bind_address" =~ ^(127\.0\.0\.1|0\.0\.0\.0):[0-9]{1,5}$ ]]; then
            echo -e "${RED}Invalid mysql_expose bind address for $service_name: $bind_address${NC}"
            echo -e "${YELLOW}Expected format: 127.0.0.1:3306${NC}"
            return 1
        fi

        local bind_port="${bind_address##*:}"
        if [ "$bind_port" -lt 1 ] || [ "$bind_port" -gt 65535 ]; then
            echo -e "${RED}Invalid mysql_expose port for $service_name: $bind_port${NC}"
            return 1
        fi

        if [ "$DRY_RUN" = true ]; then
            echo -e "${YELLOW}[DRY RUN] Would run: dokku mysql:expose $service_name $bind_address${NC}"
            continue
        fi

        if ! ssh -n "$SSH_ALIAS" "dokku mysql:exists $service_name" > /dev/null 2>&1; then
            echo -e "${YELLOW}MySQL service '$service_name' not found or unreachable, skipping exposure${NC}"
            echo -e "${YELLOW}   Verify with: ssh $SSH_ALIAS dokku mysql:exists $service_name${NC}"
            continue
        fi

        local service_ports=""
        local service_ports_list=""
        if ! service_ports=$(ssh -n "$SSH_ALIAS" "dokku mysql:info $service_name 2>/dev/null | sed -n 's/^ *Exposed ports: *//p' | head -n 1"); then
            echo -e "${RED}   Failed to query exposed ports for $service_name — skipping${NC}"
            had_failure=true
            continue
        fi
        service_ports_list=$(echo "$service_ports" | tr ',' '\n' | tr -d ' ')

        # Check both "3306->host:port" (Dokku default format) and bare "host:port" (some plugin versions)
        if echo "$service_ports_list" | grep -Fxq "3306->$bind_address" || echo "$service_ports_list" | grep -Fxq "$bind_address"; then
            echo -e "${GREEN}   MySQL service already exposed: $service_name -> $bind_address${NC}"
            continue
        fi

        if [ -n "$service_ports_list" ]; then
            echo -e "${BLUE}   Reconfiguring exposure for $service_name (current: $service_ports)${NC}"
            while IFS= read -r exposed_port; do
                [ -z "$exposed_port" ] && continue
                local host_binding="$exposed_port"
                if [[ "$exposed_port" == *"->"* ]]; then
                    host_binding="${exposed_port#*->}"
                fi
                if [ -z "$host_binding" ]; then
                    echo -e "${RED}   Could not parse binding from port entry '$exposed_port' for $service_name — skipping unexpose${NC}"
                    had_failure=true
                    continue
                fi
                if ! ssh -n "$SSH_ALIAS" "dokku mysql:unexpose $service_name $host_binding" > /dev/null 2>&1; then
                    echo -e "${RED}   Failed to unexpose $service_name ($host_binding) — skipping re-expose to avoid inconsistent state${NC}"
                    echo -e "${RED}   Run manually: ssh $SSH_ALIAS dokku mysql:unexpose $service_name $host_binding${NC}"
                    had_failure=true
                    continue 2
                fi
            done <<< "$service_ports_list"
        fi

        echo -e "${BLUE}   Exposing MySQL service: $service_name -> $bind_address${NC}"
        if ssh -n "$SSH_ALIAS" "dokku mysql:expose $service_name $bind_address" > /dev/null 2>&1; then
            echo -e "${GREEN}   Exposed: $service_name -> $bind_address${NC}"
        else
            # Expose returned non-zero; re-check state in case it was applied anyway (idempotency guard).
            # If still missing, record failure but continue to remaining services.
            service_ports=$(ssh -n "$SSH_ALIAS" "dokku mysql:info $service_name 2>/dev/null | sed -n 's/^ *Exposed ports: *//p' | head -n 1" || true)
            service_ports_list=$(echo "$service_ports" | tr ',' '\n' | tr -d ' ')
            if echo "$service_ports_list" | grep -Fxq "3306->$bind_address" || echo "$service_ports_list" | grep -Fxq "$bind_address"; then
                echo -e "${GREEN}   MySQL exposure already present after command: $service_name -> $bind_address${NC}"
            else
                echo -e "${RED}   Failed to expose $service_name on $bind_address${NC}"
                echo -e "${RED}   Run manually: ssh $SSH_ALIAS dokku mysql:expose $service_name $bind_address${NC}"
                had_failure=true
            fi
        fi
    done < <(echo "$mysql_expose_json" | jq -r '
        to_entries[]
        | select(.value != null)
        | "\(.key)\t\(.value|tostring)"
    ')

    echo ""
    [ "$had_failure" = true ] && return 1
    return 0
}

apply_dokku_networks_config() {
    local config_file="$1"
    local dokku_networks_json

    if [ ! -f "$config_file" ]; then
        echo -e "${RED}apply_dokku_networks_config: config file not found: $config_file${NC}"
        return 1
    fi
    if ! jq -e '.' "$config_file" > /dev/null 2>&1; then
        echo -e "${RED}apply_dokku_networks_config: config file is not valid JSON: $config_file${NC}"
        return 1
    fi

    dokku_networks_json=$(jq -c '.dokku_networks // []' "$config_file")
    if ! echo "$dokku_networks_json" | jq -e 'type == "array" and length > 0' > /dev/null 2>&1; then
        return 0
    fi

    echo -e "${BLUE}Ensuring Dokku networks...${NC}"

    local network_name
    while IFS= read -r network_name; do
        [ -z "$network_name" ] && continue

        if ! [[ "$network_name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]; then
            echo -e "${RED}Invalid dokku network name: $network_name${NC}"
            return 1
        fi

        if [ "$DRY_RUN" = true ]; then
            echo -e "${YELLOW}[DRY RUN] Would ensure network exists: $network_name${NC}"
            continue
        fi

        if ssh -n "$SSH_ALIAS" "dokku network:exists '$network_name'" > /dev/null 2>&1; then
            echo -e "${GREEN}   Network already exists: $network_name${NC}"
            continue
        fi

        echo -e "${BLUE}   Creating network: $network_name${NC}"
        if ! ssh -n "$SSH_ALIAS" "dokku network:create '$network_name'" > /dev/null 2>&1; then
            echo -e "${RED}   Failed to create network: $network_name${NC}"
            return 1
        fi
    done < <(echo "$dokku_networks_json" | jq -r '.[]')

    return 0
}

apply_config_only() {
    local deployment=$1
    local domain=$(echo "$deployment" | jq -r '.domain')
    local source_dir=$(echo "$deployment" | jq -r '.source_dir')
    local app_name=$(echo "$domain" | tr '.' '-')
    local enable_letsencrypt=$(echo "$deployment" | jq -r '.letsencrypt // false')
    local dokku_settings=$(echo "$deployment" | jq -c '.dokku_settings // {}')

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
        echo -e "${BLUE}Applying secrets from .env files...${NC}"
        ssh $SSH_ALIAS "dokku config:set --no-restart $app_name $secrets" >/dev/null 2>&1 || true
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
                # Escape single quotes and wrap in single quotes for safe ssh passing
                local escaped_value="${value//\'/\'\\\'\'}"
                escaped_vars="$escaped_vars '${key}=${escaped_value}'"
            done < <(echo "$deployment" | jq -c '.env_vars | to_entries[]')
            ssh $SSH_ALIAS "dokku config:set --no-restart $app_name $escaped_vars" >/dev/null 2>&1 || true
        fi
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

    # Configure port mappings if specified
    if echo "$deployment" | jq -e '.ports' > /dev/null 2>&1; then
        local ports=$(echo "$deployment" | jq -r '.ports | join(" ")' 2>/dev/null)
        if [ -n "$ports" ]; then
            echo -e "${BLUE}Configuring port mappings...${NC}"
            echo -e "${BLUE}   Ports: $ports${NC}"
            ssh $SSH_ALIAS "dokku ports:set $app_name $ports" || true
        fi
    fi

    apply_dokku_settings "$app_name" "$dokku_settings"

    # Apply Let's Encrypt SSL in config-only mode when requested
    if [ "$enable_letsencrypt" = "true" ]; then
        echo -e "${BLUE}Checking SSL configuration...${NC}"

    # Let's Encrypt cannot issue certs for internal .dokku hostnames
    local default_dokku_vhost="${app_name}.dokku"
    local escaped_default_dokku_vhost="${app_name//./\.}\.dokku"
    if ssh -n $SSH_ALIAS "dokku domains:report $app_name 2>/dev/null | grep -E '(^|[[:space:]])${escaped_default_dokku_vhost}([[:space:]]|$)'" >/dev/null; then
        echo -e "${BLUE}Removing internal Dokku vhost ($default_dokku_vhost) before Let's Encrypt...${NC}"
        ssh -n $SSH_ALIAS "dokku domains:remove $app_name $default_dokku_vhost" || true
    fi

        if ! ssh $SSH_ALIAS "dokku plugin:list" 2>/dev/null | grep -q "letsencrypt"; then
            echo -e "${YELLOW}Let's Encrypt plugin not installed on Dokku${NC}"
            echo -e "${YELLOW}Install with: ssh $SSH_ALIAS sudo dokku plugin:install https://github.com/dokku/dokku-letsencrypt.git${NC}"
            echo -e "${YELLOW}Then configure: ssh $SSH_ALIAS dokku letsencrypt:set --global email your-email@example.com${NC}"
        elif ssh $SSH_ALIAS "dokku certs:report $app_name" 2>/dev/null | grep -q "Ssl enabled:.*true"; then
            echo -e "${GREEN}SSL already enabled${NC}"
        else
            echo -e "${BLUE}Enabling Let's Encrypt SSL certificate...${NC}"
            local ssl_output
            local ssl_exit_code
            set +e
            ssl_output=$(ssh $SSH_ALIAS "dokku letsencrypt:enable $app_name" 2>&1)
            ssl_exit_code=$?
            set -e

            if [ $ssl_exit_code -eq 0 ]; then
                echo -e "${GREEN}SSL certificate provisioned successfully${NC}"
            else
                echo -e "${YELLOW}SSL setup failed${NC}"
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

    # Set version metadata before restart
    local repo_branch=$(echo "$deployment" | jq -r '.branch // empty')
    if [ -n "$repo_branch" ]; then
        echo -e "${BLUE}Setting version metadata...${NC}"
        # Change to source directory to access git
        local source_path
        if [[ "$source_dir" == /* ]]; then
            source_path="$source_dir"
        else
            source_path="$SCRIPT_DIR/$source_dir"
        fi

        cd "$source_path" 2>/dev/null || {
            echo -e "${YELLOW}Warning: Cannot access source directory, skipping version metadata${NC}"
            cd "$SCRIPT_DIR"
        }

        if [ -d ".git" ]; then
            local local_commit=$(git rev-parse "$repo_branch" 2>/dev/null || git rev-parse HEAD 2>/dev/null || echo "")
            if [ -n "$local_commit" ]; then
                local app_version=$(git tag --points-at "$local_commit" 2>/dev/null | grep -E '^v[0-9]+\.' | head -1 || echo "")
                local git_ref="${repo_branch}"

                local version_vars="GIT_REF=${git_ref}"
                if [ -n "$app_version" ]; then
                    version_vars="APP_VERSION=${app_version} ${version_vars}"
                fi

                ssh -n $SSH_ALIAS "dokku config:set --no-restart $app_name $version_vars" || {
                    echo -e "${YELLOW}Warning: Could not set version metadata${NC}"
                }
            fi
        fi
        cd "$SCRIPT_DIR"
        echo ""
    fi

    # Restart the app to apply changes
    echo -e "${BLUE}Restarting app...${NC}"
    ssh $SSH_ALIAS "dokku ps:restart $app_name"

    echo -e "${GREEN}Config updated: $domain${NC}"
    echo ""
}

deploy_app() {
    local deployment=$1
    local domain=$(echo "$deployment" | jq -r '.domain')
    local source_dir=$(echo "$deployment" | jq -r '.source_dir')
    local subtree_prefix=$(echo "$deployment" | jq -r '.subtree_prefix // empty')
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
    local builder_type=$(echo "$deployment" | jq -r '.builder // empty')
    local dokku_settings=$(echo "$deployment" | jq -c '.dokku_settings // {}')
    local mysql_service_name=""
    local mysql_host=""

    # Export APP_NAME for use in deploy hooks
    export APP_NAME="$app_name"

    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}Deploying: $domain${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "   App name:   $app_name"
    echo -e "   Source dir: $source_dir"
    echo -e "   Dockerfile: $dockerfile"
    if [ -n "$subtree_prefix" ]; then
        echo -e "   Subtree:    $subtree_prefix"
    fi
    if [ -n "$builder_type" ]; then
        echo -e "   Builder:    $builder_type"
    fi
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

    local repo_root
    repo_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
    if [ -z "$repo_root" ]; then
        echo -e "${RED}Error: $source_path is not inside a git repository${NC}"
        cd "$SCRIPT_DIR"
        return 1
    fi
    local subtree_prefix_effective="$subtree_prefix"
    local repo_root_rel=""
    if [ -n "$subtree_prefix" ] && [[ "$repo_root" == "$SCRIPT_DIR"/* ]]; then
        if [ "$repo_root" = "$SCRIPT_DIR" ]; then
            repo_root_rel=""
        else
            repo_root_rel="${repo_root#$SCRIPT_DIR/}"
        fi
        if [ "$subtree_prefix" = "$repo_root_rel" ]; then
            subtree_prefix_effective=""
        elif [[ "$subtree_prefix" == "$repo_root_rel/"* ]]; then
            subtree_prefix_effective="${subtree_prefix#$repo_root_rel/}"
        fi
    fi

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
            echo -e "${YELLOW}Warning: Cannot checkout configured branch '$repo_branch'${NC}"
            local detected_branch=""
            detected_branch=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
            if [ -z "$detected_branch" ]; then
                if git rev-parse --verify origin/main >/dev/null 2>&1; then
                    detected_branch="main"
                elif git rev-parse --verify origin/master >/dev/null 2>&1; then
                    detected_branch="master"
                fi
            fi

            if [ -n "$detected_branch" ] && git checkout "$detected_branch" 2>/dev/null; then
                echo -e "${YELLOW}Using auto-detected branch '$detected_branch' instead${NC}"
                repo_branch="$detected_branch"
            else
                echo -e "${RED}Error: Cannot checkout branch '$repo_branch'${NC}"
                cd "$SCRIPT_DIR"
                return 1
            fi
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

    # Dokku deploy target is standardized to master for all apps.
    local dokku_branch="master"

    # Fetch remote state quietly
    git fetch "$remote_name" "$dokku_branch" 2>/dev/null || true

    local local_commit=""
    if [ -n "$subtree_prefix_effective" ]; then
        if [[ "$subtree_prefix_effective" == /* ]]; then
            echo -e "${RED}Error: subtree_prefix must be relative to repo root (got: $subtree_prefix_effective)${NC}"
            cd "$SCRIPT_DIR"
            return 1
        fi
        if ! git -C "$repo_root" rev-parse --verify "$repo_branch:$subtree_prefix_effective" >/dev/null 2>&1; then
            echo -e "${RED}Error: subtree_prefix '$subtree_prefix_effective' not found in branch '$repo_branch'${NC}"
            cd "$SCRIPT_DIR"
            return 1
        fi
        echo -e "${BLUE}Building subtree commit for: $subtree_prefix_effective${NC}"
        local_commit=$(git -C "$repo_root" subtree split --prefix="$subtree_prefix_effective" "$repo_branch" 2>/dev/null) || {
            echo -e "${RED}Error: failed to create subtree commit for '$subtree_prefix_effective'${NC}"
            cd "$SCRIPT_DIR"
            return 1
        }
    else
        if [ -n "$subtree_prefix" ]; then
            echo -e "${BLUE}Subtree prefix resolves to repository root; using branch commit directly${NC}"
        fi
        local_commit=$(git -C "$repo_root" rev-parse "$repo_branch" 2>/dev/null)
    fi
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
    echo -e "${BLUE}Ensuring Dokku deploy branch is master...${NC}"
    ssh $SSH_ALIAS "dokku git:set $app_name deploy-branch master" >/dev/null 2>&1 || true

    # Configure Dokku builder if explicitly set in config
    if [ -n "$builder_type" ]; then
        local current_builder
        current_builder=$(ssh $SSH_ALIAS "dokku builder:report $app_name 2>/dev/null | grep 'Builder selected:' | awk '{print \$NF}'" || echo "")
        if [ "$current_builder" != "$builder_type" ]; then
            echo -e "${BLUE}Setting builder: $builder_type${NC}"
            if ! ssh $SSH_ALIAS "dokku builder:set $app_name selected $builder_type"; then
                echo -e "${RED}Failed to set builder '$builder_type' for $app_name${NC}"
                return 1
            fi
        else
            echo -e "${GREEN}Builder already configured: $builder_type${NC}"
        fi
    fi

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
        # Check if postgres plugin is installed, auto-install if not
        if ! ssh $SSH_ALIAS "dokku plugin:list" 2>/dev/null | grep -q "postgres"; then
            echo -e "${YELLOW}PostgreSQL plugin not installed, installing...${NC}"
            if ssh $SSH_ALIAS "sudo dokku plugin:install https://github.com/dokku/dokku-postgres.git postgres"; then
                echo -e "${GREEN}PostgreSQL plugin installed${NC}"
            else
                echo -e "${RED}Failed to install PostgreSQL plugin${NC}"
                echo -e "${YELLOW}Make sure to set DATABASE_URL manually in .env/$domain${NC}"
            fi
        fi

        # Proceed if plugin is now available
        if ssh $SSH_ALIAS "dokku plugin:list" 2>/dev/null | grep -q "postgres"; then
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

    # Auto-provision MySQL when DATABASE_HOST points to dokku-mysql-<service>
    mysql_host=$(echo "$deployment" | jq -r '.env_vars.DATABASE_HOST // empty')
    if [ -z "$mysql_host" ]; then
        mysql_host=$(get_env_value "$SCRIPT_DIR/.env/$domain" "DATABASE_HOST")
    fi
    if [ -z "$mysql_host" ]; then
        mysql_host=$(get_env_value "$SCRIPT_DIR/.env/_$source_dir" "DATABASE_HOST")
    fi

    if [[ "$mysql_host" == dokku-mysql-* ]]; then
        mysql_service_name="${mysql_host#dokku-mysql-}"
        echo -e "${BLUE}Detected MySQL service from DATABASE_HOST: $mysql_service_name${NC}"

        # Ensure mysql plugin
        if ! ssh $SSH_ALIAS "dokku plugin:list" 2>/dev/null | grep -q "mysql"; then
            echo -e "${YELLOW}MySQL plugin not installed, installing...${NC}"
            if ssh $SSH_ALIAS "sudo dokku plugin:install https://github.com/dokku/dokku-mysql.git mysql"; then
                echo -e "${GREEN}MySQL plugin installed${NC}"
            else
                echo -e "${RED}Failed to install MySQL plugin${NC}"
                echo -e "${YELLOW}Proceeding without automatic MySQL setup${NC}"
                mysql_service_name=""
            fi
        fi

        # Ensure mysql service exists
        if [ -n "$mysql_service_name" ]; then
            if ! ssh $SSH_ALIAS "dokku mysql:exists $mysql_service_name" 2>/dev/null; then
                echo -e "${BLUE}Creating MySQL service: $mysql_service_name${NC}"
                ssh $SSH_ALIAS "dokku mysql:create $mysql_service_name" || true
            else
                echo -e "${GREEN}MySQL service already exists: $mysql_service_name${NC}"
            fi

            echo -e "${BLUE}Linking MySQL service to app...${NC}"
            ssh $SSH_ALIAS "dokku mysql:link $mysql_service_name $app_name" >/dev/null 2>&1 || true
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
        local mount_count=$(echo "$deployment" | jq '.storage_mounts | length')
        if [ "$mount_count" -gt 0 ]; then
            echo -e "${BLUE}Configuring storage mounts...${NC}"
            for (( i=0; i<mount_count; i++ )); do
                local mount_entry=$(echo "$deployment" | jq -c ".storage_mounts[$i]")
                local mount_path=""

                # Check if it's an object or string
                if echo "$mount_entry" | jq -e 'type == "object"' > /dev/null 2>&1; then
                    mount_path=$(echo "$mount_entry" | jq -r '.mount')
                else
                    mount_path=$(echo "$mount_entry" | jq -r '.')
                fi

                [ -z "$mount_path" ] && continue
                echo -e "${BLUE}   Mounting $mount_path${NC}"
                ssh $SSH_ALIAS "dokku storage:mount $app_name $mount_path" || true
            done
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

    # Configure docker options (e.g., -p port:port for non-HTTP ports)
    if echo "$deployment" | jq -e '.docker_options | length > 0' > /dev/null 2>&1; then
        echo -e "${BLUE}Configuring docker options...${NC}"
        while IFS= read -r opt; do
            [ -z "$opt" ] && continue
            echo -e "${BLUE}   Adding: $opt${NC}"
            ssh $SSH_ALIAS "dokku docker-options:add $app_name deploy '$opt'" || true
        done < <(echo "$deployment" | jq -r '.docker_options[]')
    fi

    apply_dokku_settings "$app_name" "$dokku_settings"

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
        echo -e "${BLUE}Applying secrets from .env files...${NC}"
        ssh $SSH_ALIAS "dokku config:set --no-restart $app_name $secrets" >/dev/null 2>&1 || true
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
                # Escape single quotes and wrap in single quotes for safe ssh passing
                local escaped_value="${value//\'/\'\\\'\'}"
                escaped_vars="$escaped_vars '${key}=${escaped_value}'"
            done < <(echo "$deployment" | jq -c '.env_vars | to_entries[]')
            ssh $SSH_ALIAS "dokku config:set --no-restart $app_name $escaped_vars" >/dev/null 2>&1 || true
        fi
    fi

    # If MySQL service is managed by Dokku, force app DB vars from live service DSN
    if [ -n "$mysql_service_name" ]; then
        local mysql_dsn
        mysql_dsn=$(ssh $SSH_ALIAS "dokku mysql:info $mysql_service_name --single-info-flag Dsn 2>/dev/null || dokku mysql:info $mysql_service_name 2>/dev/null | grep 'Dsn:' | sed 's/.*Dsn:[[:space:]]*//'" | tail -n 1)

        if [ -n "$mysql_dsn" ] && [[ "$mysql_dsn" == mysql://* ]]; then
            local mysql_user mysql_pass mysql_host_live mysql_port mysql_db
            mysql_user=$(echo "$mysql_dsn" | sed -E 's#^mysql://([^:]+):.*#\1#')
            mysql_pass=$(echo "$mysql_dsn" | sed -E 's#^mysql://[^:]+:([^@]+)@.*#\1#')
            mysql_host_live=$(echo "$mysql_dsn" | sed -E 's#^mysql://[^@]+@([^:]+):.*#\1#')
            mysql_port=$(echo "$mysql_dsn" | sed -E 's#^mysql://[^@]+@[^:]+:([0-9]+)/.*#\1#')
            mysql_db=$(echo "$mysql_dsn" | sed -E 's#^.*/([^/?]+).*$#\1#')

            local mysql_env_string=""
            local mysql_host_live_escaped mysql_port_escaped mysql_db_escaped mysql_user_escaped mysql_pass_escaped
            mysql_host_live_escaped=$(escape_shell_single_quoted "$mysql_host_live")
            mysql_port_escaped=$(escape_shell_single_quoted "$mysql_port")
            mysql_db_escaped=$(escape_shell_single_quoted "$mysql_db")
            mysql_user_escaped=$(escape_shell_single_quoted "$mysql_user")
            mysql_pass_escaped=$(escape_shell_single_quoted "$mysql_pass")
            mysql_env_string="$mysql_env_string 'DATABASE_CLIENT=mysql2'"
            mysql_env_string="$mysql_env_string 'DATABASE_HOST=${mysql_host_live_escaped}'"
            mysql_env_string="$mysql_env_string 'DATABASE_PORT=${mysql_port_escaped}'"
            mysql_env_string="$mysql_env_string 'DATABASE_NAME=${mysql_db_escaped}'"
            mysql_env_string="$mysql_env_string 'DATABASE_USERNAME=${mysql_user_escaped}'"
            mysql_env_string="$mysql_env_string 'DATABASE_PASSWORD=${mysql_pass_escaped}'"

            echo -e "${BLUE}Applying MySQL connection vars from service DSN...${NC}"
            ssh $SSH_ALIAS "dokku config:set --no-restart $app_name $mysql_env_string" >/dev/null 2>&1 || {
                echo -e "${RED}Failed to apply MySQL connection vars from service DSN${NC}"
                return 1
            }
        fi
    fi

    # Set build args (build-time) - handled via docker-options
    if echo "$deployment" | jq -e '.build_args' > /dev/null 2>&1; then
        echo -e "${BLUE}Setting build arguments...${NC}"

        # Clear existing build args first
        ssh $SSH_ALIAS "dokku docker-options:clear $app_name build" || true

        # Add build args from config.json only (not .env secrets - those are runtime only)
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            local key=$(echo "$line" | jq -r '.key')
            local value=$(echo "$line" | jq -r '.value')
            # Escape double quotes in value and wrap in double quotes
            local escaped_value="${value//\"/\\\"}"
            ssh -n $SSH_ALIAS "dokku docker-options:add $app_name build '--build-arg ${key}=\"${escaped_value}\"'" || true
        done < <(echo "$deployment" | jq -c '.build_args | to_entries[]')
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

    if [ -n "$subtree_prefix_effective" ]; then
        echo -e "${BLUE}Deploying subtree: $subtree_prefix_effective (${local_commit:0:8})${NC}"
    else
        echo -e "${BLUE}Deploying branch: $repo_branch${NC}"
    fi

    # Set version metadata before deploy
    echo -e "${BLUE}Setting version metadata...${NC}"
    local app_version=""
    # Check if local_commit is tagged with a version
    app_version=$(git tag --points-at "$local_commit" 2>/dev/null | grep -E '^v[0-9]+\.' | head -1 || echo "")
    local git_ref="${repo_branch}"

    # Build config:set command
    local version_vars="GIT_REF=${git_ref}"
    if [ -n "$app_version" ]; then
        version_vars="APP_VERSION=${app_version} ${version_vars}"
    fi

    ssh -n $SSH_ALIAS "dokku config:set --no-restart $app_name $version_vars" || {
        echo -e "${YELLOW}Warning: Could not set version metadata${NC}"
    }
    echo ""

    # Deploy
    echo -e "${GREEN}Pushing to Dokku...${NC}"
    echo ""

    # Try to push without force first
    local push_ref="$repo_branch"
    if [ -n "$subtree_prefix_effective" ]; then
        push_ref="$local_commit"
    fi
    if git push "$remote_name" "$push_ref:refs/heads/$dokku_branch"; then
        echo ""
        echo -e "${GREEN}Pushed successfully${NC}"
    else
        # If that fails, it's likely a new app or history diverged
        echo ""
        echo -e "${YELLOW}Normal push failed, attempting force push...${NC}"
        git push "$remote_name" "$push_ref:refs/heads/$dokku_branch" -f
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

    # External health checks are intentionally skipped here.
    # Dokku already performs deployment health checks before switching traffic.

    # Enable Let's Encrypt SSL if configured and not already enabled
    if [ "$enable_letsencrypt" = "true" ]; then
        echo -e "${BLUE}Checking SSL configuration...${NC}"

    # Let's Encrypt cannot issue certs for internal .dokku hostnames
    local default_dokku_vhost="${app_name}.dokku"
    local escaped_default_dokku_vhost="${app_name//./\.}\.dokku"
    if ssh -n $SSH_ALIAS "dokku domains:report $app_name 2>/dev/null | grep -E '(^|[[:space:]])${escaped_default_dokku_vhost}([[:space:]]|$)'" >/dev/null; then
        echo -e "${BLUE}Removing internal Dokku vhost ($default_dokku_vhost) before Let's Encrypt...${NC}"
        ssh -n $SSH_ALIAS "dokku domains:remove $app_name $default_dokku_vhost" || true
    fi

        # Check if letsencrypt plugin is installed
        if ! ssh $SSH_ALIAS "dokku plugin:list" 2>/dev/null | grep -q "letsencrypt"; then
            echo -e "${YELLOW}Let's Encrypt plugin not installed on Dokku${NC}"
            echo -e "${YELLOW}Install with: ssh $SSH_ALIAS sudo dokku plugin:install https://github.com/dokku/dokku-letsencrypt.git${NC}"
            echo -e "${YELLOW}Then configure: ssh $SSH_ALIAS dokku letsencrypt:set --global email your-email@example.com${NC}"
        elif ssh $SSH_ALIAS "dokku certs:report $app_name" 2>/dev/null | grep -q "Ssl enabled:.*true"; then
            echo -e "${GREEN}SSL already enabled${NC}"
        else
            echo -e "${BLUE}Enabling Let's Encrypt SSL certificate...${NC}"
            local ssl_output
            local ssl_exit_code
            set +e
            ssl_output=$(ssh $SSH_ALIAS "dokku letsencrypt:enable $app_name" 2>&1)
            ssl_exit_code=$?
            set -e

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
