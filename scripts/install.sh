#!/usr/bin/env bash
# Builds the release bundle and registers it with the desktop.
#
#   scripts/install.sh              # build, then install
#   scripts/install.sh --no-build   # install what is already built
#   scripts/install.sh --uninstall
#
# No root is needed. The bundle is copied rather than linked: a .desktop Exec
# records an absolute path, and pointing it at build/ means a `flutter clean`
# silently breaks the menu entry.
#
# The bundle goes to ~/.local/lib/morphosis and NOT to
# ~/.local/share/com.morphosis.morphosis, which is where the catalogue lives.
# This script begins by deleting its own prefix, so installing over the data
# directory would destroy every keyword and every stored edit on each install,
# with no error. The two must stay separate; see PLAN.md sections 3 and 12.
#
# Installing is what makes the icon appear at all under Wayland. A compositor
# ignores the icon a process sets on its own window and instead matches the
# window's app id against a .desktop file, taking the icon from there. On X11
# the in-process icon works by itself, but installing is still what puts the
# app in the menu.
set -euo pipefail

APP_ID="com.morphosis.morphosis"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
APPS="$DATA/applications"
ICONS="$DATA/icons/hicolor"
BIN="${XDG_BIN_HOME:-$HOME/.local/bin}"
PREFIX="${XDG_LIB_HOME:-$HOME/.local/lib}/morphosis"
SIZES=(16 24 32 48 64 128 256 512)

# The data directory: where the catalogue lives, and where the bundle used to
# be installed before it needed that space. Never deleted by this script.
DATA_DIR="$DATA/$APP_ID"

# A tripwire on the mistake this layout exists to prevent. If PREFIX is ever
# pointed back at the data directory, the rm -rf below is a silent data loss
# rather than a reinstall, so refuse instead.
assert_prefix_is_not_data() {
    if [[ -e "$PREFIX/catalog.db" ]]; then
        echo "Refusing to touch $PREFIX: it holds catalog.db." >&2
        echo "The bundle prefix and the data directory must not be the same" >&2
        echo "place. See PLAN.md section 3." >&2
        exit 1
    fi
}

# Clear out a bundle left in the data directory by an older install, and
# nothing else. A blanket rm here is exactly what would take the catalogue
# with it, so only the three entries a bundle consists of are removed.
clear_legacy_bundle() {
    [[ -e "$DATA_DIR/morphosis" ]] || return 0
    echo "==> Clearing an old bundle out of $DATA_DIR"
    rm -rf "$DATA_DIR/morphosis" "$DATA_DIR/lib" "$DATA_DIR/data"
    # Fails, harmlessly, when the catalogue is in there. That is the point.
    rmdir "$DATA_DIR" 2>/dev/null || true
}

refresh_caches() {
    # Both are best-effort: GNOME picks the entry up either way, just later.
    gtk-update-icon-cache -f -t "$ICONS" >/dev/null 2>&1 || true
    update-desktop-database "$APPS" >/dev/null 2>&1 || true
}

if [[ "${1:-}" == "--uninstall" ]]; then
    assert_prefix_is_not_data
    rm -fv "$APPS/$APP_ID.desktop" "$BIN/morphosis"
    for s in "${SIZES[@]}"; do
        rm -fv "$ICONS/${s}x${s}/apps/$APP_ID.png"
    done
    rm -rfv "$PREFIX"
    clear_legacy_bundle
    refresh_caches
    echo "==> Uninstalled."
    if [[ -e "$DATA_DIR/catalog.db" ]]; then
        echo "    The catalogue was left at $DATA_DIR/catalog.db."
        echo "    Delete it by hand to discard keywords and stored edits."
    fi
    exit 0
fi

if [[ "${1:-}" != "--no-build" ]]; then
    echo "==> Building the release bundle..."
    (cd "$REPO" && flutter build linux --release)
fi

BUNDLE="$REPO/build/linux/x64/release/bundle"
if [[ ! -x "$BUNDLE/morphosis" ]]; then
    echo "No release bundle at $BUNDLE." >&2
    echo "Run without --no-build, or: flutter build linux --release" >&2
    exit 1
fi

echo "==> Installing the bundle into $PREFIX"
assert_prefix_is_not_data
rm -rf "$PREFIX"
mkdir -p "$PREFIX"
cp -a "$BUNDLE/." "$PREFIX/"
clear_legacy_bundle

echo "==> Linking $BIN/morphosis"
mkdir -p "$BIN"
ln -sfn "$PREFIX/morphosis" "$BIN/morphosis"

echo "==> Installing icons into $ICONS"
for s in "${SIZES[@]}"; do
    src="$REPO/assets/icon/app_icon_$s.png"
    [[ -f "$src" ]] || continue
    install -Dm644 "$src" "$ICONS/${s}x${s}/apps/$APP_ID.png"
done

echo "==> Installing $APP_ID.desktop into $APPS"
mkdir -p "$APPS"
sed "s|@EXEC@|$PREFIX/morphosis|" \
    "$REPO/linux/packaging/$APP_ID.desktop" > "$APPS/$APP_ID.desktop"
chmod 644 "$APPS/$APP_ID.desktop"

# Catches a malformed entry now rather than as a silent absence in the menu.
if command -v desktop-file-validate >/dev/null 2>&1; then
    desktop-file-validate "$APPS/$APP_ID.desktop" || true
fi

refresh_caches

echo
echo "==> Installed."
echo "    launcher   $APPS/$APP_ID.desktop"
echo "    bundle     $PREFIX/morphosis"
echo "    on PATH    $BIN/morphosis"
echo "    catalogue  $DATA_DIR/catalog.db  (user data, never installed over)"
echo
echo "The icon is matched by app id, not by file path: the window reports"
echo "$APP_ID, which is why the .desktop and the icons carry that name."
