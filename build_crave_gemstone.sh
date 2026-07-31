#!/usr/bin/env bash

set -euo pipefail

ROM_MANIFEST_URL="https://github.com/IamCharvik/local_mf.git"
ROM_MANIFEST_BRANCH="main"
ROM_BRANCH="16.0"
DEVICE="gemstone"
GITHUB_RELEASE_REPO="IamCharvik/roms"
UPLOAD_GITHUB_RELEASE="${UPLOAD_GITHUB_RELEASE:-0}"
LOG_FILE="build_${DEVICE}_$(date +%Y%m%d_%H%M%S).log"

exec > >(tee -a "${LOG_FILE}") 2>&1

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: required command not found: $1" >&2
    exit 1
  }
}

require_command repo
require_command git
require_command tee
if [[ "${UPLOAD_GITHUB_RELEASE}" == "1" ]]; then
  require_command curl
  require_command jq
  require_command sha256sum
  require_command stat
  test -n "${GH_TOKEN:-}" || {
    echo "ERROR: GH_TOKEN is required when UPLOAD_GITHUB_RELEASE=1" >&2
    exit 1
  }
fi
test -x /opt/crave/resync.sh || {
  echo "ERROR: /opt/crave/resync.sh is unavailable" >&2
  exit 1
}

handle_error() {
  local status=$?
  trap - ERR

  echo "ERROR: build script failed with status ${status}" >&2
  echo "Full log: ${LOG_FILE}" >&2
  exit "${status}"
}

trap handle_error ERR

echo "==> Initializing crDroid ${ROM_BRANCH}"
repo init \
  -u https://github.com/crdroidandroid/android.git \
  -b "${ROM_BRANCH}" \
  --git-lfs \
  --depth=1

echo "==> Installing public device manifest"
rm -rf .repo/local_manifests
git clone \
  --depth=1 \
  --branch "${ROM_MANIFEST_BRANCH}" \
  "${ROM_MANIFEST_URL}" \
  .repo/local_manifests

test -f .repo/local_manifests/local_manifest.xml || {
  echo "ERROR: expected local_manifest.xml was not found" >&2
  exit 1
}

echo "Manifest revision: $(git -C .repo/local_manifests rev-parse --short HEAD)"

echo "==> Syncing sources through Crave"
/opt/crave/resync.sh

for required_path in \
  device/xiaomi/gemstone \
  device/xiaomi/sm6375-common \
  vendor/xiaomi/gemstone \
  vendor/xiaomi/sm6375-common \
  kernel/xiaomi/sm6375 \
  hardware/xiaomi; do
  test -e "${required_path}" || {
    echo "ERROR: synced path is missing: ${required_path}" >&2
    exit 1
  }
done

echo "==> Preparing ${DEVICE}"
source build/envsetup.sh
breakfast "${DEVICE}" userdebug

echo "==> Building ${DEVICE}"
mka bacon

if [[ "${UPLOAD_GITHUB_RELEASE}" == "1" ]]; then
  echo "==> Creating GitHub release in ${GITHUB_RELEASE_REPO}"
  RELEASE_TAG="gemstone-$(date -u +%Y.%m.%d-%H%M)"
  RELEASE_TITLE="crDroid ${ROM_BRANCH} for ${DEVICE} — ${RELEASE_TAG}"

  shopt -s nullglob
  RELEASE_ASSETS=(out/target/product/${DEVICE}/*.zip)
  shopt -u nullglob
  test "${#RELEASE_ASSETS[@]}" -gt 0 || {
    echo "ERROR: no ROM ZIP was found to upload" >&2
    exit 1
  }

  RELEASE_NOTES="$(printf 'Automated Crave build for Xiaomi %s.\n\nBuild device: %s\nROM branch: %s\nManifest: %s@%s\nManifest revision: %s\n' \
    "${DEVICE}" "${DEVICE}" "${ROM_BRANCH}" "${ROM_MANIFEST_URL}" "${ROM_MANIFEST_BRANCH}" \
    "$(git -C .repo/local_manifests rev-parse HEAD)")"

  RELEASE_JSON="$(jq -n \
    --arg tag "${RELEASE_TAG}" \
    --arg name "${RELEASE_TITLE}" \
    --arg body "${RELEASE_NOTES}" \
    '{tag_name:$tag, name:$name, body:$body, draft:false, prerelease:false}')"

  RELEASE_RESPONSE="$(curl --fail-with-body --silent --show-error \
    -X POST \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${GH_TOKEN}" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    https://api.github.com/repos/${GITHUB_RELEASE_REPO}/releases \
    -d "${RELEASE_JSON}")"

  UPLOAD_URL="$(jq -r '.upload_url' <<<"${RELEASE_RESPONSE}" | sed 's/{?name,label}//')"
  RELEASE_URL="$(jq -r '.html_url' <<<"${RELEASE_RESPONSE}")"
  test -n "${UPLOAD_URL}" && test "${UPLOAD_URL}" != "null" || {
    echo "ERROR: GitHub release creation returned no upload URL" >&2
    exit 1
  }

  for asset in "${RELEASE_ASSETS[@]}"; do
    asset_size="$(stat -c '%s' "${asset}")"
    test "${asset_size}" -lt 2147483648 || {
      echo "ERROR: GitHub release asset is 2 GiB or larger: ${asset}" >&2
      exit 1
    }
    sha256sum "${asset}" > "${asset}.sha256"
    for upload_asset in "${asset}" "${asset}.sha256"; do
      echo "==> Uploading $(basename "${upload_asset}")"
      curl --fail-with-body --silent --show-error \
        -X POST \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer ${GH_TOKEN}" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        -H "Content-Type: application/octet-stream" \
        --data-binary "@${upload_asset}" \
        "${UPLOAD_URL}?name=$(basename "${upload_asset}")" >/dev/null
    done
  done
  echo "GitHub release published: ${RELEASE_URL}"
fi

echo "==> Build completed"
echo "Artifacts: out/target/product/${DEVICE}/"
