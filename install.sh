#!/usr/bin/env sh
# veric installer (rehearsal channel).
#
# Fetches the latest veric CLI release asset for the current host from
# the public hub at github.com/veric-dev/veric. During the pre-1.0
# rehearsal window, this script targets prereleases — production
# installers will target the latest non-prerelease tag.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/veric-dev/veric/dev/install.sh | sh
#   curl -fsSL https://raw.githubusercontent.com/veric-dev/veric/dev/install.sh | VERIC_VERSION=0.1.0-rehearsal0 sh
#   curl -fsSL https://raw.githubusercontent.com/veric-dev/veric/dev/install.sh | VERIC_PREFIX=/usr/local sh
#
# Env:
#   VERIC_VERSION  Pin to a specific version (defaults to latest prerelease).
#   VERIC_PREFIX   Install prefix (defaults to $HOME/.local; bin goes to $PREFIX/bin).
#
# Exits non-zero on any failure. Safe to re-run (overwrites the binary).

set -eu

REPO="veric-dev/veric"
PREFIX="${VERIC_PREFIX:-$HOME/.local}"
BIN_DIR="$PREFIX/bin"

err() { printf "error: %s\n" "$*" >&2; exit 1; }
info() { printf "veric-install: %s\n" "$*"; }

command -v curl >/dev/null 2>&1 || err "curl is required"
command -v tar  >/dev/null 2>&1 || err "tar is required"
command -v uname >/dev/null 2>&1 || err "uname is required"

# Platform detection. Mirrors the archive_suffix matrix in
# veric-platform/.github/workflows/cli-release.yml:
#   linux + x86_64     -> linux-x86_64
#   macOS + arm64/x86  -> macos-arm64  (Rosetta handles Intel Macs)
UNAME_S="$(uname -s)"
UNAME_M="$(uname -m)"
case "$UNAME_S" in
  Darwin) ARCHIVE_SUFFIX="macos-arm64" ;;
  Linux)
    case "$UNAME_M" in
      x86_64|amd64) ARCHIVE_SUFFIX="linux-x86_64" ;;
      *) err "unsupported linux arch: $UNAME_M (only x86_64 is published)" ;;
    esac
    ;;
  *) err "unsupported OS: $UNAME_S (only macOS + Linux are published)" ;;
esac

# Version resolution. If pinned, trust the caller. Otherwise pick the
# most recent published release — /releases/latest skips prereleases,
# which is wrong for the rehearsal channel, so we query the list and
# pick the first entry.
if [ -n "${VERIC_VERSION:-}" ]; then
  VERSION="${VERIC_VERSION#v}"
  info "installing pinned version $VERSION"
else
  API_URL="https://api.github.com/repos/$REPO/releases?per_page=1"
  RAW="$(curl -fsSL "$API_URL")" || err "failed to query $API_URL"
  # crude extraction — avoids a jq dependency
  TAG="$(printf '%s' "$RAW" | sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
  [ -n "$TAG" ] || err "could not parse tag_name from releases list"
  VERSION="${TAG#v}"
  info "latest published release: $TAG (version $VERSION)"
fi

ARCHIVE="veric-${VERSION}-${ARCHIVE_SUFFIX}.tar.gz"
ARCHIVE_URL="https://github.com/$REPO/releases/download/v${VERSION}/$ARCHIVE"
SHA_URL="${ARCHIVE_URL}.sha256"

WORK_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t veric-install)"
trap 'rm -rf "$WORK_DIR"' EXIT

info "downloading $ARCHIVE"
curl -fsSL -o "$WORK_DIR/$ARCHIVE"       "$ARCHIVE_URL" || err "download failed: $ARCHIVE_URL"
curl -fsSL -o "$WORK_DIR/$ARCHIVE.sha256" "$SHA_URL"    || err "checksum download failed: $SHA_URL"

# Verify sha256. The .sha256 file from shasum(1) is
# "<hex>  <filename>" — strip the filename before comparing.
EXPECTED="$(awk '{print $1}' "$WORK_DIR/$ARCHIVE.sha256")"
if command -v sha256sum >/dev/null 2>&1; then
  ACTUAL="$(sha256sum "$WORK_DIR/$ARCHIVE" | awk '{print $1}')"
elif command -v shasum >/dev/null 2>&1; then
  ACTUAL="$(shasum -a 256 "$WORK_DIR/$ARCHIVE" | awk '{print $1}')"
else
  err "need sha256sum or shasum for checksum verification"
fi
[ "$EXPECTED" = "$ACTUAL" ] || err "checksum mismatch: expected $EXPECTED got $ACTUAL"
info "checksum ok"

tar -xzf "$WORK_DIR/$ARCHIVE" -C "$WORK_DIR"
SRC_DIR="$WORK_DIR/veric-${VERSION}"
[ -x "$SRC_DIR/veric" ] || err "archive did not contain veric binary at $SRC_DIR/veric"

mkdir -p "$BIN_DIR"
install -m 0755 "$SRC_DIR/veric" "$BIN_DIR/veric"
info "installed $BIN_DIR/veric"

# Post-install sanity + PATH hint
case ":${PATH:-}:" in
  *":$BIN_DIR:"*) : ;;
  *) printf "\nveric-install: %s is not on PATH. Add it with:\n  export PATH=\"%s:\$PATH\"\n" "$BIN_DIR" "$BIN_DIR" ;;
esac

"$BIN_DIR/veric" --version 2>/dev/null || "$BIN_DIR/veric" || true
