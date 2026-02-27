SKIPPED_MIGRATION_PATHS=()

record_skipped_migration_path() {
    local app_name=$1
    local host_path=$2
    local reason=$3
    SKIPPED_MIGRATION_PATHS+=("$app_name|$host_path|$reason")
}

print_skipped_migration_summary() {
    if [ "${#SKIPPED_MIGRATION_PATHS[@]}" -eq 0 ]; then
        return
    fi

    echo -e "${YELLOW}Manual rsync required for skipped storage paths:${NC}"
    local entry
    for entry in "${SKIPPED_MIGRATION_PATHS[@]}"; do
        local app_name="${entry%%|*}"
        local remainder="${entry#*|}"
        local host_path="${remainder%%|*}"
        local reason="${entry##*|}"
        echo -e "${YELLOW}   - [$app_name] $host_path ($reason)${NC}"
    done
    echo -e "${YELLOW}   Suggested: direct host-to-host rsync for the paths above.${NC}"
    echo ""
}

backup_mysql_services() {
    local backup_dir=$1
    local has_mysql=false

    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}Backing up MySQL services${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    local services
    services=$(ssh $SSH_ALIAS "dokku mysql:list 2>/dev/null | tail -n +2" 2>/dev/null | sed '/^[[:space:]]*$/d' || true)

    if [ -z "$services" ]; then
        echo -e "${YELLOW}No MySQL services found${NC}"
        echo ""
        return 0
    fi

    while IFS= read -r service; do
        [ -z "$service" ] && continue
        has_mysql=true
        local mysql_backup="$backup_dir/${service}.sql.xz"
        echo -e "${BLUE}Backing up MySQL database: $service${NC}"

        if [ "$DRY_RUN" = true ]; then
            echo -e "${YELLOW}   [DRY RUN] Would backup to $mysql_backup${NC}"
        else
            if ssh $SSH_ALIAS "dokku mysql:export $service" 2>/dev/null | xz -9 > "$mysql_backup"; then
                local size=$(du -h "$mysql_backup" | cut -f1)
                echo -e "${GREEN}   Saved: $mysql_backup ($size)${NC}"
            else
                echo -e "${RED}   Failed to backup MySQL service: $service${NC}"
                rm -f "$mysql_backup"
            fi
        fi
    done <<< "$services"

    if [ "$has_mysql" = false ] && [ "$DRY_RUN" = false ]; then
        echo -e "${YELLOW}No MySQL backups created${NC}"
    fi

    echo ""
}

