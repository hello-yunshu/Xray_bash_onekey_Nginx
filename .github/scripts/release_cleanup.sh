#!/usr/bin/env bash
# Release cleanup decision logic for Nginx build releases.
# Protects online/tested/current versions from deletion.
#
# This script is intended to be SOURCED by the workflow and the test suite.
# It exposes pure functions for testability.
#
# Fail-closed principle: if the API is unreachable, JSON is invalid, or
# required fields are empty, NO releases are deleted.

# Default API URLs (can be overridden via env for testing)
API_XRAY_SHELL_VERSIONS_URL="${API_XRAY_SHELL_VERSIONS_URL:-https://raw.githubusercontent.com/hello-yunshu/Xray_bash_onekey_api/main/xray_shell_versions.json}"
API_TESTED_VERSIONS_URL="${API_TESTED_VERSIONS_URL:-https://raw.githubusercontent.com/hello-yunshu/Xray_bash_onekey_api/main/tested_versions.json}"
CURL_BIN="${CURL_BIN:-curl}"
JQ_BIN="${JQ_BIN:-jq}"

# Parse protected versions from API JSON payloads.
#
# Args:
#   $1: xray_shell_versions.json content (must contain nginx_build_online_version
#       and nginx_build_tested_version)
#   $2: tested_versions.json content (must contain nginx_build for cross-check)
#   $3: current_build_version (may be empty)
#
# Outputs: lines of "v<version>" (deduplicated) to stdout
# Returns: 0 on success, 1 on failure (fail-closed)
#
# Fail-closed conditions:
#   - Either JSON payload is not valid JSON
#   - nginx_build_online_version is empty or null
#   - nginx_build_tested_version is empty or null
#   - Cross-check: tested_versions.json nginx_build (if present) differs from
#     nginx_build_tested_version
parse_protected_versions() {
  local xray_shell_json="$1"
  local tested_json="$2"
  local current_build_version="${3:-}"

  # Validate JSON payloads
  if ! printf '%s' "$xray_shell_json" | "$JQ_BIN" -e . >/dev/null 2>&1; then
    echo "ERROR: xray_shell_versions.json is not valid JSON" >&2
    return 1
  fi
  if ! printf '%s' "$tested_json" | "$JQ_BIN" -e . >/dev/null 2>&1; then
    echo "ERROR: tested_versions.json is not valid JSON" >&2
    return 1
  fi
  if [ "$(printf '%s' "$xray_shell_json" | "$JQ_BIN" -r 'type')" != "object" ] ||
     [ "$(printf '%s' "$tested_json" | "$JQ_BIN" -r 'type')" != "object" ]; then
    echo "ERROR: API version payloads must be JSON objects" >&2
    return 1
  fi

  local online_version tested_version tested_cross_version
  online_version=$(printf '%s' "$xray_shell_json" | "$JQ_BIN" -r '.nginx_build_online_version // ""')
  tested_version=$(printf '%s' "$xray_shell_json" | "$JQ_BIN" -r '.nginx_build_tested_version // ""')
  tested_cross_version=$(printf '%s' "$tested_json" | "$JQ_BIN" -r '.nginx_build // ""')

  # Fail closed if required fields are empty or null
  if [ -z "$online_version" ] || [ "$online_version" = "null" ]; then
    echo "ERROR: nginx_build_online_version is empty or null" >&2
    return 1
  fi
  if [ -z "$tested_version" ] || [ "$tested_version" = "null" ]; then
    echo "ERROR: nginx_build_tested_version is empty or null" >&2
    return 1
  fi

  if [ -z "$tested_cross_version" ] || [ "$tested_cross_version" = "null" ]; then
    echo "ERROR: tested_versions.json nginx_build is empty or null" >&2
    return 1
  fi

  local version
  for version in "$online_version" "$tested_version" "$tested_cross_version"; do
    if ! printf '%s' "$version" | grep -qE '^[0-9]{4}\.[0-9]{2}\.[0-9]{2}(\.[0-9]+)?$'; then
      echo "ERROR: invalid nginx build version format: $version" >&2
      return 1
    fi
  done
  if [ -n "$current_build_version" ] &&
     ! printf '%s' "$current_build_version" | grep -qE '^[0-9]{4}\.[0-9]{2}\.[0-9]{2}(\.[0-9]+)?$'; then
    echo "ERROR: invalid current build version format: $current_build_version" >&2
    return 1
  fi

  if [ "$tested_cross_version" != "$tested_version" ]; then
    echo "ERROR: tested version mismatch: xray_shell_versions=$tested_version tested_versions=$tested_cross_version" >&2
    return 1
  fi

  # Build deduplicated protected list (raw versions, no v prefix)
  local raw_versions="$online_version $tested_version"
  if [ -n "$current_build_version" ]; then
    raw_versions="$raw_versions $current_build_version"
  fi

  local seen=""
  for v in $raw_versions; do
    [ -z "$v" ] && continue
    local already=0
    for s in $seen; do
      if [ "$s" = "$v" ]; then
        already=1
        break
      fi
    done
    if [ $already -eq 0 ]; then
      seen="$seen $v"
      printf 'v%s\n' "$v"
    fi
  done

  return 0
}

