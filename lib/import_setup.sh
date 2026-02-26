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
    # Prefer ssh config hostname (public/reachable), then fallback to SSH_CONNECTION.
    local ssh_host
    ssh_host=$(ssh -G "$ssh_alias" 2>/dev/null | awk '/^hostname / {print $2; exit}')
    if [ -z "$ssh_host" ]; then
        ssh_host=$(ssh "$ssh_alias" "echo \$SSH_CONNECTION" | awk '{print $3}')
    fi
    echo -e "${BLUE}Dokku host: $ssh_host${NC}"

    # Create import directory
    mkdir -p "$import_dir"

    # All output goes to import directory
    local env_path="$import_dir/.env"
    mkdir -p "$env_path"

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

        # Clone git repo (unless --no-clone)
        if [ "$IMPORT_NO_CLONE" = true ]; then
            echo -e "  ${YELLOW}Skipping git clone (--no-clone)${NC}"
            mkdir -p "$app_dir"
        else
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
        fi

        # Get primary domain
        # Prefer custom domains over auto-generated ones (domains starting with app-name)
        local domains
        domains=$(ssh "$ssh_alias" "dokku domains:report $app" 2>/dev/null | grep "Domains app vhosts:" | sed 's/.*Domains app vhosts:[[:space:]]*//')

        # Find custom domains (exclude auto-generated ones starting with app-name.)
        local primary_domain=""
        local extra_domains=""
        local app_prefix="${app}."

        # Collect only custom domains (not starting with app name)
        for domain in $domains; do
            if [[ "$domain" != ${app_prefix}* ]]; then
                if [ -z "$primary_domain" ]; then
                    primary_domain="$domain"
                else
                    extra_domains="$extra_domains $domain"
                fi
            fi
        done
        extra_domains=$(echo "$extra_domains" | xargs)  # trim whitespace

        # If no custom domain found, use first available domain as primary (but no extras)
        if [ -z "$primary_domain" ]; then
            primary_domain=$(echo "$domains" | awk '{print $1}')
            extra_domains=""
        fi

        if [ -z "$primary_domain" ] || [ "$primary_domain" = "$app" ]; then
            primary_domain="$app"
        fi
        echo -e "  Domain: $primary_domain"

        # Rename cloned directory to use domain name (matches source_dir)
        local domain_dir="$import_dir/$primary_domain"
        if [ "$app_dir" != "$domain_dir" ] && [ -d "$app_dir" ] && [ ! -d "$domain_dir" ]; then
            mv "$app_dir" "$domain_dir"
        fi

        # Get ports (skip default http:80:* single port mappings)
        local ports_raw
        ports_raw=$(ssh "$ssh_alias" "dokku ports:report $app" 2>/dev/null | grep "Ports map:" | grep -v "detected:" | sed 's/.*Ports map:[[:space:]]*//')
        local ports_json="[]"
        if [ -n "$ports_raw" ] && [ "$ports_raw" != "" ]; then
            # Check if it's just a default single http:80:* mapping
            local port_count=$(echo "$ports_raw" | wc -w | tr -d ' ')
            local is_default=false
            if [ "$port_count" -eq 1 ] && [[ "$ports_raw" == http:80:* ]]; then
                is_default=true
            fi
            if [ "$is_default" = false ]; then
                # Output as strings like "http:80:5000"
                ports_json=$(echo "$ports_raw" | tr ' ' '\n' | grep -v '^$' | while read port_map; do
                    echo "\"$port_map\""
                done | jq -s '.')
            fi
        fi

        # Get storage mounts (from deploy mounts, format: -v /host:/container)
        local storage_raw
        storage_raw=$(ssh "$ssh_alias" "dokku storage:report $app" 2>/dev/null | grep "Storage deploy mounts:" | sed 's/.*Storage deploy mounts:[[:space:]]*//')
        local storage_json="[]"
        if [ -n "$storage_raw" ] && [ "$storage_raw" != "" ]; then
            # Parse -v /host:/container format, output as "host:container" strings
            storage_json=$(echo "$storage_raw" | grep -oE '/[^:]+:[^ ]+' | while read mount; do
                echo "\"$mount\""
            done | jq -s '.')
        fi

        # Get docker options (capture -p port mappings from deploy phase)
        local docker_opts_raw
        docker_opts_raw=$(ssh "$ssh_alias" "dokku docker-options:report $app" 2>/dev/null | grep "Docker options deploy:" | sed 's/.*Docker options deploy:[[:space:]]*//')
        local docker_options_json="[]"
        if [ -n "$docker_opts_raw" ] && [ "$docker_opts_raw" != "" ]; then
            # Extract -p port:port mappings (not -v volume mounts, those are handled by storage)
            docker_options_json=$(echo "$docker_opts_raw" | grep -oE '\-p [0-9]+:[0-9]+' | while read opt; do
                echo "\"$opt\""
            done | jq -s '.')
        fi

        # Check PostgreSQL
        local postgres="false"
        if ssh "$ssh_alias" "dokku postgres:info $app" &>/dev/null; then
            postgres="true"
            echo -e "  PostgreSQL: linked"
        fi

        # Check Let's Encrypt (command outputs "true" or "false" as text)
        local letsencrypt="false"
        local le_status=$(ssh "$ssh_alias" "dokku letsencrypt:active $app" 2>/dev/null || echo "false")
        if [ "$le_status" = "true" ]; then
            letsencrypt="true"
            echo -e "  Let's Encrypt: active"
        fi

        # Get deploy branch
        local branch
        branch=$(ssh "$ssh_alias" "dokku git:report $app" 2>/dev/null | grep "Git deploy branch:" | awk '{print $NF}')
        [ -z "$branch" ] && branch="master"

        # Get builder type
        local builder=""
        builder=$(ssh "$ssh_alias" "dokku builder:report $app" 2>/dev/null | grep "Builder selected:" | awk '{print $NF}')

        # Export env vars
        if [ "$import_secrets" = true ]; then
            echo -e "  ${BLUE}Exporting env vars...${NC}"
            local env_vars
            # Get env vars, remove 'export ' prefix, filter out Dokku internal vars
            # Also filter DATABASE_URL as it's auto-set by dokku postgres:link
            env_vars=$(ssh "$ssh_alias" "dokku config:export $app" 2>/dev/null | \
                sed 's/^export //' | \
                grep -v '^DOKKU_\|^GIT_REV=\|^PORT=\|^DATABASE_URL=' || true)
            if [ -n "$env_vars" ]; then
                echo "$env_vars" > "$env_path/$primary_domain"
                local env_rel_path="${env_path#$SCRIPT_DIR/}"
                local var_count=$(echo "$env_vars" | wc -l | tr -d ' ')
                echo -e "  ${GREEN}Saved $var_count vars to $env_rel_path/$primary_domain${NC}"
            else
                echo -e "  ${YELLOW}No env vars to export${NC}"
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
            --arg source_dir "$primary_domain" \
            --arg branch "$branch" \
            --arg builder "$builder" \
            --arg postgres "$postgres" \
            --arg letsencrypt "$letsencrypt" \
            --argjson ports "$ports_json" \
            --argjson storage "$storage_json" \
            --argjson docker_options "$docker_options_json" \
            --argjson extra_domains "$extra_domains_json" \
            '{
                source_dir: $source_dir,
                branch: $branch,
                builder: (if $builder == "" then null else $builder end),
                postgres: (if $postgres == "true" then true else null end),
                letsencrypt: (if $letsencrypt == "true" then true else null end),
                ports: (if $ports == [] then null else $ports end),
                storage_mounts: (if $storage == [] then null else $storage end),
                docker_options: (if $docker_options == [] then null else $docker_options end),
                extra_domains: (if $extra_domains == [] then null else $extra_domains end),
                deployments: {
                    ($domain): {}
                }
            } | with_entries(select(.value != null and .value != false))')

        # Add to main config
        config_json=$(echo "$config_json" | jq --arg key "$parent_key" --argjson config "$deployment_config" '.[$key] = $config')

        echo ""
    done

    # Write config to import directory
    local config_path="$import_dir/config.json"
    echo "$config_json" | jq '.' > "$config_path"

    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}Import complete!${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  Config:  ${BLUE}$config_path${NC}"
    if [ "$import_secrets" = true ]; then
        echo -e "  Secrets: ${BLUE}$env_path/${NC}"
    fi
    echo -e "  Apps:    ${BLUE}$import_dir/<app-name>/${NC}"
    echo ""
    echo -e "${GREEN}To deploy, symlink deploy.sh and run:${NC}"
    echo "  ln -s $(cd "$SCRIPT_DIR" && pwd)/deploy.sh $import_dir/deploy.sh"
    echo "  cd $import_dir && ./deploy.sh --dry-run"
    echo ""
}

