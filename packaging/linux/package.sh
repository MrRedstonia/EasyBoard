#!/bin/bash
# Packages the already built Linux binary (target/release/easyboard) as:
#   dist/EasyBoard-<version>-x86_64.AppImage
#   dist/EasyBoard-<version>-linux-x86_64.tar.gz
#   dist/easyboard_<version>_amd64.deb
#   dist/easyboard-<version>.x86_64.rpm
# Qt is bundled in all of them, so they work on distributions that ship an older Qt.
#
# Needs: QMAKE (the Qt 6 qmake used for the build), curl, ruby + `gem install fpm`, rpm (for the .rpm).
# Best run on an old Ubuntu (22.04), so the result runs on most distributions.
#
# Usage: packaging/linux/package.sh /path/to/ffmpeg
set -euo pipefail
cd "$(dirname "$0")/../.."

FFMPEG="${1:?usage: package.sh /path/to/ffmpeg}"
: "${QMAKE:?set QMAKE to the Qt 6 qmake that was used for the build}"
[ -x target/release/easyboard ] || { echo "build first: cargo build --release"; exit 1; }
VERSION=$(grep -m1 '^version' Cargo.toml | sed 's/.*"\(.*\)".*/\1/')
export VERSION
echo "EasyBoard $VERSION"

WORK="$(mktemp -d)"
mkdir -p dist
export APPIMAGE_EXTRACT_AND_RUN=1   # lets the AppImage tools run without FUSE (CI)

# --- linuxdeploy + its Qt plugin: collects the Qt libraries, plugins and QML modules
cd "$WORK"
curl -L --fail -o linuxdeploy https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage
curl -L --fail -o linuxdeploy-plugin-qt https://github.com/linuxdeploy/linuxdeploy-plugin-qt/releases/download/continuous/linuxdeploy-plugin-qt-x86_64.AppImage
chmod +x linuxdeploy linuxdeploy-plugin-qt
cd - >/dev/null
export PATH="$WORK:$PATH"

cp assets/app_icon.png "$WORK/easyboard.png"
export QML_SOURCES_PATHS="$PWD/qml"
export NO_STRIP=1

APPDIR="$WORK/AppDir"
"$WORK/linuxdeploy" --appdir "$APPDIR" \
  --executable target/release/easyboard \
  --desktop-file packaging/easyboard.desktop \
  --icon-file "$WORK/easyboard.png" \
  --plugin qt

# ffmpeg sits next to the program, where EasyBoard looks for it
cp "$FFMPEG" "$APPDIR/usr/bin/ffmpeg"
chmod +x "$APPDIR/usr/bin/ffmpeg"
cp LICENSE THIRD-PARTY.md "$APPDIR/usr/"

# --- AppImage
"$WORK/linuxdeploy" --appdir "$APPDIR" --output appimage
mv EasyBoard*.AppImage "dist/EasyBoard-$VERSION-x86_64.AppImage"

# --- tar.gz (run bin/easyboard)
TAR="EasyBoard-$VERSION-linux-x86_64"
rm -rf "$WORK/$TAR"
cp -a "$APPDIR/usr" "$WORK/$TAR"
cp packaging/easyboard.desktop "$WORK/$TAR/"
cp "$WORK/easyboard.png" "$WORK/$TAR/"
tar -czf "dist/$TAR.tar.gz" -C "$WORK" "$TAR"

# --- .deb and .rpm: everything under /opt/easyboard, plus a launcher, an icon and /usr/bin/easyboard
ROOT="$WORK/pkgroot"
mkdir -p "$ROOT/opt" "$ROOT/usr/bin" "$ROOT/usr/share/applications" "$ROOT/usr/share/icons/hicolor/512x512/apps"
cp -a "$APPDIR/usr" "$ROOT/opt/easyboard"
ln -s /opt/easyboard/bin/easyboard "$ROOT/usr/bin/easyboard"
cp packaging/easyboard.desktop "$ROOT/usr/share/applications/easyboard.desktop"
cp "$WORK/easyboard.png" "$ROOT/usr/share/icons/hicolor/512x512/apps/easyboard.png"

COMMON=(-s dir -n easyboard -v "$VERSION" --license MIT --maintainer "MrRedstonia <contact@mrredstonia.com>"
        --url https://github.com/MrRedstonia/EasyBoard
        --description "EasyBoard - a cross-platform soundboard with a virtual microphone input"
        -C "$ROOT" .)
# pactl and parec (virtual inputs, App routing) are in pulseaudio-utils on both
fpm -t deb -p "dist/easyboard_${VERSION}_amd64.deb" -a amd64 -d libgl1 -d libxkbcommon0 -d libpulse0 -d pulseaudio-utils "${COMMON[@]}"
fpm -t rpm -p "dist/easyboard-${VERSION}.x86_64.rpm" -a x86_64 -d mesa-libGL -d libxkbcommon -d pulseaudio-libs -d pulseaudio-utils "${COMMON[@]}"

ls -la dist
