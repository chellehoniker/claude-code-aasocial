#!/usr/bin/env bash
# SessionStart hook: ensure the right per-platform aa-mcp binary is at the
# unified path the .mcp.json command points to.
#
# How it works:
#   1. Read the version pin from package.json (kept in sync at release time).
#   2. Detect platform + arch via uname.
#   3. If the unified-path binary already exists AND its sha matches the
#      checksum we stamped on disk last time, skip (idempotent fast path).
#   4. Otherwise: fetch checksums.txt for this version from GitHub Releases,
#      pick the line for our platform, download the binary, verify the hash,
#      move into the unified path, mark it executable.
#
# Why bash (and not platform-conditional logic):
#   Cowork runs hooks through bash on macOS/Linux and via Git Bash on Windows
#   (per the existing v1.x hook precedent which used bash syntax). curl is on
#   PATH on all three: macOS ships it, Linux ships it, Windows 10+ ships it.
#
# Why fail loud (not silent):
#   The whole reason we're doing this binary-distribution refactor is that
#   silent failure was the conversion blocker. If the download fails, we
#   write a clear error file the aa-setup skill can read so Claude can
#   surface a real diagnosis to the user.

set -euo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
BIN_TARGET="${PLUGIN_ROOT}/mcp-server/aa-mcp.exe"
MARKER_FILE="${PLUGIN_ROOT}/mcp-server/.installed-version"
ERROR_FILE="${PLUGIN_ROOT}/mcp-server/.install-error"
PLUGIN_MANIFEST="${PLUGIN_ROOT}/.claude-plugin/plugin.json"

