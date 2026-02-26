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

backup_app() {
    local deployment=$1
    local backup_dir=$2
    local domain=$(echo "$deployment" | jq -r '.domain')
    local app_name=$(echo "$domain" | tr '.' '-')
    local has_backup=false

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

    # Backup storage (single archive preserving directory structure)
    local storage_base="/var/lib/dokku/data/storage/$app_name"
    if ssh $SSH_ALIAS "[ -d '$storage_base' ]" 2>/dev/null; then
        echo -e "${BLUE}Backing up storage: $storage_base${NC}"
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

    # Restore storage archive if present
    local storage_backup="$restore_dir/${app_name}-storage.tar.xz"
    local storage_base="/var/lib/dokku/data/storage/$app_name"
    if [ -f "$storage_backup" ]; then
        echo -e "${BLUE}Restoring storage: $storage_base${NC}"
        if [ "$DRY_RUN" = true ]; then
            echo -e "${YELLOW}   [DRY RUN] Would restore from $storage_backup${NC}"
        else
            ssh $SSH_ALIAS "sudo mkdir -p '$storage_base'" || true
            if xz -dc "$storage_backup" | ssh $SSH_ALIAS "sudo tar -C '$storage_base' -xf -" >/dev/null; then
                echo -e "${GREEN}   Restored storage for: $app_name${NC}"
            else
                echo -e "${RED}   Failed to restore storage for: $app_name${NC}"
                return 1
            fi
        fi
    fi

    if [ ! -f "$pg_backup" ] && [ ! -f "$storage_backup" ]; then
        echo -e "${YELLOW}No matching restore artifacts for this app${NC}"
    fi
    echo ""
}
