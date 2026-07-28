#!/usr/bin/env bash
# Tests for release_cleanup.sh
# Run: bash .github/test/test_release_cleanup.sh
#
# Requirements: bash 3.2+, jq
# Compatible with macOS (BSD sed, bash 3.2, no mapfile/readarray)
#
# Tests use fixture data (local variables) to simulate Release lists and API
# responses. No real GitHub API calls are made.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_SCRIPT="$SCRIPT_DIR/../scripts/release_cleanup.sh"

# Check dependencies
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required but not found. Install with: brew install jq" >&2
  exit 1
fi

if [ ! -f "$SOURCE_SCRIPT" ]; then
  echo "ERROR: source script not found: $SOURCE_SCRIPT" >&2
  exit 1
fi

# Colors (disable if not a TTY)
if [ -t 1 ]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[0;33m'
  NC='\033[0m'
else
  RED=''
  GREEN=''
  YELLOW=''
  NC=''
fi

PASS=0
FAIL=0

pass() {
  PASS=$((PASS + 1))
  printf "${GREEN}PASS${NC}: %s\n" "$1"
}

fail() {
  FAIL=$((FAIL + 1))
  printf "${RED}FAIL${NC}: %s\n" "$1"
  shift
  while [ $# -gt 0 ]; do
    printf "       %s\n" "$1"
    shift
  done
}

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    pass "$name"
  else
    fail "$name" "expected: $expected" "actual:   $actual"
  fi
}

assert_contains() {
  local name="$1" needle="$2" haystack="$3"
  if printf '%s' "$haystack" | grep -qF "$needle"; then
    pass "$name"
  else
    fail "$name" "expected to contain: $needle" "actual: $haystack"
  fi
}

assert_not_contains() {
  local name="$1" needle="$2" haystack="$3"
  if printf '%s' "$haystack" | grep -qF "$needle"; then
    fail "$name" "should NOT contain: $needle" "actual: $haystack"
  else
    pass "$name"
  fi
}

assert_fail_closed() {
  local name="$1" exit_code="$2" stdout="$3"
  if [ "$exit_code" -ne 0 ]; then
    if [ -z "$stdout" ]; then
      pass "$name (exit=$exit_code, empty stdout)"
    else
      fail "$name" "exit=$exit_code but stdout is non-empty: $stdout"
    fi
  else
    fail "$name" "expected non-zero exit but got 0"
  fi
}

# --- Source the script under test ---
# shellcheck source=../scripts/release_cleanup.sh
source "$SOURCE_SCRIPT"

# ============================================================================
# Fixture data
# ============================================================================

FIXTURE_XRAY_SHELL='{
  "nginx_build_online_version": "2026.07.15.6961",
  "nginx_build_tested_version": "2025.12.23",
  "nginx_online_version": "1.30.4",
  "shell_online_version": "3.0.1"
}'

FIXTURE_TESTED='{
  "shell": "2.8.3",
  "xray": "25.12.8",
  "nginx": "1.28.1",
  "nginx_build": "2025.12.23"
}'

FIXTURE_HTML='<html><head><title>404 Not Found</title></head><body>Not Found</body></html>'

# Generate releases JSON from tag arguments.
# First argument = newest release. Each subsequent = 1 day older.
# Output: JSON array of {id, tag_name, created_at}
make_releases() {
  local result='[]'
  local idx=0
  for tag in "$@"; do
    local day=$((31 - idx))
    local day_padded
    day_padded=$(printf '%02d' "$day")
    result=$(printf '%s' "$result" | jq -c --argjson id "$((idx + 1))" --arg tag "$tag" \
      --arg ts "2026-01-${day_padded}T00:00:00Z" \
      '. + [{id: $id, tag_name: $tag, created_at: $ts}]')
    idx=$((idx + 1))
  done
  printf '%s' "$result"
}

# Mock curl functions for fetch_protected_versions tests
mock_curl_fail() {
  return 1
}

