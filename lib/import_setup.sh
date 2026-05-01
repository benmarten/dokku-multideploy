fetch_remote_app_report_bundle() {
    local ssh_alias="$1"
    local app="$2"

    local bundle
    bundle=$(ssh -n "$ssh_alias" "
        app='$app'
        print_section() {
            section=\"\$1\"
            shift
            printf '__DOKKU_MULTI_BEGIN__%s__\n' \"\$section\"
            \"\$@\" 2>/dev/null || true
            printf '__DOKKU_MULTI_END__%s__\n' \"\$section\"
        }

        print_section domains dokku domains:report \"\$app\"
        print_section ports dokku ports:report \"\$app\"
        print_section storage dokku storage:report \"\$app\"
        print_section docker_options dokku docker-options:report \"\$app\"
        print_section postgres dokku postgres:info \"\$app\"
        print_section letsencrypt dokku letsencrypt:active \"\$app\"
        print_section builder dokku builder:report \"\$app\"
        print_section nginx dokku nginx:report \"\$app\"
        print_section network dokku network:report \"\$app\"
        print_section config_export dokku config:export \"\$app\"
        print_section git_report dokku git:report \"\$app\"
    " 2>/dev/null || true)

    if ! printf '%s\n' "$bundle" | grep -q "__DOKKU_MULTI_BEGIN__config_export__"; then
        return 1
    fi

    printf '%s' "$bundle"
}

extract_remote_app_report_section() {
    local bundle="$1"
    local section="$2"

    printf '%s\n' "$bundle" | awk -v start="__DOKKU_MULTI_BEGIN__${section}__" -v end="__DOKKU_MULTI_END__${section}__" '
        $0 == start { in_block = 1; next }
        $0 == end { exit }
        in_block { print }
    '
}

import_from_server() {
    local import_dir="$1"
    local ssh_alias="$2"
    local import_secrets="$3"
    shift 3
    local selected_apps=("$@")
    local import_global_domain="${IMPORT_GLOBAL_DOMAIN:-}"
    local import_letsencrypt_email="${IMPORT_LETSENCRYPT_EMAIL:-}"

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
        ssh_host=$(ssh -n "$ssh_alias" "echo \$SSH_CONNECTION" | awk '{print $3}')
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
    apps=$(ssh -n "$ssh_alias" "dokku apps:list" | tail -n +2)
    local app_count=$(echo "$apps" | wc -l | tr -d ' ')
    echo -e "${GREEN}Found $app_count apps${NC}"
    echo ""

    if [ ${#selected_apps[@]} -gt 0 ]; then
        local filtered_apps=""
        for requested_app in "${selected_apps[@]}"; do
            if echo "$apps" | tr ' ' '\n' | grep -Fxq "$requested_app"; then
                filtered_apps+="$requested_app "
            else
                echo -e "${YELLOW}Skipping unknown app: $requested_app${NC}"
            fi
        done
        filtered_apps=$(echo "$filtered_apps" | xargs || true)
        if [ -z "$filtered_apps" ]; then
            echo -e "${RED}No matching apps found for selection${NC}"
            exit 1
        fi
        apps="$filtered_apps"
        app_count=$(echo "$apps" | wc -w | tr -d ' ')
        echo -e "${BLUE}Import filter applied (${#selected_apps[@]} requested):${NC}"
        for selected_app in $apps; do
            echo -e "  ${BLUE}•${NC} $selected_app"
        done
        echo ""
    fi

    # Discover Dokku global vhosts to filter auto-generated app hostnames
    local dokku_global_vhosts=""
    dokku_global_vhosts=$(ssh -n "$ssh_alias" "dokku domains:report --global" 2>/dev/null | awk -F': *' '/Domains global vhosts:/{print $2; exit}' | xargs || true)

    # Initialize config structure
    local config_json='{"ssh_alias": "'$ssh_alias'", "ssh_host": "dokku@'$ssh_host'"}'
    if [ -n "$import_global_domain" ]; then
        config_json=$(echo "$config_json" | jq --arg gd "$import_global_domain" '. + {global_domain: $gd}')
    fi
    if [ -n "$import_letsencrypt_email" ]; then
        config_json=$(echo "$config_json" | jq --arg le "$import_letsencrypt_email" '. + {letsencrypt_email: $le}')
    fi

    # Process each app
    local count=0
    for app in $apps; do
        count=$((count + 1))
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${GREEN}[$count/$app_count] Processing: $app${NC}"
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

        local app_dir="$import_dir/$app"
        local app_report_bundle
        if ! app_report_bundle=$(fetch_remote_app_report_bundle "$ssh_alias" "$app"); then
            echo -e "  ${RED}Failed to fetch Dokku report bundle for $app${NC}"
            exit 1
        fi

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
        domains=$(extract_remote_app_report_section "$app_report_bundle" domains | grep "Domains app vhosts:" | sed 's/.*Domains app vhosts:[[:space:]]*//')

        # Find primary/extra domains and ignore internal Dokku vhosts
        local primary_domain=""
        local extra_domains=""

        for domain in $domains; do
            # Ignore internal Dokku domain(s)
            if [[ "$domain" == *.dokku ]]; then
                continue
            fi
            # Ignore Dokku auto-generated global-vhost aliases like <app>.<global-vhost>
            local is_internal_global_vhost=false
            for global_vhost in $dokku_global_vhosts; do
                if [ "$domain" = "$app.$global_vhost" ]; then
                    is_internal_global_vhost=true
                    break
                fi
            done
            if [ "$is_internal_global_vhost" = true ]; then
                continue
            fi
            if [ -z "$primary_domain" ]; then
                primary_domain="$domain"
            else
                extra_domains="$extra_domains $domain"
            fi
        done
        extra_domains=$(echo "$extra_domains" | xargs)  # trim whitespace

        # If no public domain exists, synthesize one from global_domain when available
        if [ -z "$primary_domain" ] && [ -n "$import_global_domain" ]; then
            primary_domain="$app.$import_global_domain"
            extra_domains=""
        fi

        # If still empty, fall back to first available domain from Dokku report
        if [ -z "$primary_domain" ]; then
            primary_domain=$(echo "$domains" | awk '{print $1}')
            extra_domains=""
        fi

        if [ -z "$primary_domain" ] || [ "$primary_domain" = "$app" ]; then
            primary_domain="$app"
        fi

        # Default local folder style for synthesized domains: app-global-domain
        local source_dir_value="$primary_domain"
        if [ -n "$import_global_domain" ] && [ "$primary_domain" = "$app.$import_global_domain" ]; then
            source_dir_value=$(echo "$primary_domain" | tr '.' '-')
        fi

        echo -e "  Domain: $primary_domain"

        # Rename cloned directory to match source_dir
        local domain_dir="$import_dir/$source_dir_value"
        if [ "$app_dir" != "$domain_dir" ] && [ -d "$app_dir" ] && [ ! -d "$domain_dir" ]; then
            mv "$app_dir" "$domain_dir"
        fi

        # Get ports (skip default http:80:* single port mappings)
        local ports_raw
        ports_raw=$(extract_remote_app_report_section "$app_report_bundle" ports | grep "Ports map:" | grep -v "detected:" | sed 's/.*Ports map:[[:space:]]*//')
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
        storage_raw=$(extract_remote_app_report_section "$app_report_bundle" storage | grep "Storage deploy mounts:" | sed 's/.*Storage deploy mounts:[[:space:]]*//')
        local storage_json="[]"
        if [ -n "$storage_raw" ] && [ "$storage_raw" != "" ]; then
            # Parse -v /host:/container format, output as "host:container" strings
            storage_json=$(echo "$storage_raw" | grep -oE '/[^:]+:[^ ]+' | while read mount; do
                echo "\"$mount\""
            done | jq -s '.')
        fi

        # Fetch docker options once and reuse it for deploy/build parsing.
        local docker_options_report
        docker_options_report=$(extract_remote_app_report_section "$app_report_bundle" docker_options)

        # Get docker options (capture -p port mappings from deploy phase)
        local docker_opts_raw
        docker_opts_raw=$(printf '%s\n' "$docker_options_report" | grep "Docker options deploy:" | sed 's/.*Docker options deploy:[[:space:]]*//')
        local docker_options_json="[]"
        if [ -n "$docker_opts_raw" ] && [ "$docker_opts_raw" != "" ]; then
            # Extract -p mappings (including ranges like 21100-21110:21100-21110).
            # Ignore non-port options such as -v mounts (handled by storage import).
            docker_options_json=$(echo "$docker_opts_raw" | grep -oE '\-p [0-9-]+:[0-9-]+' | while read opt; do
                echo "\"$opt\""
            done | jq -s '.')
        fi

        # Get build args from Docker build options.
        local build_opts_raw
        build_opts_raw=$(printf '%s\n' "$docker_options_report" | grep "Docker options build:" | sed 's/.*Docker options build:[[:space:]]*//')
        local secret_build_arg_lines=""
        local public_build_arg_lines=""
        local imported_public_build_args_json="{}"
        if [ -n "$build_opts_raw" ] && [ "$build_opts_raw" != "" ]; then
            local build_arg_line
            while IFS= read -r build_arg_line; do
                [ -z "$build_arg_line" ] && continue
                if [[ ! "$build_arg_line" =~ ^--build-arg[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
                    continue
                fi

                local build_key="${BASH_REMATCH[1]}"
                local build_value="${BASH_REMATCH[2]}"
                if [[ "$build_value" =~ ^\"(.*)\"$ ]] || [[ "$build_value" =~ ^\'(.*)\'$ ]]; then
                    build_value="${BASH_REMATCH[1]}"
                fi
                build_value="${build_value//\\\"/\"}"
                build_value="${build_value//\\\\/\\}"

                if is_ignored_sync_key "$build_key"; then
                    continue
                fi

                if is_sensitive_env_key "$build_key"; then
                    secret_build_arg_lines+="${build_key}=${build_value}"$'\n'
                else
                    public_build_arg_lines+="${build_key}=${build_value}"$'\n'
                fi
            done < <(printf '%s\n' "$build_opts_raw" | grep -oE -- '--build-arg [A-Za-z_][A-Za-z0-9_]*=([^[:space:]]+|"([^"\\]|\\.)*")')

            if [ -n "$public_build_arg_lines" ]; then
                imported_public_build_args_json=$(printf "%s" "$public_build_arg_lines" | jq -Rn '
                    [inputs | select(length > 0) | capture("^(?<k>[^=]+)=(?<v>.*)$")]
                    | reduce .[] as $item ({}; .[$item.k] = $item.v)
                ')
            fi

            if [ "$import_secrets" = true ] && [ -n "$secret_build_arg_lines" ]; then
                printf "%s" "$secret_build_arg_lines" > "$env_path/$primary_domain.build"
            fi
        fi

        # Check PostgreSQL
        local postgres="false"
        if [ -n "$(extract_remote_app_report_section "$app_report_bundle" postgres)" ]; then
            postgres="true"
            echo -e "  PostgreSQL: linked"
        fi

        # Check Let's Encrypt (command outputs "true" or "false" as text)
        local letsencrypt="false"
        local le_status
        le_status=$(extract_remote_app_report_section "$app_report_bundle" letsencrypt | head -n1 | xargs || true)
        if [ "$le_status" = "true" ]; then
            letsencrypt="true"
            echo -e "  Let's Encrypt: active"
        fi

        # Get builder type
        local builder=""
        builder=$(extract_remote_app_report_section "$app_report_bundle" builder | sed -n 's/.*Builder selected:[[:space:]]*//p' | head -n1 | xargs)

        # Import app-level Dokku plugin settings (nginx + network attach settings).
        local dokku_settings_json="{}"
        local nginx_client_max_body_size
        nginx_client_max_body_size=$(extract_remote_app_report_section "$app_report_bundle" nginx | sed -n 's/^ *Nginx client max body size:[[:space:]]*//p' | head -n1 | xargs)
        # Skip Dokku's default 1m to avoid false drift when config does not set this explicitly.
        if [ -n "$nginx_client_max_body_size" ] && [ "$nginx_client_max_body_size" != "1m" ]; then
            dokku_settings_json=$(echo "$dokku_settings_json" | jq -c --arg size "$nginx_client_max_body_size" '
                . + {
                    nginx: {
                        "client-max-body-size": $size
                    }
                }
            ')
        fi

        local network_attach_post_create
        network_attach_post_create=$(extract_remote_app_report_section "$app_report_bundle" network | sed -n 's/^ *Network attach post create:[[:space:]]*//Ip' | head -n1 | xargs)
        # Only persist explicit network attachment values.
        if [ -n "$network_attach_post_create" ] && [ "$network_attach_post_create" != "false" ] && [ "$network_attach_post_create" != "none" ] && [ "$network_attach_post_create" != "(none)" ]; then
            dokku_settings_json=$(echo "$dokku_settings_json" | jq -c --arg attach "$network_attach_post_create" '
                . + {
                    network: {
                        "attach-post-create": $attach
                    }
                }
            ')
        fi

        # Export env vars. Public env vars always belong in config.json; secret .env output
        # is optional so sync/import can inspect live public config without writing secrets.
        local imported_public_env_json="{}"
        echo -e "  ${BLUE}Exporting env vars...${NC}"
        local env_vars
        local imported_git_ref=""
        # Get env vars, remove 'export ' prefix, filter out Dokku internal vars.
        # Also filter DATABASE_URL as it's auto-set by dokku postgres:link.
        env_vars=$(extract_remote_app_report_section "$app_report_bundle" config_export | \
            sed 's/^export //' | \
            grep -v '^DOKKU_\|^GIT_REV=\|^DATABASE_URL=' || true)
        if [ -n "$env_vars" ]; then
            local secret_env_lines=""
            local public_env_lines=""
            local env_line
            while IFS= read -r env_line; do
                [ -z "$env_line" ] && continue
                if [[ "$env_line" != *=* ]]; then
                    continue
                fi

                local env_key="${env_line%%=*}"
                local env_value="${env_line#*=}"
                [ -z "$env_key" ] && continue

                # Dokku emits shell-quoted exports for values with spaces/special chars.
                # Strip a single matching pair of outer quotes before persisting public
                # env vars to config.json, but keep the original line for .env secrets.
                if [[ "$env_value" =~ ^\"(.*)\"$ ]] || [[ "$env_value" =~ ^\'(.*)\'$ ]]; then
                    env_value="${BASH_REMATCH[1]}"
                fi

                if [ "$env_key" = "GIT_REF" ]; then
                    imported_git_ref="$env_value"
                fi

                if is_ignored_sync_key "$env_key"; then
                    continue
                fi

                if is_sensitive_env_key "$env_key"; then
                    secret_env_lines+="$env_line"$'\n'
                else
                    public_env_lines+="${env_key}=${env_value}"$'\n'
                fi
            done <<< "$env_vars"

            if [ "$import_secrets" = true ] && [ -n "$secret_env_lines" ]; then
                printf "%s" "$secret_env_lines" > "$env_path/$primary_domain"
            fi

            if [ -n "$public_env_lines" ]; then
                imported_public_env_json=$(printf "%s" "$public_env_lines" | jq -Rn '
                    [inputs | select(length > 0) | capture("^(?<k>[^=]+)=(?<v>.*)$")]
                    | reduce .[] as $item ({}; .[$item.k] = $item.v)
                ')
            fi

            local env_rel_path="${env_path#$SCRIPT_DIR/}"
            local var_count
            var_count=$(echo "$env_vars" | wc -l | tr -d ' ')
            local secret_count=0
            local public_count=0
            local secret_build_count=0
            local public_build_count=0
            if [ -n "$secret_env_lines" ]; then
                secret_count=$(printf "%s" "$secret_env_lines" | sed '/^$/d' | wc -l | tr -d ' ')
            fi
            if [ -n "$public_env_lines" ]; then
                public_count=$(printf "%s" "$public_env_lines" | sed '/^$/d' | wc -l | tr -d ' ')
            fi
            if [ -n "$secret_build_arg_lines" ]; then
                secret_build_count=$(printf "%s" "$secret_build_arg_lines" | sed '/^$/d' | wc -l | tr -d ' ')
            fi
            if [ -n "$public_build_arg_lines" ]; then
                public_build_count=$(printf "%s" "$public_build_arg_lines" | sed '/^$/d' | wc -l | tr -d ' ')
            fi

            if [ "$import_secrets" = true ]; then
                if [ "$secret_count" -gt 0 ]; then
                    echo -e "  ${GREEN}Saved $secret_count secret vars to $env_rel_path/$primary_domain${NC}"
                else
                    echo -e "  ${YELLOW}No secret vars saved to .env/$primary_domain${NC}"
                fi
            else
                echo -e "  ${BLUE}Skipped writing $secret_count secret vars (.env export disabled)${NC}"
            fi
            if [ "$public_count" -gt 0 ]; then
                echo -e "  ${GREEN}Saved $public_count non-secret vars to config.json env_vars${NC}"
            else
                echo -e "  ${YELLOW}No non-secret vars saved to config.json env_vars${NC}"
            fi
            if [ "$import_secrets" = true ]; then
                if [ "$secret_build_count" -gt 0 ]; then
                    echo -e "  ${GREEN}Saved $secret_build_count build secrets to $env_rel_path/$primary_domain.build${NC}"
                else
                    echo -e "  ${YELLOW}No build secrets saved to .env/$primary_domain.build${NC}"
                fi
            else
                echo -e "  ${BLUE}Skipped writing $secret_build_count build secrets (.build export disabled)${NC}"
            fi
            if [ "$public_build_count" -gt 0 ]; then
                echo -e "  ${GREEN}Saved $public_build_count non-secret build args to config.json build_args${NC}"
            else
                echo -e "  ${YELLOW}No non-secret build args saved to config.json build_args${NC}"
            fi
            echo -e "  ${BLUE}Total imported env vars:${NC} $var_count"
        else
            echo -e "  ${YELLOW}No env vars to export${NC}"
        fi

        # Prefer the recorded source ref over Dokku's internal deploy branch.
        local branch="$imported_git_ref"
        if [ -z "$branch" ]; then
            branch=$(extract_remote_app_report_section "$app_report_bundle" git_report | grep "Git deploy branch:" | awk '{print $NF}')
        fi
        [ -z "$branch" ] && branch="master"

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
            --arg source_dir "$source_dir_value" \
            --arg branch "$branch" \
            --arg builder "$builder" \
            --arg postgres "$postgres" \
            --arg letsencrypt "$letsencrypt" \
            --argjson ports "$ports_json" \
            --argjson storage "$storage_json" \
            --argjson docker_options "$docker_options_json" \
            --argjson extra_domains "$extra_domains_json" \
            --argjson dokku_settings "$dokku_settings_json" \
            --argjson imported_public_env "$imported_public_env_json" \
            --argjson imported_public_build_args "$imported_public_build_args_json" \
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
                dokku_settings: (if $dokku_settings == {} then null else $dokku_settings end),
                deployments: {
                    ($domain): (
                        {}
                        + (if $imported_public_env == {} then {} else {env_vars: $imported_public_env} end)
                        + (if $imported_public_build_args == {} then {} else {build_args: $imported_public_build_args} end)
                    )
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
        local dokku_version=$(ssh -n "$ssh_alias" "dokku version" 2>/dev/null || echo "unknown")
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
    local current_email=$(ssh -n "$ssh_alias" "dokku letsencrypt:set --global email 2>/dev/null | grep -oE '[^ ]+@[^ ]+'" || echo "")

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
