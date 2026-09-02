#!/usr/bin/env bash
# Builds the release bundle and registers it with the desktop.
#
#   scripts/install.sh              # build, then install
#   scripts/install.sh --no-build   # install what is already built
#   scripts/install.sh --uninstall
#
# Everything lands under ~/.local/share, so no root is needed. The bundle is
# copied there rather than linked: a .desktop Exec records an absolute path,
# and pointing it at build/ means a `flutter clean` silently breaks the menu
# entry.
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
PREFIX="$DATA/$APP_ID"
BIN="${XDG_BIN_HOME:-$HOME/.local/bin}"
SIZES=(16 24 32 48 64 128 256 512)

refresh_caches() {
    # Both are best-effort: GNOME picks the entry up either way, just later.
    gtk-update-icon-cache -f -t "$ICONS" >/dev/null 2>&1 || true
    update-desktop-database "$APPS" >/dev/null 2>&1 || true
}

if [[ "${1:-}" == "--uninstall" ]]; then
    rm -fv "$APPS/$APP_ID.desktop" "$BIN/morphosis"
    for s in "${SIZES[@]}"; do
        rm -fv "$ICONS/${s}x${s}/apps/$APP_ID.png"
    done
    rm -rfv "$PREFIX"
    refresh_caches
    echo "==> Uninstalled."
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
rm -rf "$PREFIX"
mkdir -p "$PREFIX"
cp -a "$BUNDLE/." "$PREFIX/"

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
echo
echo "The icon is matched by app id, not by file path: the window reports"
echo "$APP_ID, which is why the .desktop and the icons carry that name."
