#!/usr/bin/env bash

set -euo pipefail

ROM_MANIFEST_URL="https://github.com/IamCharvik/local_mf.git"
ROM_MANIFEST_BRANCH="main"
ROM_BRANCH="16.0"
DEVICE="gemstone"
GITHUB_RELEASE_REPO="IamCharvik/roms"
UPLOAD_GITHUB_RELEASE="${UPLOAD_GITHUB_RELEASE:-0}"
UPLOAD_GOFILE="${UPLOAD_GOFILE:-1}"
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

install_jq_if_missing() {
  if command -v jq >/dev/null 2>&1; then
    return
  fi

  echo "jq is missing; installing it in the temporary Crave build environment"

  if command -v sudo >/dev/null 2>&1; then
    sudo -n apt-get update
    sudo -n apt-get install -y --no-install-recommends jq
  elif [[ "$(id -u)" -eq 0 ]]; then
    apt-get update
    apt-get install -y --no-install-recommends jq
  else
    echo "ERROR: jq is missing and package installation is unavailable" >&2
    exit 1
  fi
}

if [[ "${UPLOAD_GITHUB_RELEASE}" == "1" || "${UPLOAD_GOFILE}" == "1" ]]; then
  if ! command -v curl >/dev/null 2>&1; then
    echo "WARNING: curl is unavailable; post-build uploads will be skipped" >&2
    UPLOAD_GITHUB_RELEASE=0
    UPLOAD_GOFILE=0
  elif ! command -v jq >/dev/null 2>&1; then
    if ! install_jq_if_missing; then
      echo "WARNING: jq could not be installed; post-build uploads will be skipped" >&2
      UPLOAD_GITHUB_RELEASE=0
      UPLOAD_GOFILE=0
    fi
  fi
  if [[ "${UPLOAD_GITHUB_RELEASE}" == "1" && -z "${GH_TOKEN:-}" ]]; then
    echo "WARNING: GH_TOKEN is missing; GitHub upload will be skipped" >&2
    UPLOAD_GITHUB_RELEASE=0
  fi
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

shopt -s nullglob
RELEASE_ASSETS=(out/target/product/${DEVICE}/*.zip)
shopt -u nullglob

upload_github_release() {
  local release_tag release_title release_notes release_json release_response
  local upload_url release_url asset asset_size upload_asset

  echo "==> Creating GitHub release in ${GITHUB_RELEASE_REPO}"
  release_tag="gemstone-$(date -u +%Y.%m.%d-%H%M)"
  release_title="crDroid ${ROM_BRANCH} for ${DEVICE} — ${release_tag}"
  release_notes="$(printf 'Automated Crave build for Xiaomi %s.\n\nBuild device: %s\nROM branch: %s\nManifest: %s@%s\nManifest revision: %s\n' \
    "${DEVICE}" "${DEVICE}" "${ROM_BRANCH}" "${ROM_MANIFEST_URL}" "${ROM_MANIFEST_BRANCH}" \
    "$(git -C .repo/local_manifests rev-parse HEAD)")"
  release_json="$(jq -n \
    --arg tag "${release_tag}" \
    --arg name "${release_title}" \
    --arg body "${release_notes}" \
    '{tag_name:$tag, name:$name, body:$body, draft:false, prerelease:false}')"

  if ! release_response="$(curl --fail-with-body --silent --show-error \
    -X POST \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${GH_TOKEN}" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/${GITHUB_RELEASE_REPO}/releases" \
    -d "${release_json}")"; then
    echo "WARNING: GitHub release creation failed; continuing" >&2
    return 1
  fi

  upload_url="$(jq -r '.upload_url // empty' <<<"${release_response}" | sed 's/{?name,label}//')"
  release_url="$(jq -r '.html_url // empty' <<<"${release_response}")"
  if [[ -z "${upload_url}" ]]; then
    echo "WARNING: GitHub returned no upload URL; continuing" >&2
    return 1
  fi

  for asset in "${RELEASE_ASSETS[@]}"; do
    asset_size="$(stat -c '%s' "${asset}")"
    if [[ "${asset_size}" -ge 2147483648 ]]; then
      echo "WARNING: GitHub skipped asset at or above 2 GiB: ${asset}" >&2
      continue
    fi
    sha256sum "${asset}" > "${asset}.sha256"
    for upload_asset in "${asset}" "${asset}.sha256"; do
      echo "==> Uploading to GitHub: $(basename "${upload_asset}")"
      if ! curl --fail-with-body --silent --show-error \
        -X POST \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer ${GH_TOKEN}" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        -H "Content-Type: application/octet-stream" \
        --data-binary "@${upload_asset}" \
        "${upload_url}?name=$(basename "${upload_asset}")" >/dev/null; then
        echo "WARNING: GitHub upload failed for $(basename "${upload_asset}"); continuing" >&2
      fi
    done
  done
  echo "GitHub release URL: ${release_url}"
}

upload_gofile() {
  local server_response server asset upload_response status download_page upload_asset

  echo "==> Finding a Gofile upload server"
  if ! server_response="$(curl --fail-with-body --silent --show-error \
    --connect-timeout 15 --retry 2 https://api.gofile.io/servers)"; then
    echo "WARNING: Gofile server lookup failed; continuing" >&2
    return 1
  fi
  server="$(jq -r '.data.servers[0].name // empty' <<<"${server_response}")"
  if [[ -z "${server}" ]]; then
    echo "WARNING: Gofile returned no upload server; continuing" >&2
    return 1
  fi

  for asset in "${RELEASE_ASSETS[@]}"; do
    sha256sum "${asset}" > "${asset}.sha256"
    for upload_asset in "${asset}" "${asset}.sha256"; do
      echo "==> Uploading to Gofile: $(basename "${upload_asset}")"
      if ! upload_response="$(curl --fail-with-body --silent --show-error \
        --connect-timeout 30 --retry 2 --max-time 3600 \
        -F "file=@${upload_asset}" \
        "https://${server}.gofile.io/contents/uploadfile")"; then
        echo "WARNING: Gofile upload failed for $(basename "${upload_asset}"); continuing" >&2
        continue
      fi
      status="$(jq -r '.status // empty' <<<"${upload_response}")"
      download_page="$(jq -r '.data.downloadPage // empty' <<<"${upload_response}")"
      if [[ "${status}" == "ok" && -n "${download_page}" ]]; then
        echo "Gofile link for $(basename "${upload_asset}"): ${download_page}"
      else
        echo "WARNING: Gofile returned an unsuccessful response for $(basename "${upload_asset}"); continuing" >&2
      fi
    done
  done
}

if [[ "${#RELEASE_ASSETS[@]}" -eq 0 ]]; then
  echo "WARNING: no ROM ZIP found; skipping post-build uploads" >&2
else
  if [[ "${UPLOAD_GITHUB_RELEASE}" == "1" ]]; then
    upload_github_release || true
  fi
  if [[ "${UPLOAD_GOFILE}" == "1" ]]; then
    upload_gofile || true
  fi
fi

echo "==> Build completed"
echo "Artifacts: out/target/product/${DEVICE}/"