mock_curl_html() {
  printf '%s' "$FIXTURE_HTML"
}

mock_curl_valid() {
  for arg in "$@"; do
    case "$arg" in
      */xray_shell_versions.json)
        printf '%s' "$FIXTURE_XRAY_SHELL"
        return 0
        ;;
      */tested_versions.json)
        printf '%s' "$FIXTURE_TESTED"
        return 0
        ;;
    esac
  done
  return 1
}

# ============================================================================
# Tests for parse_protected_versions
# ============================================================================

echo ""
echo "=== Testing parse_protected_versions ==="
echo ""

# Test 1: Normal valid input
OUTPUT=$(parse_protected_versions "$FIXTURE_XRAY_SHELL" "$FIXTURE_TESTED" "2026.07.28.7000")
EXIT_CODE=$?
assert_eq "T01: normal input - exit code" "0" "$EXIT_CODE"
assert_contains "T01: normal input - online" "v2026.07.15.6961" "$OUTPUT"
assert_contains "T01: normal input - tested" "v2025.12.23" "$OUTPUT"
assert_contains "T01: normal input - current build" "v2026.07.28.7000" "$OUTPUT"

# Test 2: tested is empty string
BAD_JSON_EMPTY_TESTED='{"nginx_build_online_version": "2026.07.15.6961", "nginx_build_tested_version": ""}'
OUTPUT=$(parse_protected_versions "$BAD_JSON_EMPTY_TESTED" "$FIXTURE_TESTED" "" 2>/dev/null)
EXIT_CODE=$?
assert_fail_closed "T02: tested empty string" "$EXIT_CODE" "$OUTPUT"

# Test 3: tested is null
BAD_JSON_NULL_TESTED='{"nginx_build_online_version": "2026.07.15.6961", "nginx_build_tested_version": null}'
OUTPUT=$(parse_protected_versions "$BAD_JSON_NULL_TESTED" "$FIXTURE_TESTED" "" 2>/dev/null)
EXIT_CODE=$?
assert_fail_closed "T03: tested null" "$EXIT_CODE" "$OUTPUT"

# Test 4: tested field missing entirely
BAD_JSON_MISSING_TESTED='{"nginx_build_online_version": "2026.07.15.6961"}'
OUTPUT=$(parse_protected_versions "$BAD_JSON_MISSING_TESTED" "$FIXTURE_TESTED" "" 2>/dev/null)
EXIT_CODE=$?
assert_fail_closed "T04: tested missing" "$EXIT_CODE" "$OUTPUT"

# Test 5: online is empty
BAD_JSON_EMPTY_ONLINE='{"nginx_build_online_version": "", "nginx_build_tested_version": "2025.12.23"}'
OUTPUT=$(parse_protected_versions "$BAD_JSON_EMPTY_ONLINE" "$FIXTURE_TESTED" "" 2>/dev/null)
EXIT_CODE=$?
assert_fail_closed "T05: online empty" "$EXIT_CODE" "$OUTPUT"

# Test 6: API returns HTML (xray_shell_versions.json)
OUTPUT=$(parse_protected_versions "$FIXTURE_HTML" "$FIXTURE_TESTED" "" 2>/dev/null)
EXIT_CODE=$?
assert_fail_closed "T06: HTML xray_shell response" "$EXIT_CODE" "$OUTPUT"

# Test 7: API returns HTML (tested_versions.json)
OUTPUT=$(parse_protected_versions "$FIXTURE_XRAY_SHELL" "$FIXTURE_HTML" "" 2>/dev/null)
EXIT_CODE=$?
assert_fail_closed "T07: HTML tested response" "$EXIT_CODE" "$OUTPUT"

# Test 8: Cross-check mismatch between two API files
BAD_TESTED_MISMATCH='{"nginx_build": "2024.01.01"}'
OUTPUT=$(parse_protected_versions "$FIXTURE_XRAY_SHELL" "$BAD_TESTED_MISMATCH" "" 2>/dev/null)
EXIT_CODE=$?
assert_fail_closed "T08: cross-check mismatch" "$EXIT_CODE" "$OUTPUT"

