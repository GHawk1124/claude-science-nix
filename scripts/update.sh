#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# claude-science-nix — version-update script
#
# Usage:
#   scripts/update.sh              # Update to latest version
#   scripts/update.sh --check      # Only check for updates (exit 1 if available)
#   scripts/update.sh --help       # Show help
#
# This script downloads the latest Linux binary to discover the current
# upstream version, then computes fresh SRI hashes for every supported
# platform and writes them back into package.nix.  After the update it
# verifies the Linux build and refreshes flake.lock.
# ---------------------------------------------------------------------------

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

readonly BASE_URL="https://downloads.claude.ai/claude-science/latest"

# platform → URL path suffix (same order as package.nix srcs attrset)
declare -A PLATFORM_URLS=(
  ["x86_64-linux"]="${BASE_URL}/linux-x64"
  ["aarch64-darwin"]="${BASE_URL}/mac-arm64.dmg"
  ["x86_64-darwin"]="${BASE_URL}/mac-x64.dmg"
)

readonly MAX_RETRIES=3
readonly RETRY_BASE_DELAY=2

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

log_info()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

retry() {
  local max_attempts="$1" base_delay="$2"
  shift 2

  for ((attempt = 1; attempt <= max_attempts; attempt++)); do
    local result
    result=$("$@") && [ -n "$result" ] && { echo "$result"; return 0; }

    if ((attempt < max_attempts)); then
      local delay=$((base_delay ** attempt))
      log_warn "Attempt $attempt/$max_attempts failed, retrying in ${delay}s..."
      sleep "$delay"
    fi
  done
  return 1
}

get_current_version() {
  sed -n 's/.*version = "\([^"]*\)".*/\1/p' package.nix | head -1 || echo "unknown"
}

# Download the latest Linux binary and extract its --version string.
fetch_upstream_version() {
  local tmpbin
  tmpbin=$(mktemp /tmp/claude-science-XXXXXX)
  # Clean up on any exit.
  # shellcheck disable=SC2064
  trap "rm -f '$tmpbin'" RETURN

  log_info "Downloading latest Linux binary to discover upstream version..."
  if ! curl -sfL --max-time 120 \
    "${BASE_URL}/linux-x64" -o "$tmpbin"; then
    log_error "Failed to download Linux binary"
    return 1
  fi

  chmod +x "$tmpbin"

  local raw
  raw=$("$tmpbin" --version 2>/dev/null) || {
    log_error "Failed to run --version on downloaded binary"
    return 1
  }

  # Expected format: "claude-science 0.1.0-dev.20260630.t212931.sha2bc1ac8 (release, public)"
  local version
  version=$(echo "$raw" | sed -n 's/.*claude-science \([^ ]*\).*/\1/p')
  if [ -z "$version" ]; then
    log_error "Could not parse version from: $raw"
    return 1
  fi

  echo "$version"
}

# Fetch the SRI hash for a given platform.
fetch_hash() {
  local platform="$1"
  local url="${PLATFORM_URLS[$platform]}"

  log_info "  Fetching hash for $platform..."
  local json hash
  json=$(nix store prefetch-file "$url" --json 2>/dev/null) || {
    log_error "nix store prefetch-file failed for $platform"
    return 1
  }
  hash=$(echo "$json" | jq -r '.hash')
  if [ -z "$hash" ] || [ "$hash" = "null" ]; then
    log_error "Could not extract hash for $platform"
    return 1
  fi

  echo "$hash"
}

# ---------------------------------------------------------------------------
# update implementation
# ---------------------------------------------------------------------------

update_package_version() {
  local new_version="$1"
  sed -i.bak "s/version = \"[^\"]*\"/version = \"$new_version\"/" package.nix
}

update_platform_hash() {
  local platform="$1" hash="$2"
  local tmpfile
  tmpfile=$(mktemp)

  # Update the hash line inside the srcs attrset for the given platform key.
  awk -v plat="$platform" -v h="$hash" '
    BEGIN { in_block = 0 }
    $0 ~ "\"" plat "\"" { in_block = 1 }
    in_block && /hash =/ {
      sub(/hash = "[^"]*"/, "hash = \"" h "\"")
      in_block = 0
    }
    { print }
  ' package.nix > "$tmpfile"
  mv "$tmpfile" package.nix
}

cleanup_backup() {
  rm -f package.nix.bak
}

do_update() {
  local new_version="$1"

  log_info "Updating from $(get_current_version) → $new_version"

  update_package_version "$new_version"

  for platform in x86_64-linux aarch64-darwin x86_64-darwin; do
    local h
    h=$(fetch_hash "$platform") || exit 1
    log_info "    $platform  $h"
    update_platform_hash "$platform" "$h"
  done

  cleanup_backup

  log_info "Verifying Linux build..."
  if ! nix build .#claude-science --no-link >/dev/null 2>&1; then
    log_error "Build verification failed — rolling back"
    mv package.nix.bak package.nix 2>/dev/null || true
    return 1
  fi

  log_info "Build successful!"
  return 0
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

ensure_root() {
  if [ ! -f flake.nix ] || [ ! -f package.nix ]; then
    log_error "Must be run from the repository root (flake.nix / package.nix not found)"
    exit 1
  fi
}

ensure_tools() {
  command -v nix    >/dev/null 2>&1 || { log_error "nix is required";   exit 1; }
  command -v curl   >/dev/null 2>&1 || { log_error "curl is required";  exit 1; }
  command -v jq     >/dev/null 2>&1 || { log_error "jq is required";    exit 1; }
}

print_usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --check        Only check whether an update is available (exit 1 if yes).
  --help         Show this message.

Without options the script updates package.nix to the latest upstream version,
rebuilds, and refreshes flake.lock.
EOF
}

main() {
  ensure_root
  ensure_tools

  local check_only=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --check) check_only=true; shift ;;
      --help)  print_usage; exit 0 ;;
      *)       log_error "Unknown option: $1"; print_usage; exit 1 ;;
    esac
  done

  local current
  current=$(get_current_version)
  log_info "Current version: $current"

  local latest
  latest=$(retry "$MAX_RETRIES" "$RETRY_BASE_DELAY" fetch_upstream_version) || {
    log_error "Failed to determine upstream version after $MAX_RETRIES attempts"
    exit 1
  }
  log_info "Upstream version: $latest"

  if [ "$current" = "$latest" ]; then
    log_info "Already up to date!"
    exit 0
  fi

  if [ "$check_only" = true ]; then
    log_info "Update available: $current → $latest"
    exit 1
  fi

  do_update "$latest"
  log_info "Successfully updated from $current to $latest"

  log_info "Updating flake.lock..."
  nix flake update

  echo ""
  log_info "Changes:"
  git diff --stat package.nix flake.lock 2>/dev/null || true
}

main "$@"
