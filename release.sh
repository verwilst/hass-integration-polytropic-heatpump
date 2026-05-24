#!/usr/bin/env bash
set -euo pipefail

VERSION=${1:?Usage: ./release.sh <version>  e.g. ./release.sh 1.0.0}
REPO="verwilst/hass-integration-polytropic-heatpump"
MANIFEST="custom_components/polytropic_heatpump/manifest.json"

# ── Checks ────────────────────────────────────────────────────────────────────

if ! command -v jq &>/dev/null; then
  echo "Error: jq is required (pacman -S jq)" && exit 1
fi

if ! command -v zip &>/dev/null; then
  echo "Error: zip is required (pacman -S zip)" && exit 1
fi

if ! command -v python3 &>/dev/null; then
  echo "Error: python3 is required (pacman -S python)" && exit 1
fi

if ! command -v curl &>/dev/null; then
  echo "Error: curl is required (pacman -S curl)" && exit 1
fi

if ! command -v awk &>/dev/null; then
  echo "Error: awk is required" && exit 1
fi

if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  echo "Error: GITHUB_TOKEN env var not set"
  echo "  export GITHUB_TOKEN=<your token>"
  exit 1
fi

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "Warning: uncommitted changes present"
  git status --short
  read -r -p "Proceed anyway? [y/N] " REPLY
  if [[ ! "${REPLY}" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 1
  fi
fi

# ── Bump manifest.json ────────────────────────────────────────────────────────

echo "→ Bumping manifest.json to ${VERSION}..."
python3 -c "
import json
with open('${MANIFEST}') as f:
    m = json.load(f)
m['version'] = '${VERSION}'
with open('${MANIFEST}', 'w') as f:
    json.dump(m, f, indent=2)
    f.write('\n')
"

git add "${MANIFEST}"
if git diff --cached --quiet; then
  echo "  (manifest already at ${VERSION}, skipping commit)"
else
  git commit -m "chore: bump version to ${VERSION}"
fi

# ── Extract changelog for this version ───────────────────────────────────────

CHANGELOG_BODY=$(awk "/^## \[${VERSION}\]/{found=1; next} found && /^## /{exit} found{print}" CHANGELOG.md)

if [[ -z "${CHANGELOG_BODY}" ]]; then
  echo "Warning: no changelog entry found for ${VERSION} in CHANGELOG.md"
  CHANGELOG_BODY="See CHANGELOG.md for details."
fi

# ── Tag & push ────────────────────────────────────────────────────────────────

echo "→ Tagging v${VERSION} and pushing..."
if git rev-parse -q --verify "refs/tags/v${VERSION}" >/dev/null; then
  echo "  (tag already exists, skipping)"
else
  git tag "v${VERSION}"
fi
git push origin main
git push origin "v${VERSION}"

# ── Build ZIP ─────────────────────────────────────────────────────────────────

ZIPFILE="/tmp/polytropic_heatpump_${VERSION}.zip"
echo "→ Building release ZIP..."
(cd custom_components && zip -qr "${ZIPFILE}" polytropic_heatpump/)

# ── Create GitHub release ─────────────────────────────────────────────────────

echo "→ Creating release on GitHub..."
EXISTING=$(curl -s \
  -H "Authorization: Bearer ${GITHUB_TOKEN}" \
  "https://api.github.com/repos/${REPO}/releases/tags/v${VERSION}")
RELEASE_ID=$(echo "${EXISTING}" | jq -r '.id // empty')

if [[ -n "${RELEASE_ID}" ]]; then
  echo "  (release v${VERSION} already exists, id=${RELEASE_ID}, reusing)"
  UPLOAD_URL=$(echo "${EXISTING}" | jq -r '.upload_url' | sed 's/{?name,label}//')
else
  RESPONSE=$(jq -n \
    --arg tag "v${VERSION}" \
    --arg name "v${VERSION}" \
    --arg body "${CHANGELOG_BODY}" \
    '{tag_name: $tag, name: $name, body: $body, draft: false, prerelease: false}' \
    | curl -s -X POST \
      -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      -H "Content-Type: application/json" \
      "https://api.github.com/repos/${REPO}/releases" \
      --data-binary @-)

  RELEASE_ID=$(echo "${RESPONSE}" | jq -r '.id')
  UPLOAD_URL=$(echo "${RESPONSE}" | jq -r '.upload_url' | sed 's/{?name,label}//')

  if [[ -z "${RELEASE_ID}" || "${RELEASE_ID}" == "null" ]]; then
    echo "Error: failed to create release"
    echo "${RESPONSE}" | jq .
    exit 1
  fi
fi

# ── Upload ZIP asset ──────────────────────────────────────────────────────────

echo "→ Uploading ZIP asset..."
EXISTING_ASSET_ID=$(curl -s \
  -H "Authorization: Bearer ${GITHUB_TOKEN}" \
  "https://api.github.com/repos/${REPO}/releases/${RELEASE_ID}/assets" \
  | jq -r '.[] | select(.name == "polytropic_heatpump.zip") | .id' | head -n1)

if [[ -n "${EXISTING_ASSET_ID}" ]]; then
  echo "  (deleting stale asset ${EXISTING_ASSET_ID} before re-uploading)"
  curl -s -X DELETE \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    "https://api.github.com/repos/${REPO}/releases/assets/${EXISTING_ASSET_ID}" >/dev/null
fi

curl -s -X POST \
  -H "Authorization: Bearer ${GITHUB_TOKEN}" \
  -H "Content-Type: application/zip" \
  "${UPLOAD_URL}?name=polytropic_heatpump.zip" \
  --data-binary "@${ZIPFILE}" \
  | jq -r '.browser_download_url'

rm -f "${ZIPFILE}"

echo ""
echo "✓ Released v${VERSION}: https://github.com/${REPO}/releases/tag/v${VERSION}"