# Test 9: online == tested (same version, should deduplicate)
SAME_VERSION_JSON='{"nginx_build_online_version": "2025.12.23", "nginx_build_tested_version": "2025.12.23"}'
OUTPUT=$(parse_protected_versions "$SAME_VERSION_JSON" "$FIXTURE_TESTED" "")
EXIT_CODE=$?
assert_eq "T09: online==tested - exit code" "0" "$EXIT_CODE"
TAG_COUNT=$(printf '%s\n' "$OUTPUT" | grep -c '^v' || true)
assert_eq "T09: online==tested - deduplicated count" "1" "$TAG_COUNT"

# Test 10: current_build_version is empty (still works)
OUTPUT=$(parse_protected_versions "$FIXTURE_XRAY_SHELL" "$FIXTURE_TESTED" "")
EXIT_CODE=$?
assert_eq "T10: empty current build - exit code" "0" "$EXIT_CODE"
assert_contains "T10: empty current build - online" "v2026.07.15.6961" "$OUTPUT"
assert_contains "T10: empty current build - tested" "v2025.12.23" "$OUTPUT"

# Test 11: all three versions are the same (dedup to 1)
ALL_SAME_JSON='{"nginx_build_online_version": "2025.12.23", "nginx_build_tested_version": "2025.12.23"}'
OUTPUT=$(parse_protected_versions "$ALL_SAME_JSON" "$FIXTURE_TESTED" "2025.12.23")
EXIT_CODE=$?
assert_eq "T11: all same - exit code" "0" "$EXIT_CODE"
TAG_COUNT=$(printf '%s\n' "$OUTPUT" | grep -c '^v' || true)
assert_eq "T11: all same - deduplicated count" "1" "$TAG_COUNT"

# Test 12: invalid JSON (truncated)
BAD_JSON_TRUNCED='{"nginx_build_online_version": "2026.07.15.6961", "nginx_build_tes'
OUTPUT=$(parse_protected_versions "$BAD_JSON_TRUNCED" "$FIXTURE_TESTED" "" 2>/dev/null)
EXIT_CODE=$?
assert_fail_closed "T12: truncated JSON" "$EXIT_CODE" "$OUTPUT"

BAD_TESTED_MISSING='{"shell": "2.8.3"}'
OUTPUT=$(parse_protected_versions "$FIXTURE_XRAY_SHELL" "$BAD_TESTED_MISSING" "" 2>/dev/null)
EXIT_CODE=$?
assert_fail_closed "T12b: tested cross-check field missing" "$EXIT_CODE" "$OUTPUT"

BAD_JSON_FORMAT='{"nginx_build_online_version": "../../escape", "nginx_build_tested_version": "2025.12.23"}'
OUTPUT=$(parse_protected_versions "$BAD_JSON_FORMAT" "$FIXTURE_TESTED" "" 2>/dev/null)
EXIT_CODE=$?
assert_fail_closed "T12c: invalid build version format" "$EXIT_CODE" "$OUTPUT"

# ============================================================================
# Tests for fetch_protected_versions (fail-closed behavior)
# ============================================================================

echo ""
echo "=== Testing fetch_protected_versions (fail-closed) ==="
echo ""

# Test 13: curl fails (API unreachable)
OUTPUT=$(CURL_BIN=mock_curl_fail fetch_protected_versions "2026.07.28.7000" 2>/dev/null)
EXIT_CODE=$?
assert_fail_closed "T13: curl fails (API unreachable)" "$EXIT_CODE" "$OUTPUT"

# Test 14: curl returns HTML
OUTPUT=$(CURL_BIN=mock_curl_html fetch_protected_versions "" 2>/dev/null)
EXIT_CODE=$?
assert_fail_closed "T14: curl returns HTML" "$EXIT_CODE" "$OUTPUT"