# Read both version and repository URL from the plugin manifest. Reading
# the repo dynamically (not hardcoded) means a fork/test repo can run
# the same hook unchanged — only its plugin.json differs. Strip the
# trailing slash if present, and trust that the manifest's repository
# field already points at a github.com URL.
VERSION="$(grep -E '"version"[[:space:]]*:' "${PLUGIN_MANIFEST}" | head -1 | sed -E 's/.*"([0-9]+\.[0-9]+\.[0-9]+)".*/\1/')"
REPO_URL="$(grep -E '"repository"[[:space:]]*:' "${PLUGIN_MANIFEST}" | head -1 | sed -E 's/.*"(https:\/\/[^"]+)".*/\1/' | sed 's:/*$::')"

if [ -z "${VERSION}" ]; then
  echo "Could not determine plugin version from ${PLUGIN_MANIFEST}" > "${ERROR_FILE}"
  exit 1
fi

if [ -z "${REPO_URL}" ]; then
  echo "Could not determine repository URL from ${PLUGIN_MANIFEST}" > "${ERROR_FILE}"
  exit 1
fi

TAG="v${VERSION}"
RELEASE_BASE="${REPO_URL}/releases/download"

# Detect platform → release-asset filename
unameOut="$(uname -s 2>/dev/null || echo "Unknown")"
unameArch="$(uname -m 2>/dev/null || echo "unknown")"
ASSET=""
case "${unameOut}-${unameArch}" in
  Darwin-arm64)        ASSET="aa-mcp-darwin-arm64" ;;
  Darwin-x86_64)       ASSET="aa-mcp-darwin-x64" ;;
  Linux-x86_64)        ASSET="aa-mcp-linux-x64" ;;
  Linux-aarch64)       ASSET="aa-mcp-linux-x64" ;;  # bun emits x64 only; aarch64 Linux is rare here
  MINGW*|MSYS*|CYGWIN*|*MINGW64*|*MSYS_NT*|*CYGWIN_NT*)
                       ASSET="aa-mcp-windows-x64.exe" ;;
  *)
    # If uname is missing or unrecognized (some Windows shells), assume
    # Windows when the OS env var is set — Git Bash sets it.
    if [ "${OS:-}" = "Windows_NT" ]; then
      ASSET="aa-mcp-windows-x64.exe"
    else
      echo "Unsupported platform: ${unameOut}-${unameArch}" > "${ERROR_FILE}"
      exit 1
    fi
    ;;
esac

EXPECTED_SIG="${TAG}/${ASSET}"

# Fast path: binary already installed for this version.
if [ -f "${BIN_TARGET}" ] && [ -f "${MARKER_FILE}" ] && [ "$(cat "${MARKER_FILE}")" = "${EXPECTED_SIG}" ]; then
  rm -f "${ERROR_FILE}"
  exit 0
fi

# Slow path: download.
mkdir -p "$(dirname "${BIN_TARGET}")"
TMP_BIN="${BIN_TARGET}.downloading"
TMP_SUMS="$(mktemp 2>/dev/null || echo "${PLUGIN_ROOT}/mcp-server/.checksums.txt.tmp")"

# Fetch checksums.txt first — small, fast, lets us verify the binary hash
# before we trust the binary itself.
if ! curl -fsSL --retry 2 --retry-delay 1 -o "${TMP_SUMS}" "${RELEASE_BASE}/${TAG}/checksums.txt"; then
  cat <<EOF > "${ERROR_FILE}"
Failed to download checksums.txt from GitHub Releases.

Tried: ${RELEASE_BASE}/${TAG}/checksums.txt

Most common cause: your sandbox is blocking outbound traffic to GitHub.
Fix in Claude Cowork: Settings → Capabilities → Allow Network Egress
should be ON, set to "All Domains".
EOF
  exit 1
fi

EXPECTED_SHA="$(grep "  ${ASSET}\$" "${TMP_SUMS}" | awk '{print $1}')"
if [ -z "${EXPECTED_SHA}" ]; then
  echo "Could not find ${ASSET} in checksums.txt for ${TAG}" > "${ERROR_FILE}"
  rm -f "${TMP_SUMS}"
  exit 1
fi

# Download the binary itself.
if ! curl -fsSL --retry 2 --retry-delay 1 -o "${TMP_BIN}" "${RELEASE_BASE}/${TAG}/${ASSET}"; then
  cat <<EOF > "${ERROR_FILE}"
Failed to download ${ASSET} from GitHub Releases.

Tried: ${RELEASE_BASE}/${TAG}/${ASSET}

This usually means the network blocked the download partway through.
Try restarting Cowork. If it still fails: Settings → Capabilities →
Allow Network Egress → All Domains.
EOF
  rm -f "${TMP_SUMS}"
  exit 1
fi

# Verify the hash. Try shasum (BSD/macOS), sha256sum (Linux/Git Bash on Win),
# in that order. Fail loud if neither is present — better than silently
# trusting an unverified binary.
ACTUAL_SHA=""
if command -v shasum >/dev/null 2>&1; then
  ACTUAL_SHA="$(shasum -a 256 "${TMP_BIN}" | awk '{print $1}')"
elif command -v sha256sum >/dev/null 2>&1; then
  ACTUAL_SHA="$(sha256sum "${TMP_BIN}" | awk '{print $1}')"
else
  echo "Neither shasum nor sha256sum available — cannot verify binary integrity" > "${ERROR_FILE}"
  rm -f "${TMP_BIN}" "${TMP_SUMS}"
  exit 1
fi

if [ "${ACTUAL_SHA}" != "${EXPECTED_SHA}" ]; then
  cat <<EOF > "${ERROR_FILE}"
Binary integrity check failed for ${ASSET}.
Expected sha256: ${EXPECTED_SHA}
Got:             ${ACTUAL_SHA}

This could mean a corrupted download or a transparent proxy modifying
traffic. Try restarting Cowork. If it persists, contact support.
EOF
  rm -f "${TMP_BIN}" "${TMP_SUMS}"
  exit 1
fi

# All checks passed. Atomic move + mark + cleanup.
mv -f "${TMP_BIN}" "${BIN_TARGET}"
chmod +x "${BIN_TARGET}" 2>/dev/null || true
echo "${EXPECTED_SIG}" > "${MARKER_FILE}"
rm -f "${ERROR_FILE}" "${TMP_SUMS}"

echo "Author Automations Social: installed ${ASSET} for ${TAG}"
