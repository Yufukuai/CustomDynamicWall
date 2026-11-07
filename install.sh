#!/bin/bash
# Install a custom video as a macOS Sequoia Aerial wallpaper (appears in System Settings > Wallpaper > Aerials).
#
#   ./install.sh install <video> "<Name>" [--category Custom] [--id UUID] [--mbps 30] [--seconds N]
#   ./install.sh remove  <UUID>                [--category Custom]
#
# What it does: (1) makes the video Aerial-compatible if it isn't already (aerialize.swift encode/verify),
# (2) backs up entries.json + Aerial.sqlite to ./backups/<timestamp>/, (3) copies the video + a preview image into
# /Library/Application Support/com.apple.idleassetsd, (4) registers it in entries.json and Aerial.sqlite,
# (5) restarts idleassetsd + WallpaperVideoExtension. Steps 3-5 need sudo. No SIP changes, no debuggers.
#
# Test hooks: IDLE_DIR=<copy of the idleassetsd folder> NO_SUDO=1 runs everything against a copy without sudo/restarts.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
IDLE_DIR="${IDLE_DIR:-/Library/Application Support/com.apple.idleassetsd}"
BUILD="$HERE/build"; mkdir -p "$BUILD"
priv() { if [ -n "${NO_SUDO:-}" ]; then "$@"; else sudo "$@"; fi; }
die() { echo "error: $*" >&2; exit 1; }

cmd="${1:-}"; shift || true
[ "$cmd" = install ] || [ "$cmd" = remove ] || die "usage: $0 install <video> \"<Name>\" [options] | remove <UUID>"
if [ "$cmd" = install ]; then VIDEO="${1:-}"; NAME="${2:-}"; shift 2 || die "install needs <video> \"<Name>\""; [ -f "$VIDEO" ] || die "no such file: $VIDEO"
else ID="${1:-}"; shift || die "remove needs <UUID>"; fi
CATEGORY=Custom; MBPS=30; SECONDS_LIMIT=""
while [ $# -gt 0 ]; do case "$1" in
  --category) CATEGORY="$2"; shift 2;; --id) ID="$2"; shift 2;; --mbps) MBPS="$2"; shift 2;; --seconds) SECONDS_LIMIT="$2"; shift 2;;
  *) die "unknown option $1";; esac; done
[ -d "$IDLE_DIR/Customer" ] || die "$IDLE_DIR/Customer not found — is this macOS 15 (Sequoia) with Aerial wallpapers downloaded at least once?"
command -v python3 >/dev/null && command -v sqlite3 >/dev/null || die "need python3 and sqlite3"
ID="$(echo "${ID:-$(uuidgen)}" | tr a-z A-Z)"

backup() {
  local b="$HERE/backups/$(date +%Y%m%d-%H%M%S)"; mkdir -p "$b"
  cp -p "$IDLE_DIR/Customer/entries.json" "$b/entries.json"
  sqlite3 -readonly "$IDLE_DIR/Aerial.sqlite" ".backup '$b/Aerial.sqlite'" 2>/dev/null \
    || priv sqlite3 "$IDLE_DIR/Aerial.sqlite" ".backup '$b/Aerial.sqlite'"   # read-only open of a WAL db fails if no -shm exists yet
  echo "backup: $b"
}
restart() { [ -n "${NO_SUDO:-}" ] || { priv killall idleassetsd WallpaperVideoExtension 2>/dev/null || true; }; }
catalog() { python3 -I "$HERE/catalog.py" "$@" --dir "$IDLE_DIR" --id "$ID" --category "$CATEGORY"; }

if [ "$cmd" = remove ]; then
  backup
  catalog entries remove | cat; catalog sql remove > "$BUILD/remove.sql"
  priv sqlite3 "$IDLE_DIR/Aerial.sqlite" < "$BUILD/remove.sql"
  priv rm -f "$IDLE_DIR/Customer/4KSDR240FPS/$ID.mov" "$IDLE_DIR/snapshots/asset-preview-$ID.jpg"
  restart; echo "removed $ID"; exit 0
fi

# --- build the tool, make the video compatible
command -v swiftc >/dev/null || die "swiftc not found — install Xcode command line tools: xcode-select --install"
swiftc -O "$HERE/aerialize.swift" -o "$BUILD/aerialize" 2>/dev/null || die "failed to compile aerialize.swift"
if [ -z "$SECONDS_LIMIT" ] && "$BUILD/aerialize" verify "$VIDEO" >/dev/null 2>&1; then
  echo "input already passes verification — using it as is"; READY="$VIDEO"
else
  READY="$BUILD/$ID.mov"; echo "encoding (hardware HEVC, about 4 min per minute of video)…"
  "$BUILD/aerialize" encode "$VIDEO" "$READY" --mbps "$MBPS" ${SECONDS_LIMIT:+--seconds "$SECONDS_LIMIT"}
  "$BUILD/aerialize" verify "$READY" | tail -9
fi
"$BUILD/aerialize" thumb "$READY" "$BUILD/$ID.jpg"

# --- install
backup
catalog sql add --name "$NAME" > "$BUILD/add.sql"
priv mkdir -p "$IDLE_DIR/Customer/4KSDR240FPS" "$IDLE_DIR/snapshots"
priv cp "$READY" "$IDLE_DIR/Customer/4KSDR240FPS/$ID.mov"
priv cp "$BUILD/$ID.jpg" "$IDLE_DIR/snapshots/asset-preview-$ID.jpg"
if [ -n "${NO_SUDO:-}" ]; then catalog entries add --name "$NAME"; else
  # entries.json is root-owned on a stock system; run the editor as root, keep it under -I (isolated) mode
  sudo python3 -I "$HERE/catalog.py" entries add --dir "$IDLE_DIR" --id "$ID" --name "$NAME" --category "$CATEGORY"; fi
priv sqlite3 "$IDLE_DIR/Aerial.sqlite" < "$BUILD/add.sql"
restart
echo "installed \"$NAME\" ($ID). Open System Settings > Wallpaper > Aerials > $CATEGORY and select it."
echo "undo: $0 remove $ID"
