storage_transfer_cleanup() {
    local source_ssh="$1"
    local target_ssh="$2"
    local key_dir="$3"
    local marker="$4"

    if [ -n "$source_ssh" ] && [ -n "$marker" ]; then
        ssh "$source_ssh" "marker='$marker'; auth=/root/.ssh/authorized_keys; if [ -f \"\$auth\" ]; then tmp=\$(mktemp); awk -v marker=\"\$marker\" '\$NF != marker { print }' \"\$auth\" > \"\$tmp\" && cat \"\$tmp\" > \"\$auth\" && rm -f \"\$tmp\"; chmod 600 \"\$auth\"; fi" >/dev/null 2>&1 || true
    fi
    if [ -n "$target_ssh" ] && [ -n "$key_dir" ]; then
        ssh "$target_ssh" "rm -rf '$key_dir'" >/dev/null 2>&1 || true
    fi
}

transfer_storage_mounts() {
    local config_file="$1"
    local source_ssh="$2"
    local target_ssh="$3"

    if [ "$source_ssh" = "$target_ssh" ]; then
        echo -e "${RED}Error: source and destination SSH aliases are identical${NC}"
        return 1
    fi
    if ! ssh -o ConnectTimeout=10 "$source_ssh" "echo 'Connection OK'" >/dev/null 2>&1; then
        echo -e "${RED}Cannot connect to storage source $source_ssh${NC}"
        return 1
    fi
    if ! ssh -o ConnectTimeout=10 "$target_ssh" "echo 'Connection OK'" >/dev/null 2>&1; then
        echo -e "${RED}Cannot connect to storage destination $target_ssh${NC}"
        return 1
    fi

    local mount_paths
    mount_paths=$(jq -r '
        [to_entries[]
         | select(.value | type == "object" and has("deployments")) as $group
         | $group.value as $parent
         | $parent.deployments | to_entries[] as $deployment
         | (($parent.storage_mounts // []) + ($deployment.value.storage_mounts // []))[]?
         | (if type == "string" then . else .mount // empty end)
         | split(":")[0]
         | select(startswith("/"))]
        | unique[]
    ' "$config_file") || return 1

    if [ -z "$mount_paths" ]; then
        echo -e "${YELLOW}No absolute storage mount paths found in $config_file${NC}"
        return 0
    fi

    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}   dokku-multideploy - Storage Transfer${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
    echo -e "Source:      $source_ssh"
    echo -e "Destination: $target_ssh"
    echo ""

    # A real transfer is initiated on the destination and pulls from the source.
    # Use an ephemeral key authorized only for the duration of this command so
    # the payload travels directly between the two servers, not through the CLI host.
    local source_host source_user source_port source_known_hosts key_dir key_marker key_pub
    source_host=$(ssh -G "$source_ssh" 2>/dev/null | awk '$1 == "hostname" { print $2; exit }')
    source_user=$(ssh -G "$source_ssh" 2>/dev/null | awk '$1 == "user" { print $2; exit }')
    source_port=$(ssh -G "$source_ssh" 2>/dev/null | awk '$1 == "port" { print $2; exit }')
    [ -n "$source_host" ] && [ -n "$source_user" ] && [ -n "$source_port" ] || {
        echo -e "${RED}Could not resolve SSH connection details for source $source_ssh${NC}"
        return 1
    }

    if [ "$source_port" = "22" ]; then
        source_known_hosts=$(ssh-keygen -F "$source_host" 2>/dev/null | sed '/^#/d')
    else
        source_known_hosts=$(ssh-keygen -F "[$source_host]:$source_port" 2>/dev/null | sed '/^#/d')
    fi
    if [ -z "$source_known_hosts" ]; then
        echo -e "${RED}No pinned SSH host key found locally for source $source_host:$source_port${NC}"
        return 1
    fi

    if [ "$DRY_RUN" = true ]; then
        local dry_path dry_size
        while IFS= read -r dry_path; do
            [ -z "$dry_path" ] && continue
            if ! ssh -n "$source_ssh" "sudo test -d '$dry_path'" >/dev/null 2>&1; then
                echo -e "${YELLOW}Skipping missing source mount: $dry_path${NC}"
                continue
            fi
            dry_size=$(ssh -n "$source_ssh" "sudo du -sh '$dry_path' | awk '{print \$1}'" 2>/dev/null || echo "unknown size")
            echo -e "${BLUE}Would transfer: $dry_path ($dry_size) directly from $source_ssh to $target_ssh${NC}"
        done <<< "$mount_paths"
        echo -e "${GREEN}Storage transfer dry run complete${NC}"
        return 0
    fi

    key_marker="deploy-storage-$(date +%s)-$$"
    key_dir=$(ssh "$target_ssh" "umask 077; mktemp -d /root/.ssh/deploy-storage.XXXXXX") || return 1
    if ! ssh "$target_ssh" "ssh-keygen -q -t ed25519 -N '' -C '$key_marker' -f '$key_dir/id'"; then
        storage_transfer_cleanup "" "$target_ssh" "$key_dir" ""
        echo -e "${RED}Could not create temporary SSH key on destination${NC}"
        return 1
    fi
    key_pub=$(ssh "$target_ssh" "cat '$key_dir/id.pub'") || {
        storage_transfer_cleanup "" "$target_ssh" "$key_dir" ""
        return 1
    }

    if ! printf '%s\n' "$key_pub" | ssh "$source_ssh" 'umask 077; mkdir -p /root/.ssh; touch /root/.ssh/authorized_keys; chmod 600 /root/.ssh/authorized_keys; cat >> /root/.ssh/authorized_keys'; then
        storage_transfer_cleanup "" "$target_ssh" "$key_dir" ""
        echo -e "${RED}Could not authorize temporary transfer key on source${NC}"
        return 1
    fi
    if ! printf '%s\n' "$source_known_hosts" | ssh "$target_ssh" "cat > '$key_dir/known_hosts'; chmod 600 '$key_dir/known_hosts'"; then
        storage_transfer_cleanup "$source_ssh" "$target_ssh" "$key_dir" "$key_marker"
        echo -e "${RED}Could not pin the source SSH host key on destination${NC}"
        return 1
    fi

    local transfer_failed=false mount_path source_size rsync_ssh source_spec
    printf -v rsync_ssh "ssh -i %q -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=%q -p %q" "$key_dir/id" "$key_dir/known_hosts" "$source_port"
    while IFS= read -r mount_path; do
        [ -z "$mount_path" ] && continue
        if ! ssh -n "$source_ssh" "sudo test -d '$mount_path'" >/dev/null 2>&1; then
            echo -e "${YELLOW}Skipping missing source mount: $mount_path${NC}"
            continue
        fi
        source_size=$(ssh -n "$source_ssh" "sudo du -sh '$mount_path' | awk '{print \$1}'" 2>/dev/null || echo "unknown size")
        echo -e "${BLUE}Transferring directly: $mount_path ($source_size)${NC}"
        source_spec="$source_user@$source_host:$mount_path"
        if [[ "$mount_path" != */ ]]; then
            source_spec="$source_spec/"
        fi
        if ! ssh -n "$target_ssh" "sudo mkdir -p '$mount_path' && sudo rsync -aHAXS --numeric-ids --delete --partial --info=stats2 -e '$rsync_ssh' --rsync-path='sudo rsync' '$source_spec' '$mount_path/'"; then
            echo -e "${RED}Failed to transfer mount: $mount_path${NC}"
            transfer_failed=true
        fi
    done <<< "$mount_paths"

    storage_transfer_cleanup "$source_ssh" "$target_ssh" "$key_dir" "$key_marker"
    if [ "$transfer_failed" = true ]; then
        echo -e "${RED}Storage transfer finished with errors${NC}"
        return 1
    fi
    echo -e "${GREEN}Storage transfer complete${NC}"
}