restore_mysql_services() {
    local restore_dir=$1
    local found=false

    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}Restoring MySQL services${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    # Ensure mysql plugin
    if ! ssh $SSH_ALIAS "dokku plugin:list" 2>/dev/null | grep -q "mysql"; then
        echo -e "${YELLOW}MySQL plugin not installed, installing...${NC}"
        ssh $SSH_ALIAS "sudo dokku plugin:install https://github.com/dokku/dokku-mysql.git mysql" || true
    fi

    local file
    for file in "$restore_dir"/*.sql.xz; do
        [ -f "$file" ] || continue
        local service
        service=$(basename "$file" .sql.xz)
        found=true

        echo -e "${BLUE}Restoring MySQL service: $service${NC}"
        if [ "$DRY_RUN" = true ]; then
            echo -e "${YELLOW}   [DRY RUN] Would restore from $file${NC}"
            continue
        fi

        if ! ssh $SSH_ALIAS "dokku mysql:exists $service" 2>/dev/null; then
            echo -e "${BLUE}   Creating missing MySQL service: $service${NC}"
            ssh $SSH_ALIAS "dokku mysql:create $service" || true
        fi

        if xz -dc "$file" | ssh $SSH_ALIAS "dokku mysql:import $service" >/dev/null 2>&1; then
            echo -e "${GREEN}   Restored: $service${NC}"
        else
            echo -e "${YELLOW}   Initial import failed, retrying without GTID_PURGED...${NC}"
            if xz -dc "$file" | sed '/^SET @@GLOBAL.GTID_PURGED=/d' | ssh $SSH_ALIAS "dokku mysql:import $service" >/dev/null; then
                echo -e "${GREEN}   Restored (GTID_PURGED stripped): $service${NC}"
            else
                echo -e "${RED}   Failed to restore MySQL service: $service${NC}"
                return 1
            fi
        fi
    done

    if [ "$found" = false ]; then
        echo -e "${YELLOW}No MySQL backup files (*.sql.xz) found${NC}"
    fi
    echo ""
}

collect_storage_mounts() {
    local deployment_json=$1
    local mounts_json
    mounts_json=$(echo "$deployment_json" | jq -c '.storage_mounts // []')

    local idx=0
    while IFS= read -r item; do
        [ -z "$item" ] && continue

        local mount_spec=""
        local backup_enabled="true"

        if echo "$item" | jq -e 'type=="string"' >/dev/null 2>&1; then
            mount_spec=$(echo "$item" | jq -r '.')
        else
            mount_spec=$(echo "$item" | jq -r '.mount // empty')
            backup_enabled=$(echo "$item" | jq -r 'if has("backup") then (.backup|tostring) else "true" end')
        fi

        [ -z "$mount_spec" ] && continue
        local host_path="${mount_spec%%:*}"
        local container_path="${mount_spec#*:}"
        [ -z "$host_path" ] && continue
        [ "$host_path" = "$container_path" ] && continue

        idx=$((idx+1))
        echo "$idx|$host_path|$backup_enabled"
    done <<< "$(echo "$mounts_json" | jq -c '.[]')"
}

backup_app() {
    local deployment=$1
    local backup_dir=$2
    local domain=$(echo "$deployment" | jq -r '.domain')
    local app_name=$(echo "$domain" | tr '.' '-')
    local has_backup=false
    local backup_max_storage_mb="${BACKUP_MAX_STORAGE_MB:-100}"
    if ! [[ "$backup_max_storage_mb" =~ ^[0-9]+$ ]]; then
        backup_max_storage_mb=100
    fi

    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}Backing up: $domain${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    # Check if app exists
    if ! ssh $SSH_ALIAS "dokku apps:exists $app_name" 2>/dev/null; then
        echo -e "${YELLOW}App $app_name does not exist on Dokku, skipping${NC}"
        echo ""
        return 0
    fi

    # Backup PostgreSQL if linked
    local db_name="${app_name}-db"
    if ssh $SSH_ALIAS "dokku postgres:exists $db_name" 2>/dev/null; then
        echo -e "${BLUE}Backing up PostgreSQL database: $db_name${NC}"
        local db_backup="$backup_dir/${db_name}.dump.xz"

        if [ "$DRY_RUN" = true ]; then
            echo -e "${YELLOW}   [DRY RUN] Would backup to $db_backup${NC}"
        else
            if ssh $SSH_ALIAS "dokku postgres:export $db_name" 2>/dev/null | xz -9 > "$db_backup"; then
                local size=$(du -h "$db_backup" | cut -f1)
                echo -e "${GREEN}   Saved: $db_backup ($size)${NC}"
                has_backup=true
            else
                echo -e "${RED}   Failed to backup database${NC}"
                rm -f "$db_backup"
            fi
        fi
    fi

    # Backup storage mounts from config (honors storage_mounts[].backup=false)
    local storage_mount_entries=""
    storage_mount_entries=$(collect_storage_mounts "$deployment")
    local skipped_disabled_mounts=()
    local skipped_large_mounts=()

    if [ -n "$storage_mount_entries" ]; then
        echo -e "${BLUE}Backing up storage mounts from config${NC}"
        while IFS= read -r entry; do
            [ -z "$entry" ] && continue
            local mount_index="${entry%%|*}"
            local remainder="${entry#*|}"
            local host_path="${remainder%%|*}"
            local backup_enabled="${entry##*|}"

            if [ "$backup_enabled" != "true" ]; then
                skipped_disabled_mounts+=("$host_path")
                record_skipped_migration_path "$app_name" "$host_path" "backup=false"
                continue
            fi

            if ! ssh $SSH_ALIAS "[ -d '$host_path' ]" 2>/dev/null; then
                echo -e "${YELLOW}   Mount source missing on host, skipping: $host_path${NC}"
                continue
            fi

            local mount_size_mb
            mount_size_mb=$(ssh $SSH_ALIAS "du -sm '$host_path' 2>/dev/null | awk '{print \$1}'" 2>/dev/null || true)
            if [ -z "$mount_size_mb" ]; then
                mount_size_mb=0
            fi
            if [ "$backup_max_storage_mb" -gt 0 ] && [ "$mount_size_mb" -gt "$backup_max_storage_mb" ]; then
                skipped_large_mounts+=("$host_path (${mount_size_mb}MB)")
                record_skipped_migration_path "$app_name" "$host_path" "size=${mount_size_mb}MB > ${backup_max_storage_mb}MB"
                continue
            fi

            local storage_backup="$backup_dir/${app_name}-storage-${mount_index}.tar.xz"
            echo -e "${BLUE}   [$mount_index] $host_path${NC}"

            if [ "$DRY_RUN" = true ]; then
                echo -e "${YELLOW}      [DRY RUN] Would backup to $storage_backup${NC}"
            else
                if ssh $SSH_ALIAS "tar -C / -cf - '${host_path#/}'" 2>/dev/null | xz -9 > "$storage_backup"; then
                    local size=$(du -h "$storage_backup" | cut -f1)
                    echo -e "${GREEN}      Saved: $storage_backup ($size)${NC}"
                    has_backup=true
                else
                    echo -e "${RED}      Failed to backup storage mount: $host_path${NC}"
                    rm -f "$storage_backup"
                fi
            fi
        done <<< "$storage_mount_entries"
    else
        # Backward-compatible fallback for configs without storage_mounts
        local storage_base="/var/lib/dokku/data/storage/$app_name"
        if ssh $SSH_ALIAS "[ -d '$storage_base' ]" 2>/dev/null; then
            echo -e "${BLUE}Backing up storage (legacy app directory): $storage_base${NC}"
            local storage_backup="$backup_dir/${app_name}-storage.tar.xz"

            if [ "$DRY_RUN" = true ]; then
                echo -e "${YELLOW}   [DRY RUN] Would backup to $storage_backup${NC}"
            else
                if ssh $SSH_ALIAS "tar -C '$storage_base' -cf - ." 2>/dev/null | xz -9 > "$storage_backup"; then
                    local size=$(du -h "$storage_backup" | cut -f1)
                    echo -e "${GREEN}   Saved: $storage_backup ($size)${NC}"
                    has_backup=true
                else
                    echo -e "${RED}   Failed to backup storage${NC}"
                    rm -f "$storage_backup"
                fi
            fi
        fi
    fi

    if [ "${#skipped_disabled_mounts[@]}" -gt 0 ]; then
        echo -e "${YELLOW}Skipped storage mounts (backup=false):${NC}"
        local skipped
        for skipped in "${skipped_disabled_mounts[@]}"; do
            echo -e "${YELLOW}   - $skipped${NC}"
        done
    fi

    if [ "${#skipped_large_mounts[@]}" -gt 0 ]; then
        echo -e "${YELLOW}Skipped large storage mounts (size > ${backup_max_storage_mb}MB):${NC}"
        local skipped_large
        for skipped_large in "${skipped_large_mounts[@]}"; do
            echo -e "${YELLOW}   - $skipped_large${NC}"
        done
    fi

    if [ "${#skipped_disabled_mounts[@]}" -gt 0 ] || [ "${#skipped_large_mounts[@]}" -gt 0 ]; then
        echo -e "${YELLOW}   Note: migrate skipped paths separately (recommended: direct host-to-host rsync).${NC}"
    fi

    if [ "$has_backup" = false ] && [ "$DRY_RUN" = false ]; then
        echo -e "${YELLOW}No databases or storage mounts to backup${NC}"
    fi

    echo ""
}

restore_app() {
    local deployment=$1
    local restore_dir=$2
    local domain=$(echo "$deployment" | jq -r '.domain')
    local app_name=$(echo "$domain" | tr '.' '-')

    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}Restoring: $domain${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    # Restore Postgres dump if present (by convention: <app>-db.dump.xz)
    local pg_name="${app_name}-db"
    local pg_backup="$restore_dir/${pg_name}.dump.xz"
    if [ -f "$pg_backup" ]; then
        echo -e "${BLUE}Restoring PostgreSQL database: $pg_name${NC}"

        if ! ssh $SSH_ALIAS "dokku plugin:list" 2>/dev/null | grep -q "postgres"; then
            echo -e "${YELLOW}PostgreSQL plugin not installed, installing...${NC}"
            ssh $SSH_ALIAS "sudo dokku plugin:install https://github.com/dokku/dokku-postgres.git postgres" || true
        fi

        if [ "$DRY_RUN" = true ]; then
            echo -e "${YELLOW}   [DRY RUN] Would restore from $pg_backup${NC}"
        else
            if ! ssh $SSH_ALIAS "dokku postgres:exists $pg_name" 2>/dev/null; then
                echo -e "${BLUE}   Creating missing Postgres service: $pg_name${NC}"
                ssh $SSH_ALIAS "dokku postgres:create $pg_name" || true
            fi
            if xz -dc "$pg_backup" | ssh $SSH_ALIAS "dokku postgres:import $pg_name" >/dev/null; then
                echo -e "${GREEN}   Restored: $pg_name${NC}"
            else
                echo -e "${RED}   Failed to restore PostgreSQL database: $pg_name${NC}"
                return 1
            fi
        fi
    fi

    # Restore storage archives from configured mounts
    local restored_any_storage=false
    local matched_storage_artifact=false
    local storage_mount_entries=""
    storage_mount_entries=$(collect_storage_mounts "$deployment")

    if [ -n "$storage_mount_entries" ]; then
        while IFS= read -r entry; do
            [ -z "$entry" ] && continue
            local mount_index="${entry%%|*}"
            local remainder="${entry#*|}"
            local host_path="${remainder%%|*}"
            local backup_enabled="${entry##*|}"
            [ "$backup_enabled" != "true" ] && continue

            local storage_backup="$restore_dir/${app_name}-storage-${mount_index}.tar.xz"
            if [ ! -f "$storage_backup" ]; then
                continue
            fi
            matched_storage_artifact=true

            echo -e "${BLUE}Restoring storage mount [$mount_index]: $host_path${NC}"
            if [ "$DRY_RUN" = true ]; then
                echo -e "${YELLOW}   [DRY RUN] Would restore from $storage_backup${NC}"
            else
                ssh $SSH_ALIAS "sudo mkdir -p '$host_path'" || true
                if xz -dc "$storage_backup" | ssh $SSH_ALIAS "sudo tar -C / -xf -" >/dev/null; then
                    echo -e "${GREEN}   Restored storage mount: $host_path${NC}"
                    restored_any_storage=true
                else
                    echo -e "${RED}   Failed to restore storage mount: $host_path${NC}"
                    return 1
                fi
            fi
        done <<< "$storage_mount_entries"
    fi

    # Backward-compatible restore path for old single-archive backups
    local legacy_storage_backup="$restore_dir/${app_name}-storage.tar.xz"
    local legacy_storage_base="/var/lib/dokku/data/storage/$app_name"
    if [ "$restored_any_storage" = false ] && [ -f "$legacy_storage_backup" ]; then
        matched_storage_artifact=true
        echo -e "${BLUE}Restoring storage (legacy format): $legacy_storage_base${NC}"
        if [ "$DRY_RUN" = true ]; then
            echo -e "${YELLOW}   [DRY RUN] Would restore from $legacy_storage_backup${NC}"
        else
            ssh $SSH_ALIAS "sudo mkdir -p '$legacy_storage_base'" || true
            if xz -dc "$legacy_storage_backup" | ssh $SSH_ALIAS "sudo tar -C '$legacy_storage_base' -xf -" >/dev/null; then
                echo -e "${GREEN}   Restored storage for: $app_name${NC}"
                restored_any_storage=true
            else
                echo -e "${RED}   Failed to restore storage for: $app_name${NC}"
                return 1
            fi
        fi
    fi

    if [ ! -f "$pg_backup" ] && [ "$matched_storage_artifact" = false ]; then
        echo -e "${YELLOW}No matching restore artifacts for this app${NC}"
    fi
    echo ""
}