# Test 15: curl succeeds with valid JSON (success path)
OUTPUT=$(CURL_BIN=mock_curl_valid fetch_protected_versions "2026.07.28.7000")
EXIT_CODE=$?
assert_eq "T15: mock curl valid - exit code" "0" "$EXIT_CODE"
assert_contains "T15: mock curl valid - online" "v2026.07.15.6961" "$OUTPUT"
assert_contains "T15: mock curl valid - tested" "v2025.12.23" "$OUTPUT"
assert_contains "T15: mock curl valid - current" "v2026.07.28.7000" "$OUTPUT"

# ============================================================================
# Tests for compute_releases_to_delete
# ============================================================================

echo ""
echo "=== Testing compute_releases_to_delete ==="
echo ""

# Test 16: tested is the newest version (should not be deleted)
# 6 releases, keep=5. Only tested (v2025.12.23) is protected.
# Index 0: tested -> protected. Index 1-4: keep-recent. Index 5: delete-old.
RELEASES=$(make_releases "v2025.12.23" "v2025.12.20" "v2025.12.18" "v2025.12.15" "v2025.12.10" "v2025.12.05")
PROTECTED="v2026.07.15.6961 v2025.12.23 v2026.07.28.7000"
TO_DELETE=$(compute_releases_to_delete "$RELEASES" "$PROTECTED" "5")
EXIT_CODE=$?
assert_eq "T16: tested newest - exit code" "0" "$EXIT_CODE"
DELETE_COUNT=$(printf '%s' "$TO_DELETE" | jq 'length')
assert_eq "T16: tested newest - delete count" "0" "$DELETE_COUNT"
assert_not_contains "T16: tested newest - tested not in delete list" "v2025.12.23" "$TO_DELETE"

# Test 17: tested is 6th oldest (position 5, 0-indexed) - should be protected
# 8 releases total, keep=5. Tested at index 5 (after sort by created_at desc).
# Protected: online + tested + current.
# Index 0-1: protected (current + online)
# Index 2-4: keep-recent
# Index 5: tested -> protected
# Index 6-7: delete-old
RELEASES=$(make_releases \
  "v2026.07.28.7000" \
  "v2026.07.15.6961" \
  "v2026.07.10.6900" \
  "v2026.07.05.6800" \
  "v2026.06.28.6700" \
  "v2025.12.23" \
  "v2025.12.20" \
  "v2025.12.18")
PROTECTED="v2026.07.15.6961 v2025.12.23 v2026.07.28.7000"
TO_DELETE=$(compute_releases_to_delete "$RELEASES" "$PROTECTED" "5")
EXIT_CODE=$?
assert_eq "T17: tested 6th - exit code" "0" "$EXIT_CODE"
assert_not_contains "T17: tested 6th - tested not deleted" "v2025.12.23" "$TO_DELETE"
DELETE_COUNT=$(printf '%s' "$TO_DELETE" | jq 'length')
assert_eq "T17: tested 6th - delete count" "0" "$DELETE_COUNT"

# Test 18: tested is 10th oldest - should be protected
# 12 releases, keep=5. Protected at indices 0,1 (current+online) and 9 (tested).
# Protected: 3. Keep-recent: 3 (indices 2,3,4). Delete-old: 12-3-3=6.
RELEASES=$(make_releases \
  "v2026.07.28.7000" \
  "v2026.07.15.6961" \
  "v2026.07.10.6900" \
  "v2026.07.05.6800" \
  "v2026.06.28.6700" \
  "v2026.06.20.6600" \
  "v2026.06.15.6500" \
  "v2026.06.10.6400" \
  "v2026.06.05.6300" \
  "v2025.12.23" \
  "v2025.12.20" \
  "v2025.12.18")
