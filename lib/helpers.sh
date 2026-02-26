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
