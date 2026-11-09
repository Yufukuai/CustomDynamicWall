#!/bin/bash
# Install a custom video as a macOS Aerial wallpaper (appears in System Settings > Wallpaper > Aerials).
#
#   ./install.sh install <video> "<Name>" [options]
#   ./install.sh remove  <UUID>           [--category Custom] [--slot-key url-…]
#
# Options (install):  --category NAME (Custom)   --mbps N (30)   --seconds N (encode only the first N s)   --id UUID
#                     --fps F (239.76)  --size WxH (3840x2160)  --fit crop|stretch (crop)  --software
#                     --no-convert  install the file exactly as given; stops with an error if it fails `aerialize verify`
#                                   (without it, a file that already passes verification is also used as is)
#                     --replace     update the existing entry of the same name (same id, file replaced) instead of refusing
#                     --force       skip the duplicate checks and add another entry/copy anyway
#                     --slot-key url-4K-SDR-240FPS   (auto-detected from entries.json; only that slot is verified)
#
# Steps: (1) make the video Aerial-compatible if it isn't already, (2) back up entries.json + Aerial.sqlite to
# ./backups/<timestamp>/, (3) copy the video + preview into /Library/Application Support/com.apple.idleassetsd,
# (4) register it in entries.json and Aerial.sqlite, (5) restart idleassetsd + WallpaperVideoExtension.
# Steps 3-5 use sudo. No SIP changes, no debuggers.
#
# Test hooks: IDLE_DIR=<copy of the idleassetsd folder> NO_SUDO=1 runs against a copy, without sudo or restarts.
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
CATEGORY=Custom; MBPS=30; SECONDS_LIMIT=""; SLOT_KEY=""; NO_CONVERT=""; FORCE=""; REPLACE=""; ID_GIVEN=""; ENC=(); VER=()
while [ $# -gt 0 ]; do case "$1" in
  --category) CATEGORY="$2"; shift 2;; --id) ID="$2"; ID_GIVEN=1; shift 2;; --mbps) MBPS="$2"; shift 2;; --seconds) SECONDS_LIMIT="$2"; shift 2;;
  --slot-key) SLOT_KEY="$2"; shift 2;;
  --fps) ENC+=(--fps "$2"); VER+=(--fps "$2"); shift 2;; --size) ENC+=(--size "$2"); VER+=(--size "$2"); shift 2;;
  --fit) ENC+=(--fit "$2"); shift 2;; --software) ENC+=(--software); shift;;
  --no-convert) NO_CONVERT=1; shift;; --force) FORCE=1; shift;; --replace) REPLACE=1; shift;;
  *) die "unknown option $1";; esac; done

# --- environment: warn rather than refuse; only macOS 15 / Apple Silicon has been tested
[ "$(uname)" = Darwin ] || die "this only works on macOS"
OSV="$(sw_vers -productVersion)"; ARCH="$(uname -m)"
[ "${OSV%%.*}" -ge 14 ] 2>/dev/null || echo "warning: macOS $OSV — the wallpaper video extension this targets appeared in macOS 14; untested here"
[ "${OSV%%.*}" = 15 ] && [ "$ARCH" = arm64 ] || echo "warning: tested only on macOS 15 / Apple Silicon (this is macOS $OSV, $ARCH). The result is checked with 'aerialize verify' before install."
[ -d "$IDLE_DIR/Customer" ] || die "$IDLE_DIR/Customer not found — has Aerial been downloaded at least once on this Mac (System Settings > Wallpaper > Aerials)?"
command -v python3 >/dev/null && command -v sqlite3 >/dev/null || die "need python3 and sqlite3"

# --- which slot does this macOS use? (the url-* key shared by Apple's assets in entries.json)
if [ -z "$SLOT_KEY" ]; then
  SLOT_KEY="$(python3 -I - "$IDLE_DIR/Customer/entries.json" <<'PY'
import json, sys, collections
d = json.load(open(sys.argv[1]))
c = collections.Counter(k for a in d["assets"] for k in a if k.startswith("url-"))
print(c.most_common(1)[0][0] if c else "")
PY
)"
  [ -n "$SLOT_KEY" ] || die "no url-* keys found in entries.json; pass --slot-key"