PROTECTED="v2026.07.15.6961 v2025.12.23 v2026.07.28.7000"
TO_DELETE=$(compute_releases_to_delete "$RELEASES" "$PROTECTED" "5")
EXIT_CODE=$?
assert_eq "T18: tested 10th - exit code" "0" "$EXIT_CODE"
assert_not_contains "T18: tested 10th - tested not deleted" "v2025.12.23" "$TO_DELETE"
DELETE_COUNT=$(printf '%s' "$TO_DELETE" | jq 'length')
assert_eq "T18: tested 10th - delete count" "4" "$DELETE_COUNT"
assert_contains "T18: tested 10th - deletes v2025.12.20" "v2025.12.20" "$TO_DELETE"
assert_contains "T18: tested 10th - deletes v2025.12.18" "v2025.12.18" "$TO_DELETE"

# Test 19: tested is 20th oldest - should be protected
# 22 releases, keep=5. Protected at indices 0,1 (current+online) and 19 (tested).
# Protected: 3. Keep-recent: 3 (indices 2,3,4). Delete-old: 22-3-3=16.
RELEASES=$(make_releases \
  "v2026.07.28.7000" \
  "v2026.07.15.6961" \
  "v2026.07.10.6900" \
  "v2026.07.05.6800" \
  "v2026.06.28.6700" \
  "v2026.06.20.6600" \
  "v2026.06.15.6500" \
  "v2026.06.10.6400" \
  "v2026.06.05.6300" \
  "v2026.05.28.6200" \
  "v2026.05.20.6100" \
  "v2026.05.15.6000" \
  "v2026.05.10.5900" \
  "v2026.05.05.5800" \
  "v2026.04.28.5700" \
  "v2026.04.20.5600" \
  "v2026.04.15.5500" \
  "v2026.04.10.5400" \
  "v2026.04.05.5300" \
  "v2025.12.23" \
  "v2025.12.20" \
  "v2025.12.18")
PROTECTED="v2026.07.15.6961 v2025.12.23 v2026.07.28.7000"
TO_DELETE=$(compute_releases_to_delete "$RELEASES" "$PROTECTED" "5")
EXIT_CODE=$?
assert_eq "T19: tested 20th - exit code" "0" "$EXIT_CODE"
assert_not_contains "T19: tested 20th - tested not deleted" "v2025.12.23" "$TO_DELETE"
DELETE_COUNT=$(printf '%s' "$TO_DELETE" | jq 'length')
assert_eq "T19: tested 20th - delete count" "14" "$DELETE_COUNT"

# Test 20: Release count below threshold (3 < 5, delete none)
RELEASES=$(make_releases "v2026.07.28.7000" "v2026.07.15.6961" "v2025.12.23")
PROTECTED="v2026.07.15.6961 v2025.12.23 v2026.07.28.7000"
TO_DELETE=$(compute_releases_to_delete "$RELEASES" "$PROTECTED" "5")
EXIT_CODE=$?
assert_eq "T20: below threshold - exit code" "0" "$EXIT_CODE"
DELETE_COUNT=$(printf '%s' "$TO_DELETE" | jq 'length')
assert_eq "T20: below threshold - delete count" "0" "$DELETE_COUNT"

# Test 21: Release count exactly at threshold (5 == 5, delete none)
RELEASES=$(make_releases "v2026.07.28.7000" "v2026.07.15.6961" "v2026.07.10.6900" "v2026.07.05.6800" "v2025.12.23")
PROTECTED="v2026.07.15.6961 v2025.12.23 v2026.07.28.7000"
TO_DELETE=$(compute_releases_to_delete "$RELEASES" "$PROTECTED" "5")
EXIT_CODE=$?
assert_eq "T21: at threshold - exit code" "0" "$EXIT_CODE"
DELETE_COUNT=$(printf '%s' "$TO_DELETE" | jq 'length')
assert_eq "T21: at threshold - delete count" "0" "$DELETE_COUNT"

# Test 22: protected release/tag never enters delete list
# 10 releases, all non-protected except tested at position 7
RELEASES=$(make_releases \
  "v2026.07.28.7000" \
  "v2026.07.15.6961" \
  "v2026.07.10.6900" \
  "v2026.07.05.6800" \
  "v2026.06.28.6700" \
  "v2026.06.20.6600" \
  "v2025.12.23" \
  "v2025.12.20" \
  "v2025.12.18" \
  "v2025.12.15")