setup_server() {
    local ssh_alias="$1"
    local letsencrypt_email="$2"

    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}   dokku-multideploy - Server Setup${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
    echo ""

    # Check SSH connectivity first
    echo -e "${BLUE}Checking SSH connectivity to $ssh_alias...${NC}"
    if ! ssh -o ConnectTimeout=10 "$ssh_alias" "echo 'Connection OK'" &>/dev/null; then
        echo -e "${RED}Cannot connect to $ssh_alias${NC}"
        echo -e "${RED}Please check your SSH configuration${NC}"
        exit 1
    fi
    echo -e "${GREEN}Connected${NC}"
    echo ""

    # Check if Dokku is installed
    echo -e "${BLUE}Checking if Dokku is installed...${NC}"
    if ssh "$ssh_alias" "command -v dokku" &>/dev/null; then
        local dokku_version=$(ssh "$ssh_alias" "dokku version" 2>/dev/null || echo "unknown")
        echo -e "${GREEN}Dokku is installed (version: $dokku_version)${NC}"
    else
        echo -e "${YELLOW}Dokku is not installed${NC}"
        echo ""
        read -p "Install Dokku now? (yes/no): " confirm
        if [ "$confirm" = "yes" ]; then
            echo -e "${BLUE}Installing Dokku...${NC}"
            echo -e "${YELLOW}This may take a few minutes...${NC}"
            ssh "$ssh_alias" "wget -NP . https://dokku.com/bootstrap.sh && sudo DOKKU_TAG=v0.35.16 bash bootstrap.sh"
            echo -e "${GREEN}Dokku installed${NC}"
        else
            echo -e "${RED}Dokku is required. Exiting.${NC}"
            exit 1
        fi
    fi
    echo ""

    # Install/check required plugins
    echo -e "${BLUE}Checking required plugins...${NC}"
    echo ""

    # Let's Encrypt plugin (universally needed for SSL)
    echo -e "${BLUE}  Checking letsencrypt plugin...${NC}"
    if ssh "$ssh_alias" "dokku plugin:list" 2>/dev/null | grep -q "letsencrypt"; then
        echo -e "${GREEN}  ✓ letsencrypt already installed${NC}"
    else
        echo -e "${YELLOW}  Installing letsencrypt plugin...${NC}"
        ssh "$ssh_alias" "sudo dokku plugin:install https://github.com/dokku/dokku-letsencrypt.git"
        echo -e "${GREEN}  ✓ letsencrypt installed${NC}"
    fi
    echo ""
    echo -e "${BLUE}Note: Other plugins (postgres, redis, etc.) are auto-installed when needed${NC}"
    echo ""

    # Configure Let's Encrypt email
    echo -e "${BLUE}Configuring Let's Encrypt...${NC}"
    local current_email=$(ssh "$ssh_alias" "dokku letsencrypt:set --global email 2>/dev/null | grep -oE '[^ ]+@[^ ]+'" || echo "")

    if [ -n "$current_email" ]; then
        echo -e "${GREEN}Let's Encrypt email already set: $current_email${NC}"
        if [ -n "$letsencrypt_email" ] && [ "$letsencrypt_email" != "$current_email" ]; then
            read -p "Update to $letsencrypt_email? (yes/no): " confirm
            if [ "$confirm" = "yes" ]; then
                ssh "$ssh_alias" "dokku letsencrypt:set --global email $letsencrypt_email"
                echo -e "${GREEN}Email updated${NC}"
            fi
        fi
    else
        if [ -z "$letsencrypt_email" ]; then
            read -p "Enter Let's Encrypt email address: " letsencrypt_email
        fi
        if [ -n "$letsencrypt_email" ]; then
            ssh "$ssh_alias" "dokku letsencrypt:set --global email $letsencrypt_email"
            echo -e "${GREEN}Let's Encrypt email configured: $letsencrypt_email${NC}"
        else
            echo -e "${YELLOW}Skipped - SSL certificates will need manual email configuration${NC}"
        fi
    fi
    echo ""

    # Show summary
    echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}   Setup complete!${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "Server is ready for deployments. Next steps:"
    echo -e "  1. Update ${BLUE}config.json${NC} with the new server's SSH alias/host"
    echo -e "  2. Run ${BLUE}./deploy.sh --dry-run${NC} to preview deployments"
    echo -e "  3. Deploy a test app: ${BLUE}./deploy.sh csvfilter.e7ad.cc${NC}"
    echo ""
}
