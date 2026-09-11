#!/bin/sh
# sbmerlin installer — fetches the addon tree and runs its own installer.
#   curl -fsSL <raw-url>/install.sh | sh
# Override the source with SBM_REPO_URL (any archive that unpacks to sbmerlin/).

set -e

SBM_REPO_URL="${SBM_REPO_URL:-https://github.com/lavrentijav/asuswrt-merlin-singbox/archive/refs/heads/main.tar.gz}"
DEST="/jffs/addons/sbmerlin"
TMP="/opt/tmp/sbmerlin-install.$$"

echo "sbmerlin installer"

[ -d /opt/bin ] || { echo "Entware not found. Install it from amtm first."; exit 1; }
[ -d /jffs/addons ] || mkdir -p /jffs/addons

for t in curl jq; do
	[ -x "/opt/bin/$t" ] || { echo "installing $t ..."; opkg update >/dev/null 2>&1; opkg install "$t" >/dev/null 2>&1; }
done

mkdir -p "$TMP"
echo "downloading $SBM_REPO_URL"
/opt/bin/curl -fsSL --max-time 120 -o "$TMP/src.tar.gz" "$SBM_REPO_URL"
tar xzf "$TMP/src.tar.gz" -C "$TMP"

SRC=$(ls -d "$TMP"/*/sbmerlin 2>/dev/null | head -1)
[ -n "$SRC" ] || SRC=$(ls -d "$TMP"/sbmerlin 2>/dev/null | head -1)
[ -n "$SRC" ] || { echo "archive does not contain a sbmerlin/ directory"; rm -rf "$TMP"; exit 1; }

mkdir -p "$DEST"
cp -rf "$SRC/." "$DEST/"
chmod 755 "$DEST/sbmerlin.sh"
rm -rf "$TMP"

sh "$DEST/sbmerlin.sh" install