PROTECTED="v2026.07.15.6961 v2025.12.23 v2026.07.28.7000"
TO_DELETE=$(compute_releases_to_delete "$RELEASES" "$PROTECTED" "5")
EXIT_CODE=$?
assert_eq "T22: protected never deleted - exit code" "0" "$EXIT_CODE"
assert_not_contains "T22: online not in delete list" "v2026.07.15.6961" "$TO_DELETE"
assert_not_contains "T22: tested not in delete list" "v2025.12.23" "$TO_DELETE"
assert_not_contains "T22: current not in delete list" "v2026.07.28.7000" "$TO_DELETE"

# Test 23: normal old versions enter delete list per policy
RELEASES=$(make_releases \
  "v2026.07.28.7000" \
  "v2026.07.15.6961" \
  "v2026.07.10.6900" \
  "v2026.07.05.6800" \
  "v2026.06.28.6700" \
  "v2026.06.20.6600" \
  "v2025.12.23" \
  "v2025.12.20" \
  "v2025.12.18")
PROTECTED="v2026.07.15.6961 v2025.12.23 v2026.07.28.7000"
TO_DELETE=$(compute_releases_to_delete "$RELEASES" "$PROTECTED" "5")
EXIT_CODE=$?
assert_eq "T23: normal old versions - exit code" "0" "$EXIT_CODE"
assert_contains "T23: deletes v2025.12.18" "v2025.12.18" "$TO_DELETE"

# Test 24: online == tested, both protected, old versions deleted
# 8 releases, keep=5. Protected at indices 0 (current) and 1 (online==tested).
# Protected: 2. Keep-recent: 3 (indices 2,3,4). Delete-old: 8-2-3=3.
RELEASES=$(make_releases \
  "v2026.07.28.7000" \
  "v2025.12.23" \
  "v2025.12.20" \
  "v2025.12.18" \
  "v2025.12.15" \
  "v2025.12.10" \
  "v2025.12.05" \
  "v2025.12.01")
PROTECTED="v2025.12.23 v2026.07.28.7000"
TO_DELETE=$(compute_releases_to_delete "$RELEASES" "$PROTECTED" "5")
EXIT_CODE=$?
assert_eq "T24: online==tested - exit code" "0" "$EXIT_CODE"
assert_not_contains "T24: tested not deleted" "v2025.12.23" "$TO_DELETE"
DELETE_COUNT=$(printf '%s' "$TO_DELETE" | jq 'length')
assert_eq "T24: online==tested - delete count" "1" "$DELETE_COUNT"

# Test 25: empty releases list (delete none)
TO_DELETE=$(compute_releases_to_delete '[]' "v2025.12.23 v2026.07.15.6961" "5")
EXIT_CODE=$?
assert_eq "T25: empty releases - exit code" "0" "$EXIT_CODE"
DELETE_COUNT=$(printf '%s' "$TO_DELETE" | jq 'length')
assert_eq "T25: empty releases - delete count" "0" "$DELETE_COUNT"

# Test 26: invalid releases JSON (fail-closed)
OUTPUT=$(compute_releases_to_delete 'not json' "v2025.12.23" "5" 2>/dev/null)
EXIT_CODE=$?
assert_fail_closed "T26: invalid releases JSON" "$EXIT_CODE" "$OUTPUT"

# Test 27: no protected tags at all (should still keep recent 5, delete old)
RELEASES=$(make_releases \
  "v2026.07.28.7000" \
  "v2026.07.15.6961" \
  "v2026.07.10.6900" \
  "v2026.07.05.6800" \
  "v2026.06.28.6700" \
  "v2026.06.20.6600" \
  "v2026.06.15.6500")
