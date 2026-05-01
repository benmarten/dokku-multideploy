#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dokku-multideploy-tests.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

SCRIPT_DIR="$TMP_ROOT/workspace"
CONFIG_FILE="$SCRIPT_DIR/config.json"
mkdir -p "$SCRIPT_DIR/.env"
printf '{\"sync\":{\"ignored_keys\":[\"APP_VERSION\",\"GIT_SHA\",\"NUXT_VIEWTLAB_VERSION\"]}}\n' > "$CONFIG_FILE"

# shellcheck source=/dev/null
. "$REPO_ROOT/lib/import_setup.sh"
# shellcheck source=/dev/null
. "$REPO_ROOT/lib/helpers.sh"
# shellcheck source=/dev/null
. "$REPO_ROOT/lib/sync.sh"

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

assert_eq() {
    local expected="$1"
    local actual="$2"
    local message="$3"

    if [ "$expected" != "$actual" ]; then
        fail "$message
expected: $expected
actual:   $actual"
    fi
}

assert_secret() {
    local key="$1"
    if ! is_sensitive_env_key "$key"; then
        fail "expected secret key classification for $key"
    fi
}

assert_public() {
    local key="$1"
    if is_sensitive_env_key "$key"; then
        fail "expected public key classification for $key"
    fi
}

assert_secret "APP_KEYS"
assert_secret "RETRIEVERS_0_GITHUBTOKEN"
assert_secret "CREATE_SUPERUSER"
assert_secret "CRONICLE_Storage__AWS__credentials__secretAccessKey"
assert_secret "GOOGLE_SERVICE_ACCOUNT_B64"
assert_public "NUXT_PUBLIC_SHARED_API_TOKEN"

if ! is_ignored_sync_key "GIT_SHA"; then
    fail "expected config.json sync.ignored_keys to extend ignored keys"
fi

if ! is_ignored_sync_key "GIT_REF"; then
    fail "expected GIT_REF to be ignored by default"
fi

if ! is_ignored_sync_key "GIT_REV"; then
    fail "expected GIT_REV to be ignored by default"
fi

if ! is_ignored_sync_key "NUXT_VIEWTLAB_VERSION"; then
    fail "expected config.json sync.ignored_keys to include NUXT_VIEWTLAB_VERSION"
fi

DOKKU_MULTIDEPLOY_IGNORED_SYNC_KEYS="CUSTOM_BUILD_ID"
export DOKKU_MULTIDEPLOY_IGNORED_SYNC_KEYS
if ! is_ignored_sync_key "custom_build_id"; then
    fail "expected custom ignored sync key override to be honored"
fi
if is_ignored_sync_key "NUXT_VIEWTLAB_VERSION"; then
    fail "expected env override to replace config-driven ignored keys"
fi
if is_ignored_sync_key "GIT_REF"; then
    fail "expected env override to replace default ignored keys"
fi
unset DOKKU_MULTIDEPLOY_IGNORED_SYNC_KEYS

printf '{\"sync\":{\"ignored_keys\":[\"APP_VERSION\",\"GIT_SHA\",\"NUXT_VIEWTLAB_VERSION\"],\"sensitive_keys\":[\"TWITTER_CLIENT_ID\"],\"public_keys\":[\"GOOGLE_CLIENT_ID\"]}}\n' > "$CONFIG_FILE"
assert_secret "TWITTER_CLIENT_ID"
assert_public "GOOGLE_CLIENT_ID"

mkdir -p "$SCRIPT_DIR/.env/_apps"
printf 'GIT_REF=main\nKEEP_SHARED=yes\n' > "$SCRIPT_DIR/.env/_apps/viewtlab-frontend"
printf 'NUXT_VIEWTLAB_VERSION=dev-123\nKEEP_BUILD=yes\n' > "$SCRIPT_DIR/.env/foo.example.build"

summary_json='{"source_dir":"apps/viewtlab-frontend","domain":"foo.example","env_vars":{"APP_VERSION":"dev-123","KEEP_RUNTIME":"yes"},"build_args":{"GIT_SHA":"abc123","KEEP_ARG":"yes"}}'
summary_result="$(enrich_summary_with_file_overlays "$summary_json" "$SCRIPT_DIR" true)"

runtime_json="$(printf '%s' "$summary_result" | jq -c '.env_vars')"
build_json="$(printf '%s' "$summary_result" | jq -c '.build_args')"
assert_eq '{"KEEP_RUNTIME":"yes","KEEP_SHARED":"yes"}' "$runtime_json" "metadata keys should be removed from effective runtime env"
assert_eq '{"KEEP_ARG":"yes","KEEP_BUILD":"yes"}' "$build_json" "metadata keys should be removed from effective build args"

printf 'APP_KEYS=old-app-keys\nSHARED_ONLY=keep-me\n' > "$SCRIPT_DIR/.env/_apps/viewtlab-backend"
printf 'DOMAIN_SECRET=old-domain\n' > "$SCRIPT_DIR/.env/backend.example"

distribution_json="$(distribute_secret_json_by_existing_ownership '{"APP_KEYS":"new-app-keys","DOMAIN_SECRET":"new-domain"}' "$SCRIPT_DIR/.env/_apps/viewtlab-backend" "$SCRIPT_DIR/.env/backend.example")"
shared_distribution="$(printf '%s' "$distribution_json" | jq -c '.shared')"
domain_distribution="$(printf '%s' "$distribution_json" | jq -c '.domain')"

assert_eq '{"APP_KEYS":"new-app-keys","SHARED_ONLY":"keep-me"}' "$shared_distribution" "shared secret ownership should be preserved"
assert_eq '{"DOMAIN_SECRET":"new-domain"}' "$domain_distribution" "domain secret ownership should stay domain-local"

echo "sync_regressions.sh: ok"
