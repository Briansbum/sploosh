#!/usr/bin/env bash
# import-mods.sh — generate ${PACKWIZ:-nix run nixpkgs#packwiz --} mod stubs from an existing mods/ directory.
#
# Usage:
#   nix develop
#   ./scripts/import-mods.sh ~/minecraft-backup/alf10/AllTheForge10/mods modpacks/all-the-forge-10
#   ./scripts/import-mods.sh ~/minecraft-backup/glorp/mods modpacks/jaffa-factory-2
#
# For each JAR it tries Modrinth first (by file hash), then CurseForge.
# Mods it can't identify are written to a "manual.txt" list for you to handle.
#
# Requires: ${PACKWIZ:-nix run nixpkgs#packwiz --}, curl, jq (all in nix develop shell)

set -euo pipefail

MODS_DIR="${1:?Usage: import-mods.sh <mods-dir> <pack-dir>}"
PACK_DIR="${2:?Usage: import-mods.sh <mods-dir> <pack-dir>}"

PACK_DIR="$(realpath "$PACK_DIR")"
mkdir -p "$PACK_DIR/mods"
MANUAL="$PACK_DIR/mods/manual.txt"
> "$MANUAL"

cd "$PACK_DIR"

found=0
notfound=0

for jar in "$MODS_DIR"/*.jar; do
  filename=$(basename "$jar")
  echo -n "  $filename ... "

  # SHA-512 hash (Modrinth uses sha512)
  sha512=$(sha512sum "$jar" | cut -d' ' -f1)

  # Try Modrinth hash lookup
  result=$(curl -sf "https://api.modrinth.com/v2/version_file/$sha512?algorithm=sha512" 2>/dev/null || echo "")

  if [ -n "$result" ] && echo "$result" | jq -e '.project_id' >/dev/null 2>&1; then
    project_id=$(echo "$result" | jq -r '.project_id')
    version_id=$(echo "$result" | jq -r '.id')

    ${PACKWIZ:-nix run nixpkgs#packwiz --} modrinth add \
      --project-id "$project_id" \
      --version-id "$version_id" \
      -y 2>/dev/null && echo "✓ modrinth:$project_id" && found=$((found+1)) && continue
  fi

  # Modrinth not found → record for manual addition
  echo "✗ not found"
  echo "$filename" >> "$MANUAL"
  notfound=$((notfound+1))
done

echo ""
echo "Imported: $found mods"
echo "Not found: $notfound mods — see $MANUAL"

if [ "$notfound" -gt 0 ]; then
  echo ""
  echo "For unresolved mods, try:"
  echo "  ${PACKWIZ:-nix run nixpkgs#packwiz --} cf add <curseforge-project-slug>"
  echo "  ${PACKWIZ:-nix run nixpkgs#packwiz --} url add --name <name> <direct-download-url>"
fi

# Rebuild the pack index
${PACKWIZ:-nix run nixpkgs#packwiz --} refresh