# Fetch protected versions from API.
#
# Args:
#   $1: current_build_version (may be empty)
#
# Outputs: lines of "v<version>" to stdout
# Returns: 0 on success, 1 on failure (fail-closed)
fetch_protected_versions() {
  local current_build_version="${1:-}"

  local xray_shell_json tested_json
  xray_shell_json=$("$CURL_BIN" -fsS --max-time 20 "$API_XRAY_SHELL_VERSIONS_URL" 2>/dev/null) || {
    echo "ERROR: failed to fetch $API_XRAY_SHELL_VERSIONS_URL" >&2
    return 1
  }
  tested_json=$("$CURL_BIN" -fsS --max-time 20 "$API_TESTED_VERSIONS_URL" 2>/dev/null) || {
    echo "ERROR: failed to fetch $API_TESTED_VERSIONS_URL" >&2
    return 1
  }

  parse_protected_versions "$xray_shell_json" "$tested_json" "$current_build_version"
}

# Build a JSON array from a space/newline-separated list of tags.
_tags_to_json_array() {
  local tags="$1"
  if [ -z "$tags" ]; then
    printf '[]'
    return 0
  fi
  printf '%s\n' $tags | grep -v '^$' | "$JQ_BIN" -R . | "$JQ_BIN" -s . 2>/dev/null || printf '[]'
}

# Compute the full cleanup plan (kept + deleted) for logging.
#
# Args:
#   $1: releases JSON (array of objects with .id, .tag_name, .created_at)
#   $2: protected tags (space/newline-separated, with v prefix)
#   $3: keep_count (default 5)
#
# Outputs: JSON array of {id, tag_name, created_at, reason} to stdout
#   reason is one of: "protected", "keep-recent", "delete-old"
# Returns: 0 on success, 1 on failure
compute_release_plan() {
  local releases_json="$1"
  local protected_tags="$2"
  local keep_count="${3:-5}"

  if ! printf '%s' "$releases_json" | "$JQ_BIN" -e . >/dev/null 2>&1; then
    echo "ERROR: releases JSON is not valid" >&2
    return 1
  fi

  local protected_array
  protected_array=$(_tags_to_json_array "$protected_tags")

  printf '%s' "$releases_json" | "$JQ_BIN" -c \
    --argjson protected "$protected_array" \
    --argjson keep "$keep_count" '
    sort_by(.created_at) | reverse |
    reduce .[] as $release (
      {ordinary_kept: 0, plan: []};
      if (($release.tag_name as $tag | $protected | index($tag)) != null) then
        .plan += [$release + {reason: "protected"}]
      elif .ordinary_kept < $keep then
        .ordinary_kept += 1 |
        .plan += [$release + {reason: "keep-recent"}]
      else
        .plan += [$release + {reason: "delete-old"}]
      end
    ) | .plan | map({id, tag_name, created_at, reason})
  '
}

# Compute which releases to delete.
#
# Args:
#   $1: releases JSON (array of objects with .id, .tag_name, .created_at)
#   $2: protected tags (space/newline-separated, with v prefix)
#   $3: keep_count (default 5)
#
# Outputs: JSON array of {id, tag_name, created_at, reason} to stdout
#   Only releases with reason "delete-old" are included.
# Returns: 0 on success, 1 on failure
compute_releases_to_delete() {
  local releases_json="$1"
  local protected_tags="$2"
  local keep_count="${3:-5}"

  local plan
  plan=$(compute_release_plan "$releases_json" "$protected_tags" "$keep_count") || return 1
  printf '%s' "$plan" | "$JQ_BIN" -c 'map(select(.reason == "delete-old"))'
}

# Validate HTTP status code returned by a DELETE request to the GitHub API.
#
# Args:
#   $1: HTTP status code (3-digit string from curl -w "%{http_code}")
#
# Returns: 0 if the deletion is acceptable, 1 if fail-closed
#
# Acceptable codes:
#   204 - successfully deleted
#   404 - resource already gone (idempotent success)
#
# Fail-closed codes (must NOT be treated as success):
#   401 - unauthorized (token issue)
#   403 - forbidden (permissions / abuse)
#   429 - rate limited
#   5xx - server error
#   000 - connection failure / no response
#   anything else - unexpected
validate_delete_response() {
  local http_code="$1"
  case "$http_code" in
    204|404)
      return 0
      ;;
    401)
      echo "ERROR: DELETE failed with 401 Unauthorized" >&2
      return 1
      ;;
    403)
      echo "ERROR: DELETE failed with 403 Forbidden" >&2
      return 1
      ;;
    429)
      echo "ERROR: DELETE failed with 429 Too Many Requests" >&2
      return 1
      ;;
    5[0-9][0-9])
      echo "ERROR: DELETE failed with $http_code (server error)" >&2
      return 1
      ;;
    *)
      echo "ERROR: DELETE returned unexpected status code: $http_code" >&2
      return 1
      ;;
  esac
}

# Validate HTTP status code returned by a GET request verifying that a
# protected resource (tag or release) still exists after cleanup.
#
# Args:
#   $1: HTTP status code (3-digit string from curl -w "%{http_code}")
#
# Returns: 0 if the resource exists (200), 1 otherwise (fail-closed)
validate_protected_exists() {
  local http_code="$1"
  if [ "$http_code" = "200" ]; then
    return 0
  fi
  echo "ERROR: protected resource verification failed (HTTP $http_code)" >&2
  return 1
}
