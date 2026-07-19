#!/bin/bash
# =============================================================================
# Bumps the app version in lockstep across the 3 files that must always agree
# (package.json, src-tauri/Cargo.toml, src-tauri/tauri.conf.json), and prints
# the new version on stdout (only line on stdout — callers capture it via
# command substitution).
#
# Usage: release/bump-version.sh [patch|minor|major]   (default: patch)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

BUMP="${1:-patch}"
case "$BUMP" in
    patch|minor|major) ;;
    *) echo "Usage: $0 [patch|minor|major]" >&2; exit 1 ;;
esac

CURRENT=$(grep -m1 '"version"' "$ROOT_DIR/package.json" | sed -E 's/.*"version": *"([^"]+)".*/\1/')
IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT"

case "$BUMP" in
    patch) PATCH=$((PATCH + 1)) ;;
    minor) MINOR=$((MINOR + 1)); PATCH=0 ;;
    major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
esac

NEW="$MAJOR.$MINOR.$PATCH"

sed -i '' "s/\"version\": \"$CURRENT\"/\"version\": \"$NEW\"/" "$ROOT_DIR/package.json"
sed -i '' "s/\"version\": \"$CURRENT\"/\"version\": \"$NEW\"/" "$ROOT_DIR/src-tauri/tauri.conf.json"
sed -i '' "s/^version = \"$CURRENT\"/version = \"$NEW\"/" "$ROOT_DIR/src-tauri/Cargo.toml"

echo "$NEW"