PROTECTED=""
TO_DELETE=$(compute_releases_to_delete "$RELEASES" "$PROTECTED" "5")
EXIT_CODE=$?
assert_eq "T27: no protected tags - exit code" "0" "$EXIT_CODE"
DELETE_COUNT=$(printf '%s' "$TO_DELETE" | jq 'length')
assert_eq "T27: no protected tags - delete count" "2" "$DELETE_COUNT"
assert_contains "T27: deletes v2026.06.20.6600" "v2026.06.20.6600" "$TO_DELETE"
assert_contains "T27: deletes v2026.06.15.6500" "v2026.06.15.6500" "$TO_DELETE"

# Test 28: compute_release_plan shows all reasons
# 6 releases, keep=5. Protected at indices 0 (current), 1 (online), 3 (tested).
# Protected builds do not consume the ordinary retention budget.
# Protected: 3. Ordinary builds: 3, all retained. Delete-old: 0.
RELEASES=$(make_releases \
  "v2026.07.28.7000" \
  "v2026.07.15.6961" \
  "v2026.07.10.6900" \
  "v2025.12.23" \
  "v2025.12.20" \
  "v2025.12.18")
PROTECTED="v2026.07.15.6961 v2025.12.23 v2026.07.28.7000"
PLAN=$(compute_release_plan "$RELEASES" "$PROTECTED" "5")
EXIT_CODE=$?
assert_eq "T28: plan - exit code" "0" "$EXIT_CODE"
PROTECTED_COUNT=$(printf '%s' "$PLAN" | jq '[.[] | select(.reason == "protected")] | length')
KEEP_COUNT=$(printf '%s' "$PLAN" | jq '[.[] | select(.reason == "keep-recent")] | length')
DELETE_COUNT=$(printf '%s' "$PLAN" | jq '[.[] | select(.reason == "delete-old")] | length')
assert_eq "T28: plan - protected count" "3" "$PROTECTED_COUNT"
assert_eq "T28: plan - keep-recent count" "3" "$KEEP_COUNT"
assert_eq "T28: plan - delete-old count" "0" "$DELETE_COUNT"

# Test 29: all releases are protected (delete none)
RELEASES=$(make_releases "v2026.07.28.7000" "v2026.07.15.6961" "v2025.12.23")
PROTECTED="v2026.07.15.6961 v2025.12.23 v2026.07.28.7000"
TO_DELETE=$(compute_releases_to_delete "$RELEASES" "$PROTECTED" "5")
EXIT_CODE=$?
assert_eq "T29: all protected - exit code" "0" "$EXIT_CODE"
DELETE_COUNT=$(printf '%s' "$TO_DELETE" | jq 'length')
assert_eq "T29: all protected - delete count" "0" "$DELETE_COUNT"

# Test 30: current build version is protected even if very old
RELEASES=$(make_releases \
  "v2026.07.28.7000" \
  "v2026.07.15.6961" \
  "v2026.07.10.6900" \
  "v2026.07.05.6800" \
  "v2026.06.28.6700" \
  "v2026.06.20.6600" \
  "v2026.06.15.6500" \
  "v2026.06.10.6400" \
  "v2025.12.23" \
  "v2025.12.20")
PROTECTED="v2026.07.15.6961 v2025.12.23 v2026.07.28.7000"
TO_DELETE=$(compute_releases_to_delete "$RELEASES" "$PROTECTED" "5")
EXIT_CODE=$?
assert_eq "T30: current build protected - exit code" "0" "$EXIT_CODE"
assert_not_contains "T30: current build not deleted" "v2026.07.28.7000" "$TO_DELETE"
assert_not_contains "T30: tested not deleted" "v2025.12.23" "$TO_DELETE"

# ============================================================================
# Summary
# ============================================================================

echo ""
echo "=========================================="
printf "Total: %d, ${GREEN}Pass: %d${NC}, ${RED}Fail: %d${NC}\n" $((PASS + FAIL)) "$PASS" "$FAIL"
echo "=========================================="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi

exit 0
