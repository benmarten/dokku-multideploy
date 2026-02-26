run_sync_check() {
    local sync_dir_resolved
    if [ -n "$SYNC_DIR" ]; then
        if [[ "$SYNC_DIR" == /* ]]; then
            sync_dir_resolved="$SYNC_DIR"
        else
            sync_dir_resolved="$SCRIPT_DIR/$SYNC_DIR"
        fi
    else
        sync_dir_resolved="$SCRIPT_DIR/.sync-cache"
    fi

    local remote_config="$sync_dir_resolved/config.json"
    local compare_tmp_dir
    compare_tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/dokku-sync-compare.XXXXXX")
    local remote_index="$compare_tmp_dir/remote_index.json"
    local sync_ok=true
    local missing_count=0
    local mismatch_count=0
    local local_apps_file="$compare_tmp_dir/local_apps.txt"
    local remote_apps_file="$compare_tmp_dir/remote_apps.txt"

    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}   dokku-multideploy - Sync Check${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
    echo ""

    if [ "$SYNC_RESET" = true ] && [ -d "$sync_dir_resolved" ]; then
        echo -e "${BLUE}Resetting sync cache: $sync_dir_resolved${NC}"
        rm -rf "$sync_dir_resolved"
    fi

    if [ "$SYNC_REFRESH" = true ] || [ ! -f "$remote_config" ]; then
        echo -e "${BLUE}Importing current Dokku state (config only)...${NC}"
        mkdir -p "$sync_dir_resolved"
        local previous_no_clone="$IMPORT_NO_CLONE"
        IMPORT_NO_CLONE=true
        import_from_server "$sync_dir_resolved" "$SSH_ALIAS" false >/dev/null
        IMPORT_NO_CLONE="$previous_no_clone"
        echo -e "${GREEN}Using fresh sync state${NC} (${BLUE}$(file_mtime_human "$remote_config")${NC})"
    else
        echo -e "${BLUE}Using cached Dokku sync state: $sync_dir_resolved${NC}"
        echo -e "${BLUE}(use --refresh-sync to re-import)${NC}"
        echo -e "${YELLOW}Cached sync timestamp:${NC} ${BLUE}$(file_mtime_human "$remote_config")${NC}"
    fi

    if [ ! -f "$remote_config" ]; then
        echo -e "${RED}Error: failed to generate remote config during sync${NC}"
        rm -rf "$compare_tmp_dir"
        return 1
    fi

    jq -c '
        [
            to_entries[]
            | select(.value | type == "object" and has("deployments"))
            | .key as $parent_key
            | .value as $parent
            | ($parent.deployments | to_entries[])
            | .key as $domain
            | .value as $child
            | {
                app_name: ($parent_key | gsub("_"; "-")),
                domain: $domain,
                summary: {
                    branch: ($child.branch // $parent.branch // null),
                    postgres: (($child.postgres // $parent.postgres // false) == true or ($child.postgres // $parent.postgres // false) == "true"),
                    letsencrypt: (($child.letsencrypt // $parent.letsencrypt // false) == true or ($child.letsencrypt // $parent.letsencrypt // false) == "true"),
                    ports: (($child.ports // $parent.ports // []) | map(tostring) | sort),
                    storage_mounts: ((($child.storage_mounts // []) + ($parent.storage_mounts // [])) | map(tostring) | sort),
                    docker_options: ((($child.docker_options // []) + ($parent.docker_options // [])) | map(tostring) | sort),
                    extra_domains: ((($child.extra_domains // []) + ($parent.extra_domains // [])) | map(tostring) | sort)
                }
            }
        ]
    ' "$remote_config" > "$remote_index"

    echo -e "${BLUE}Comparing local config with live Dokku state...${NC}"
    echo ""

    for deployment in "${FILTERED_DEPLOYMENTS[@]}"; do
        local domain
        domain=$(echo "$deployment" | jq -r '.domain')
        local app_name
        app_name=$(echo "$domain" | tr '.' '-')
        local local_summary
        local_summary=$(echo "$deployment" | jq -c '{
            branch: (.branch // null),
            postgres: (.postgres == true),
            letsencrypt: (.letsencrypt == true),
            ports: ((.ports // [])
                | map(tostring)
                | (if (length == 1 and (.[0] | test("^http:80:[0-9]+$"))) then [] else . end)
                | sort),
            storage_mounts: ((.storage_mounts // [])
                | map(if type == "object" then (.mount // "") else tostring end)
                | map(select(. != ""))
                | sort),
            docker_options: ((.docker_options // []) | map(tostring) | sort),
            extra_domains: ((.extra_domains // []) | map(tostring) | sort)
        }')

        local remote_domain
        remote_domain=$(jq -r --arg app "$app_name" '
            first(.[] | select(.app_name == $app) | .domain) // empty
        ' "$remote_index")
        local remote_summary
        remote_summary=$(jq -c --arg app "$app_name" '
            first(.[] | select(.app_name == $app) | .summary) // empty
        ' "$remote_index")

        if [ -z "$remote_summary" ]; then
            echo -e "${RED}✗ Missing on Dokku:${NC} $domain"
            missing_count=$((missing_count + 1))
            sync_ok=false
            continue
        fi

        if [[ "$domain" == *.* ]] && [ -n "$remote_domain" ] && [ "$remote_domain" != "$domain" ]; then
            echo -e "${YELLOW}⚠ Domain mismatch:${NC} $domain (dokku primary: $remote_domain)"
            mismatch_count=$((mismatch_count + 1))
            sync_ok=false
        fi

        local diff_fields=()
        local field
        for field in branch postgres letsencrypt ports storage_mounts docker_options extra_domains; do
            local local_val
            local remote_val
            local_val=$(echo "$local_summary" | jq -c ".$field")
            remote_val=$(echo "$remote_summary" | jq -c ".$field")

            # If branch is not explicitly set locally, accept Dokku's current branch.
            if [ "$field" = "branch" ] && [ "$local_val" = "null" ]; then
                continue
            fi

            # Treat default single http mapping as equivalent to unset ports.
            if [ "$field" = "ports" ]; then
                if [[ "$local_val" =~ ^\\[\"http:80:[0-9]+\"\\]$ ]]; then
                    local_val="[]"
                fi
                if [[ "$remote_val" =~ ^\\[\"http:80:[0-9]+\"\\]$ ]]; then
                    remote_val="[]"
                fi
            fi

            if [ "$field" = "extra_domains" ]; then
                if extra_domains_match "$local_val" "$remote_val"; then
                    continue
                fi
            fi

            if [ "$local_val" != "$remote_val" ]; then
                diff_fields+=("$field")
            fi
        done

        if [ ${#diff_fields[@]} -eq 0 ]; then
            echo -e "${GREEN}✓ In sync:${NC} $domain"
        else
            echo -e "${YELLOW}⚠ Drift:${NC} $domain"
            for field in "${diff_fields[@]}"; do
                local local_val
                local remote_val
                local_val=$(echo "$local_summary" | jq -c ".$field")
                remote_val=$(echo "$remote_summary" | jq -c ".$field")
                echo -e "   ${BLUE}$field${NC}"
                echo -e "     local : $local_val"
                echo -e "     dokku : $remote_val"
            done
            mismatch_count=$((mismatch_count + 1))
            sync_ok=false
        fi
    done

    for deployment in "${FILTERED_DEPLOYMENTS[@]}"; do
        echo "$deployment" | jq -r '.domain' | tr '.' '-'
    done | sort -u > "$local_apps_file"
    jq -r '.[] | .app_name' "$remote_index" | sort -u > "$remote_apps_file"

    local extra_remote_count=0
    while IFS= read -r remote_app; do
        [ -z "$remote_app" ] && continue
        if ! grep -qxF "$remote_app" "$local_apps_file"; then
            local extra_domain
            extra_domain=$(jq -r --arg app "$remote_app" 'first(.[] | select(.app_name == $app) | .domain) // $app' "$remote_index")
            if [ "$extra_remote_count" -eq 0 ]; then
                echo ""
                echo -e "${YELLOW}Apps on Dokku but not in current local selection:${NC}"
            fi
            echo "  - $extra_domain ($remote_app)"
            extra_remote_count=$((extra_remote_count + 1))
        fi
    done < "$remote_apps_file"

    echo ""
    if [ "$sync_ok" = true ]; then
        echo -e "${GREEN}Sync check passed: all selected deployments match Dokku state.${NC}"
    else
        echo -e "${YELLOW}Sync check found differences.${NC}"
        echo -e "  Missing on Dokku: ${RED}$missing_count${NC}"
        echo -e "  Config drift:     ${YELLOW}$mismatch_count${NC}"
        echo -e "  Extra on Dokku:   ${YELLOW}$extra_remote_count${NC}"
    fi

    rm -rf "$compare_tmp_dir"
    [ "$sync_ok" = true ]
}
