truncate_for_status() {
    local value="$1"
    local max_len="$2"
    local value_len=${#value}

    if [ "$value_len" -le "$max_len" ]; then
        echo "$value"
        return
    fi

    if [ "$max_len" -le 3 ]; then
        echo "${value:0:$max_len}"
        return
    fi

    echo "${value:0:$((max_len - 3))}..."
}

normalize_bool_status() {
    local value="$1"
    case "$value" in
        true|yes|on|running) echo "yes" ;;
        false|no|off|stopped) echo "no" ;;
        *) echo "?" ;;
    esac
}

sync_apply_summary_to_child_patch() {
    local remote_summary="$1"
    local diff_fields_json="$2"
    echo "$remote_summary" | jq -c --argjson diff_fields "$diff_fields_json" '
        def settings_from_lines:
            (map(capture("^(?<plugin>[^:]+):(?<key>[^=]+)=(?<value>.*)$"))
            | reduce .[] as $entry ({}; .[$entry.plugin] = ((.[$entry.plugin] // {}) + {($entry.key): $entry.value})));
        {
            branch: (.branch // null),
            builder: (.builder // null),
            postgres: (if .postgres == true then true else null end),
            letsencrypt: (if .letsencrypt == true then true else null end),
            ports: (if (.ports | length) > 0 then .ports else null end),
            storage_mounts: (if (.storage_mounts | length) > 0 then .storage_mounts else null end),
            docker_options: (if (.docker_options | length) > 0 then .docker_options else null end),
            extra_domains: (if (.extra_domains | length) > 0 then .extra_domains else null end),
            dokku_settings: (if (.dokku_settings | length) > 0 then (.dokku_settings | settings_from_lines) else null end)
        }
        | with_entries(. as $entry | select($diff_fields | index($entry.key)))
    '
}

apply_sync_patch_to_config() {
    local domain="$1"
    local child_patch="$2"

    local tmp_file
    tmp_file=$(mktemp "${TMPDIR:-/tmp}/dokku-sync-apply.XXXXXX")

    if ! jq --arg domain "$domain" --argjson patch "$child_patch" '
        reduce (to_entries[]
            | select(.value | type == "object" and has("deployments"))
            | select(.value.deployments | has($domain))
            | .key) as $parent_key
            (.;
                .[$parent_key].deployments[$domain] |= (
                    . as $child
                    | (if ($patch | has("branch")) then (if ($patch.branch == null) then del(.branch) else .branch = $patch.branch end) else . end)
                    | (if ($patch | has("builder")) then (if ($patch.builder == null) then del(.builder) else .builder = $patch.builder end) else . end)
                    | (if ($patch | has("postgres")) then (if ($patch.postgres == null) then del(.postgres) else .postgres = true end) else . end)
                    | (if ($patch | has("letsencrypt")) then (if ($patch.letsencrypt == null) then del(.letsencrypt) else .letsencrypt = true end) else . end)
                    | (if ($patch | has("ports")) then (if ($patch.ports == null) then del(.ports) else .ports = $patch.ports end) else . end)
                    | (if ($patch | has("storage_mounts")) then (if ($patch.storage_mounts == null) then del(.storage_mounts) else .storage_mounts = $patch.storage_mounts end) else . end)
                    | (if ($patch | has("docker_options")) then (if ($patch.docker_options == null) then del(.docker_options) else .docker_options = $patch.docker_options end) else . end)
                    | (if ($patch | has("extra_domains")) then (if ($patch.extra_domains == null) then del(.extra_domains) else .extra_domains = $patch.extra_domains end) else . end)
                    | (if ($patch | has("dokku_settings")) then (if ($patch.dokku_settings == null) then del(.dokku_settings) else .dokku_settings = $patch.dokku_settings end) else . end)
                )
            )
    ' "$CONFIG_FILE" > "$tmp_file"; then
        rm -f "$tmp_file"
        return 1
    fi

    if cmp -s "$CONFIG_FILE" "$tmp_file"; then
        rm -f "$tmp_file"
        return 2
    fi

    mv "$tmp_file" "$CONFIG_FILE"
    return 0
}

get_effective_local_summary_for_domain() {
    local domain="$1"
    jq -c --arg domain "$domain" '
        first([
            to_entries[]
            | select(.value | type == "object" and has("deployments"))
            | .value as $parent
            | ($parent.deployments | to_entries[])
            | select(.key == $domain)
            | .value as $child
            | {
                branch: ($child.branch // $parent.branch // null),
                builder: ($child.builder // $parent.builder // null),
                postgres: (($child.postgres // $parent.postgres // false) == true or ($child.postgres // $parent.postgres // false) == "true"),
                letsencrypt: (($child.letsencrypt // $parent.letsencrypt // false) == true or ($child.letsencrypt // $parent.letsencrypt // false) == "true"),
                ports: (($child.ports // $parent.ports // []) | map(tostring) | sort),
                storage_mounts: ((($child.storage_mounts // []) + ($parent.storage_mounts // [])) | map(tostring) | sort),
                docker_options: ((($child.docker_options // []) + ($parent.docker_options // [])) | map(tostring) | sort),
                extra_domains: ((($child.extra_domains // []) + ($parent.extra_domains // [])) | map(tostring) | sort),
                dokku_settings: (
                    ((($parent.dokku_settings // {}) * ($child.dokku_settings // {})) // {})
                    | to_entries
                    | map(
                        select(.value | type == "object")
                        | .key as $plugin
                        | (
                            .value
                            | to_entries
                            | map("\($plugin):\(.key)=\(.value|tostring)")
                        )
                    )
                    | add // []
                    | sort
                )
            }
        ][])
    ' "$CONFIG_FILE"
}

print_live_status_summary() {
    echo ""
    echo -e "${BLUE}Live App Status (from dokku ps:report --all):${NC}"
    echo "  format: domain | dep:<yes/no> run:<yes/no> procs:<count>"

    local ps_report_all
    ps_report_all=$(ssh -n "$SSH_ALIAS" '
        apps=$(dokku apps:list 2>/dev/null | tail -n +2)
        for app in $apps; do
            echo "===APP:${app}==="
            dokku ps:report "$app" 2>/dev/null || true
        done
    ' 2>/dev/null || true)
    local report_available=true
    if [ -z "$ps_report_all" ]; then
        report_available=false
    fi

    local deployment
    for deployment in "${FILTERED_DEPLOYMENTS[@]}"; do
        local domain
        domain=$(echo "$deployment" | jq -r '.domain')
        local app_name
        app_name=$(echo "$domain" | tr '.' '-')

        local app_block
        local app_block=""
        if [ "$report_available" = true ]; then
            app_block=$(echo "$ps_report_all" | awk -v app="$app_name" '
                $0 == "===APP:" app "===" { in_block=1; next }
                in_block && /^===APP:/ { exit }
                in_block { print }
            ')
        fi

        if [ -z "$app_block" ]; then
            echo -e "  - ${YELLOW}$domain${NC} | dep:? run:? procs:?"
            continue
        fi

        local deployed_raw
        deployed_raw=$(echo "$app_block" | awk -F': *' '/Deployed:/{print tolower($2); exit}')
        local status_raw
        status_raw=$(echo "$app_block" | awk -F': *' '/Status:/{print tolower($2); exit}')
        local process_count
        process_count=$(echo "$app_block" | awk -F': *' '/Processes:/{print $2; exit}' | awk '{print $1}')
        [ -z "$process_count" ] && process_count="?"

        local run_raw="unknown"
        if [[ "$status_raw" == running* ]]; then
            run_raw="running"
        elif [[ "$status_raw" == stopped* ]] || [[ "$status_raw" == off* ]]; then
            run_raw="stopped"
        fi

        local deployed
        deployed=$(normalize_bool_status "$deployed_raw")
        local running
        running=$(normalize_bool_status "$run_raw")

        local domain_display
        domain_display=$(truncate_for_status "$domain" 34)
        echo "  - $domain_display | dep:$deployed run:$running procs:$process_count"
    done
}

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
    local applied_count=0
    local apply_failed_count=0
    local apply_preview_count=0
    local sync_apply_backup=""

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
                    builder: ($child.builder // $parent.builder // null),
                    postgres: (($child.postgres // $parent.postgres // false) == true or ($child.postgres // $parent.postgres // false) == "true"),
                    letsencrypt: (($child.letsencrypt // $parent.letsencrypt // false) == true or ($child.letsencrypt // $parent.letsencrypt // false) == "true"),
                    ports: (($child.ports // $parent.ports // []) | map(tostring) | sort),
                    storage_mounts: ((($child.storage_mounts // []) + ($parent.storage_mounts // [])) | map(tostring) | sort),
                    docker_options: ((($child.docker_options // []) + ($parent.docker_options // [])) | map(tostring) | sort),
                    extra_domains: ((($child.extra_domains // []) + ($parent.extra_domains // [])) | map(tostring) | sort),
                    dokku_settings: (
                        ((($parent.dokku_settings // {}) * ($child.dokku_settings // {})) // {})
                        | to_entries
                        | map(
                            select(.value | type == "object")
                            | .key as $plugin
                            | (
                                .value
                                | to_entries
                                | map("\($plugin):\(.key)=\(.value|tostring)")
                            )
                        )
                        | add // []
                        | sort
                    )
                }
            }
        ]
    ' "$remote_config" > "$remote_index"

    echo -e "${BLUE}Comparing local config with live Dokku state...${NC}"
    echo ""

    if [ "$SYNC_APPLY" = true ]; then
        if [ "$DRY_RUN" = true ]; then
            echo -e "${YELLOW}SYNC APPLY DRY RUN - Showing what would be patched into config.json${NC}"
            echo ""
        else
            sync_apply_backup="$CONFIG_FILE.sync-bak-$(date +%Y%m%d-%H%M%S)"
            cp "$CONFIG_FILE" "$sync_apply_backup"
            echo -e "${BLUE}Backup created:${NC} $sync_apply_backup"
            echo ""
        fi
    fi

    for deployment in "${FILTERED_DEPLOYMENTS[@]}"; do
        local domain
        domain=$(echo "$deployment" | jq -r '.domain')
        local app_name
        app_name=$(echo "$domain" | tr '.' '-')
        local local_summary
        local_summary=$(echo "$deployment" | jq -c '{
            branch: (.branch // null),
            builder: (.builder // null),
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
            extra_domains: ((.extra_domains // []) | map(tostring) | sort),
            dokku_settings: (
                (.dokku_settings // {})
                | to_entries
                | map(
                    select(.value | type == "object")
                    | .key as $plugin
                    | (
                        .value
                        | to_entries
                        | map("\($plugin):\(.key)=\(.value|tostring)")
                    )
                )
                | add // []
                | sort
            )
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
        # Branch is intentionally excluded from sync drift checks: config branch selects
        # source code branch, while Dokku deploy branch is standardized to master.
        for field in builder postgres letsencrypt ports storage_mounts docker_options extra_domains dokku_settings; do
            local local_val
            local remote_val
            local_val=$(echo "$local_summary" | jq -c ".$field")
            remote_val=$(echo "$remote_summary" | jq -c ".$field")

            # Treat default single http mapping as equivalent to unset ports.
            if [ "$field" = "ports" ]; then
                local_val=$(echo "$local_val" | jq -c '
                    map(tostring)
                    | map(select(test("^http:80:[0-9]+$|^https:443:[0-9]+$") | not))
                    | sort
                ')
                remote_val=$(echo "$remote_val" | jq -c '
                    map(tostring)
                    | map(select(test("^http:80:[0-9]+$|^https:443:[0-9]+$") | not))
                    | sort
                ')
            fi

            # Treat unspecified builder as equivalent to Dokku's default selected builder.
            if [ "$field" = "builder" ]; then
                if [ "$local_val" = "null" ] && { [ "$remote_val" = "null" ] || [ "$remote_val" = "\"herokuish\"" ] || [ "$remote_val" = "\"selected:\"" ] || [ "$remote_val" = "\"selected\"" ]; }; then
                    continue
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

            if [ "$SYNC_APPLY" = true ]; then
                local child_patch
                local diff_fields_json
                local patch_rc
                local post_apply_summary
                local remaining_diff_fields=()
                diff_fields_json=$(printf '%s\n' "${diff_fields[@]}" | jq -R . | jq -s .)
                child_patch=$(sync_apply_summary_to_child_patch "$remote_summary" "$diff_fields_json")
                if [ "$DRY_RUN" = true ]; then
                    echo -e "   ${BLUE}apply${NC}"
                    echo -e "     mode  : dry-run"
                    echo -e "     patch : $child_patch"
                    apply_preview_count=$((apply_preview_count + 1))
                    mismatch_count=$((mismatch_count + 1))
                    sync_ok=false
                else
                    if apply_sync_patch_to_config "$domain" "$child_patch"; then
                        patch_rc=0
                    else
                        patch_rc=$?
                    fi

                    if [ "$patch_rc" -ne 0 ] && [ "$patch_rc" -ne 2 ]; then
                        echo -e "   ${RED}apply${NC}"
                        echo -e "     result: failed to patch local config.json"
                        apply_failed_count=$((apply_failed_count + 1))
                        mismatch_count=$((mismatch_count + 1))
                        sync_ok=false
                        continue
                    fi

                    post_apply_summary=$(get_effective_local_summary_for_domain "$domain")
                    if [ -z "$post_apply_summary" ] || [ "$post_apply_summary" = "null" ]; then
                        echo -e "   ${RED}apply${NC}"
                        echo -e "     result: patch applied but could not re-evaluate effective local config"
                        apply_failed_count=$((apply_failed_count + 1))
                        mismatch_count=$((mismatch_count + 1))
                        sync_ok=false
                        continue
                    fi

                    for field in "${diff_fields[@]}"; do
                        local post_local_val
                        local remote_val
                        post_local_val=$(echo "$post_apply_summary" | jq -c ".$field")
                        remote_val=$(echo "$remote_summary" | jq -c ".$field")

                        # Treat default single http/https mapping as equivalent to unset ports.
                        if [ "$field" = "ports" ]; then
                            post_local_val=$(echo "$post_local_val" | jq -c '
                                map(tostring)
                                | map(select(test("^http:80:[0-9]+$|^https:443:[0-9]+$") | not))
                                | sort
                            ')
                            remote_val=$(echo "$remote_val" | jq -c '
                                map(tostring)
                                | map(select(test("^http:80:[0-9]+$|^https:443:[0-9]+$") | not))
                                | sort
                            ')
                        fi

                        # Treat unspecified builder as equivalent to Dokku default builder.
                        if [ "$field" = "builder" ]; then
                            if [ "$post_local_val" = "null" ] && { [ "$remote_val" = "null" ] || [ "$remote_val" = "\"herokuish\"" ] || [ "$remote_val" = "\"selected:\"" ] || [ "$remote_val" = "\"selected\"" ]; }; then
                                continue
                            fi
                        fi

                        if [ "$field" = "extra_domains" ]; then
                            if extra_domains_match "$post_local_val" "$remote_val"; then
                                continue
                            fi
                        fi

                        if [ "$post_local_val" != "$remote_val" ]; then
                            remaining_diff_fields+=("$field")
                        fi
                    done

                    if [ ${#remaining_diff_fields[@]} -eq 0 ]; then
                        echo -e "   ${GREEN}apply${NC}"
                        if [ "$patch_rc" -eq 0 ]; then
                            echo -e "     result: patched local config.json"
                        else
                            echo -e "     result: no local file change required"
                        fi
                        applied_count=$((applied_count + 1))
                    else
                        echo -e "   ${RED}apply${NC}"
                        echo -e "     result: unresolved drift remains after child-level patch"
                        echo -e "     fields: $(printf '%s\n' "${remaining_diff_fields[@]}" | paste -sd ', ' -)"
                        echo -e "     hint  : move these settings to deployment-level or patch parent block manually"
                        apply_failed_count=$((apply_failed_count + 1))
                        mismatch_count=$((mismatch_count + 1))
                        sync_ok=false
                    fi
                fi
            else
                mismatch_count=$((mismatch_count + 1))
                sync_ok=false
            fi
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

    print_live_status_summary

    echo ""
    if [ "$sync_ok" = true ]; then
        echo -e "${GREEN}Sync check passed: all selected deployments match Dokku state.${NC}"
    else
        echo -e "${YELLOW}Sync check found differences.${NC}"
        echo -e "  Missing on Dokku: ${RED}$missing_count${NC}"
        echo -e "  Config drift:     ${YELLOW}$mismatch_count${NC}"
        echo -e "  Extra on Dokku:   ${YELLOW}$extra_remote_count${NC}"
    fi
    if [ "$SYNC_APPLY" = true ]; then
        if [ "$DRY_RUN" = true ]; then
            echo -e "  Sync apply (dry): ${YELLOW}$apply_preview_count${NC}"
        else
            echo -e "  Sync apply:       ${GREEN}$applied_count${NC} patched, ${RED}$apply_failed_count${NC} failed"
            if [ -n "$sync_apply_backup" ]; then
                echo -e "  Backup file:      ${BLUE}$sync_apply_backup${NC}"
            fi
        fi
    fi

    rm -rf "$compare_tmp_dir"
    [ "$sync_ok" = true ]
}
