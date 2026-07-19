#!/bin/bash
# =============================================================================
# Sets the app version to an exact value in lockstep across the 3 files that
# must always agree (package.json, src-tauri/Cargo.toml, src-tauri/tauri.conf.json).
# No bump math — the caller decides the exact version.
#
# Usage: release/set-version.sh <version>
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

NEW="${1:?Usage: $0 <version>}"
if [[ ! "$NEW" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Error: version must look like X.Y.Z (got: $NEW)" >&2
    exit 1
fi

CURRENT=$(grep -m1 '"version"' "$ROOT_DIR/package.json" | sed -E 's/.*"version": *"([^"]+)".*/\1/')

if [[ "$NEW" == "$CURRENT" ]]; then
    echo "Version already $NEW — nothing to change." >&2
else
    sed -i '' "s/\"version\": \"$CURRENT\"/\"version\": \"$NEW\"/" "$ROOT_DIR/package.json"
    sed -i '' "s/\"version\": \"$CURRENT\"/\"version\": \"$NEW\"/" "$ROOT_DIR/src-tauri/tauri.conf.json"
    sed -i '' "s/^version = \"$CURRENT\"/version = \"$NEW\"/" "$ROOT_DIR/src-tauri/Cargo.toml"
fi

echo "$NEW"
