is_sensitive_env_key() {
    local key_upper
    key_upper=$(echo "$1" | tr '[:lower:]' '[:upper:]')

    # Explicitly public frontend/runtime prefixes should stay in config.json
    # even when the suffix contains words like TOKEN or KEY.
    if [[ "$key_upper" =~ ^(NUXT_PUBLIC_|NEXT_PUBLIC_|PUBLIC_|VITE_) ]]; then
        return 1
    fi

    case "$key_upper" in
        APP_KEYS|CREATE_SUPERUSER)
            return 0
            ;;
    esac

    # Keep likely credentials/secrets in .env files instead of config.json.
    if [[ "$key_upper" =~ (^|_)(SECRET|PASSWORD|PASS|PASSWD|TOKEN|PRIVATE|CERT|COOKIE|SESSION|JWT|SIGNING|ENCRYPTION|DSN|CONNECTION_STRING)($|_) ]]; then
        return 0
    fi
    if [[ "$key_upper" =~ (^|_)(API_KEY|ACCESS_KEY|SECRET_KEY|CLIENT_SECRET|PRIVATE_KEY|DB_PASSWORD|DATABASE_PASSWORD)($|_) ]]; then
        return 0
    fi
    # Catch suffix-style keys like GITHUBTOKEN that omit underscore separators.
    if [[ "$key_upper" =~ (TOKEN|SECRET|PASSWORD|PASSWD|JWT|DSN)($|_) ]]; then
        return 0
    fi
    if [[ "$key_upper" =~ (^|_)KEYS?($|_) ]]; then
        return 0
    fi

    return 1
}

ignored_sync_keys_json() {
    local default_keys_json='["GIT_REF","GIT_REV"]'

    if [ -n "${DOKKU_MULTIDEPLOY_IGNORED_SYNC_KEYS:-}" ]; then
        printf '%s' "$DOKKU_MULTIDEPLOY_IGNORED_SYNC_KEYS" | tr ', ' '\n\n' | awk 'NF { print toupper($0) }' | jq -R . | jq -s .
        return
    fi

    if [ -n "${CONFIG_FILE:-}" ] && [ -f "$CONFIG_FILE" ]; then
        local config_keys_json
        config_keys_json=$(jq -c '
            (.sync.ignored_keys // .ignored_sync_keys // [])
            | map(ascii_upcase)
        ' "$CONFIG_FILE" 2>/dev/null || echo "[]")

        jq -cn --argjson defaults "$default_keys_json" --argjson config_keys "$config_keys_json" '
            ($defaults + $config_keys) | unique
        '
        return
    fi

    printf '%s' "$default_keys_json"
}

is_ignored_sync_key() {
    local key_upper
    key_upper=$(echo "$1" | tr '[:lower:]' '[:upper:]')

    printf '%s' "$(ignored_sync_keys_json)" | jq -e --arg key "$key_upper" 'index($key)' > /dev/null 2>&1
}

strip_ignored_sync_keys_json() {
    local input_json="$1"
    local ignored_keys_json
    ignored_keys_json=$(ignored_sync_keys_json)

    printf '%s' "$input_json" | jq -c --argjson ignored "$ignored_keys_json" '
        with_entries(select(.key as $key | ($ignored | index($key) | not)))
    '
}

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

            # Escape single quotes in value by replacing ' with '\''
            # Then wrap in single quotes for safe shell passing through ssh
            local escaped_value="${value//\'/\'\\\'\'}"
            result="$result '${key}=${escaped_value}'"
        fi
    done < "$file"

    echo "$result"
}

parse_env_file_to_json() {
    local file=$1
    local result="{}"

    if [ ! -f "$file" ]; then
        echo "{}"
        return
    fi

    while IFS= read -r line || [ -n "$line" ]; do
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

        if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            local key="${BASH_REMATCH[1]}"
            local value="${BASH_REMATCH[2]}"

            if [[ "$value" =~ ^\"(.*)\"$ ]] || [[ "$value" =~ ^\'(.*)\'$ ]]; then
                value="${BASH_REMATCH[1]}"
            fi

            result=$(printf '%s' "$result" | jq -c --arg key "$key" --arg value "$value" '. + {($key): $value}')
        fi
    done < "$file"

    echo "$result"
}

get_env_value() {
    local file=$1
    local key=$2

    [ ! -f "$file" ] && return 0

    local line
    line=$(grep -E "^${key}=" "$file" 2>/dev/null | tail -n 1 || true)
    [ -z "$line" ] && return 0

    local value="${line#*=}"
    if [[ "$value" =~ ^\"(.*)\"$ ]] || [[ "$value" =~ ^\'(.*)\'$ ]]; then
        value="${BASH_REMATCH[1]}"
    fi
    echo "$value"
}

escape_shell_single_quoted() {
    local value="$1"
    echo "${value//\'/\'\\\'\'}"
}

domain_matches_pattern() {
    local domain="$1"
    local pattern="$2"

    if [[ "$pattern" == \*.* ]]; then
        local base="${pattern#*.}"
        [[ "$domain" == *".${base}" ]]
        return
    fi

    [ "$domain" = "$pattern" ]
}

extra_domains_match() {
    local local_json="$1"
    local remote_json="$2"

    local local_patterns=()
    local remote_domains=()
    local pattern
    local domain

    while IFS= read -r pattern; do
        [ -z "$pattern" ] && continue
        local_patterns+=("$pattern")
    done < <(echo "$local_json" | jq -r '.[]?' 2>/dev/null)

    while IFS= read -r domain; do
        [ -z "$domain" ] && continue
        remote_domains+=("$domain")
    done < <(echo "$remote_json" | jq -r '.[]?' 2>/dev/null)

    # Every remote domain must be covered by local exact or wildcard pattern.
    for domain in "${remote_domains[@]}"; do
        local matched=false
        for pattern in "${local_patterns[@]}"; do
            if domain_matches_pattern "$domain" "$pattern"; then
                matched=true
                break
            fi
        done
        if [ "$matched" = false ]; then
            return 1
        fi
    done

    return 0
}

file_mtime_human() {
    local file="$1"

    if [ ! -f "$file" ]; then
        echo "unknown"
        return
    fi

    # macOS/BSD
    if stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S %Z" "$file" >/dev/null 2>&1; then
        stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S %Z" "$file"
        return
    fi

    # GNU coreutils
    if stat -c "%y" "$file" >/dev/null 2>&1; then
        stat -c "%y" "$file" | cut -d'.' -f1
        return
    fi

    echo "unknown"
}