fi
SLOT_DIR="$(echo "${SLOT_KEY#url-}" | tr -d -)"
[ "$SLOT_KEY" = url-4K-SDR-240FPS ] || echo "warning: slot $SLOT_KEY is untested; the encoder defaults (239.76 fps, 3840x2160) are for url-4K-SDR-240FPS — pass --fps/--size to match your slot"
ID="$(echo "${ID:-$(uuidgen)}" | tr a-z A-Z)"

backup() {
  local b="$HERE/backups/$(date +%Y%m%d-%H%M%S)"; mkdir -p "$b"
  cp -p "$IDLE_DIR/Customer/entries.json" "$b/entries.json"
  sqlite3 -readonly "$IDLE_DIR/Aerial.sqlite" ".backup '$b/Aerial.sqlite'" 2>/dev/null \
    || priv sqlite3 "$IDLE_DIR/Aerial.sqlite" ".backup '$b/Aerial.sqlite'"   # read-only open of a WAL db fails if no -shm exists yet
  echo "backup: $b"
}
restart() { [ -n "${NO_SUDO:-}" ] || { priv killall idleassetsd WallpaperVideoExtension 2>/dev/null || true; }; }
catalog() { python3 -I "$HERE/catalog.py" "$@" --dir "$IDLE_DIR" --id "$ID" --category "$CATEGORY" --slot-key "$SLOT_KEY"; }

# --- duplicate check 1 (before the slow encode): is an entry with this name already registered?
if [ "$cmd" = install ] && [ -z "$ID_GIVEN" ] && [ -z "$FORCE" ]; then
  if EXISTING="$(catalog entries find --name "$NAME" 2>/dev/null)"; then
    if [ -n "$REPLACE" ]; then ID="$EXISTING"; echo "--replace: updating existing entry \"$NAME\" ($ID)"
    else die "an entry named \"$NAME\" already exists in category $CATEGORY ($EXISTING). Use --replace to update it, --force to add another one, or './install.sh remove $EXISTING' first."; fi
  fi
fi

if [ "$cmd" = remove ]; then
  backup
  catalog entries remove | cat; catalog sql remove > "$BUILD/remove.sql"
  priv sqlite3 "$IDLE_DIR/Aerial.sqlite" < "$BUILD/remove.sql"
  priv rm -f "$IDLE_DIR/Customer/$SLOT_DIR/$ID.mov" "$IDLE_DIR/snapshots/asset-preview-$ID.jpg"
  restart; echo "removed $ID"; exit 0
fi

# --- build the tool, make the video compatible
command -v swiftc >/dev/null || die "swiftc not found — install Xcode command line tools: xcode-select --install"
swiftc -O "$HERE/aerialize.swift" -o "$BUILD/aerialize" 2>/dev/null || die "failed to compile aerialize.swift"
if [ -n "$NO_CONVERT" ]; then
  [ -z "$SECONDS_LIMIT" ] && [ ${#ENC[@]} -eq 0 ] || die "--no-convert cannot be combined with encoding options (--seconds/--fps/--size/--fit/--software)"
  "$BUILD/aerialize" verify "$VIDEO" ${VER[@]+"${VER[@]}"} | tail -12 || true
  "$BUILD/aerialize" verify "$VIDEO" ${VER[@]+"${VER[@]}"} >/dev/null 2>&1 || die "$VIDEO does not pass verification, so it was not installed (see FAIL lines above). Re-run without --no-convert to convert it."
  echo "--no-convert: installing the file as is"; READY="$VIDEO"
elif [ -z "$SECONDS_LIMIT" ] && [ ${#ENC[@]} -eq 0 ] && "$BUILD/aerialize" verify "$VIDEO" >/dev/null 2>&1; then
  echo "input already passes verification — using it as is"; READY="$VIDEO"
else
  READY="$BUILD/$ID.mov"; echo "encoding (about 4 min per minute of 4K video on Apple Silicon)…"
  "$BUILD/aerialize" encode "$VIDEO" "$READY" --mbps "$MBPS" ${SECONDS_LIMIT:+--seconds "$SECONDS_LIMIT"} ${ENC[@]+"${ENC[@]}"}
  "$BUILD/aerialize" verify "$READY" ${VER[@]+"${VER[@]}"} | tail -9
fi
"$BUILD/aerialize" thumb "$READY" "$BUILD/$ID.jpg"

# --- duplicate check 2: is a byte-identical file already in the slot (e.g. a leftover after a macOS update)?
SKIP_COPY=""
if [ -z "$FORCE" ]; then
  SIZE="$(stat -f%z "$READY")"; HASH=""; DUP_ID=""
  for f in "$IDLE_DIR/Customer/$SLOT_DIR"/*.mov; do
    [ -e "$f" ] && [ "$(stat -f%z "$f")" = "$SIZE" ] || continue
    [ -n "$HASH" ] || HASH="$(shasum -a 256 "$READY" | cut -d' ' -f1)"
    if [ "$(shasum -a 256 "$f" | cut -d' ' -f1)" = "$HASH" ]; then DUP_ID="$(basename "$f" .mov | tr a-z A-Z)"; break; fi
  done
  if [ -n "$DUP_ID" ]; then
    if REG="$(python3 -I "$HERE/catalog.py" entries has --dir "$IDLE_DIR" --id "$DUP_ID" --slot-key "$SLOT_KEY" 2>/dev/null)"; then
      echo "already installed: this exact video is in the wallpaper storage as \"$REG\" ($DUP_ID). Nothing to do. (--force adds another copy.)"; exit 0
    fi
    echo "found an identical video in the slot ($DUP_ID) with no catalog entry (leftover after an update?) — re-registering it instead of copying a duplicate"
    ID="$DUP_ID"; SKIP_COPY=1
  fi
fi

# --- install
backup
catalog sql add --name "$NAME" > "$BUILD/add.sql"
priv mkdir -p "$IDLE_DIR/Customer/$SLOT_DIR" "$IDLE_DIR/snapshots"
[ -n "$SKIP_COPY" ] || priv cp "$READY" "$IDLE_DIR/Customer/$SLOT_DIR/$ID.mov"
priv cp "$BUILD/$ID.jpg" "$IDLE_DIR/snapshots/asset-preview-$ID.jpg"
if [ -n "${NO_SUDO:-}" ]; then catalog entries add --name "$NAME"; else
  # entries.json is root-owned on a stock system; run the editor as root, in isolated (-I) mode
  sudo python3 -I "$HERE/catalog.py" entries add --dir "$IDLE_DIR" --id "$ID" --name "$NAME" --category "$CATEGORY" --slot-key "$SLOT_KEY"; fi
priv sqlite3 "$IDLE_DIR/Aerial.sqlite" < "$BUILD/add.sql"
restart
echo "installed \"$NAME\" ($ID). Open System Settings > Wallpaper > Aerials > $CATEGORY and select it."
echo "undo: $0 remove $ID"
