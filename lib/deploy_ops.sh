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
                # Escape single quotes and wrap in single quotes for safe ssh passing
                local escaped_value="${value//\'/\'\\\'\'}"
                escaped_vars="$escaped_vars '${key}=${escaped_value}'"
            done < <(echo "$deployment" | jq -c '.env_vars | to_entries[]')
            ssh $SSH_ALIAS "dokku config:set --no-restart $app_name $escaped_vars" || true
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
        repo_root_rel="${repo_root#$SCRIPT_DIR/}"
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

    # Configure Dokku builder if explicitly set in config
    if [ -n "$builder_type" ]; then
        local current_builder
        current_builder=$(ssh $SSH_ALIAS "dokku builder:report $app_name 2>/dev/null | grep 'Builder selected:' | awk '{print \$NF}'" || echo "")
        if [ "$current_builder" != "$builder_type" ]; then
            echo -e "${BLUE}Setting builder: $builder_type${NC}"
            if ! ssh $SSH_ALIAS "dokku builder:set $app_name $builder_type"; then
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
                # Escape single quotes and wrap in single quotes for safe ssh passing
                local escaped_value="${value//\'/\'\\\'\'}"
                escaped_vars="$escaped_vars '${key}=${escaped_value}'"
            done < <(echo "$deployment" | jq -c '.env_vars | to_entries[]')
            ssh $SSH_ALIAS "dokku config:set --no-restart $app_name $escaped_vars" || true
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
            ssh $SSH_ALIAS "dokku config:set --no-restart $app_name $mysql_env_string" || {
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
        elif ssh $SSH_ALIAS "dokku certs:report $app_name" 2>/dev/null | grep -q "Ssl enabled:.*true"; then
            echo -e "${GREEN}SSL already enabled${NC}"
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
