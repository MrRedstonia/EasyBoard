#!/bin/bash
# Builds EasyBoard.app and a .dmg that run on every Mac: Apple Silicon and Intel (a "universal" app).
# With UNIVERSAL=0 it builds only for the kind of Mac this runs on (quicker, for trying things out).
#
# Needs: Rust, Xcode command line tools, Qt 6 for macOS (the official builds, e.g. from the Qt
# installer or aqtinstall, contain both CPU types) and ffmpeg: either one universal binary, or one
# arm64 and one x86_64 binary (they are joined into one). It must be a self-contained build, not
# Homebrew's (that one needs Homebrew's libraries on the Mac it runs on): packaging/ffmpeg/build-ffmpeg.sh
# makes the right one (run it once with arm64 and once with x86_64).
#
# Usage (from anywhere):
#   packaging/macos/build-app.sh [<ffmpeg> [<ffmpeg for the other CPU>]] [/path/to/Qt/6.8.3/macos]
#   (an argument that is a folder is taken as the Qt folder; without ffmpeg the app still works,
#   only saving as MP3/OGG/FLAC/Opus/M4A doesn't)
# Result: dist/EasyBoard.app and dist/EasyBoard-<version>.dmg
set -euo pipefail
cd "$(dirname "$0")/../.."

FFMPEGS=()
QT="${QT_DIR:-$HOME/Qt/6.8.3/macos}"
for a in "$@"; do
  if [ -d "$a" ]; then QT="$a"; else FFMPEGS+=("$a"); fi
done
[ ${#FFMPEGS[@]} -ge 1 ] || echo "WARNING: no ffmpeg given: the app won't be able to save as MP3/OGG/FLAC/Opus/M4A."
export QMAKE="$QT/bin/qmake"
[ -x "$QMAKE" ] || { echo "qmake not found in $QT/bin"; exit 1; }
for f in "${FFMPEGS[@]+"${FFMPEGS[@]}"}"; do [ -x "$f" ] || { echo "ffmpeg not found or not executable: $f"; exit 1; }; done

VERSION=$(grep -m1 '^version' Cargo.toml | sed 's/.*"\(.*\)".*/\1/')
echo "EasyBoard $VERSION"
mkdir -p dist
# the oldest macOS the app runs on (matches LSMinimumSystemVersion below)
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-12.0}"
if [ "${UNIVERSAL:-1}" = "1" ]; then
  # one app for both kinds of Mac (the Intel half is cross-compiled when run on Apple Silicon and vice versa)
  rustup target add aarch64-apple-darwin x86_64-apple-darwin
  cargo build --release --target aarch64-apple-darwin
  cargo build --release --target x86_64-apple-darwin
  lipo -create -output dist/easyboard-bin \
    target/aarch64-apple-darwin/release/easyboard target/x86_64-apple-darwin/release/easyboard
  SUFFIX=universal
else
  # default: an app for the kind of Mac this runs on
  cargo build --release
  cp target/release/easyboard dist/easyboard-bin
  case "$(uname -m)" in arm64) SUFFIX=arm64 ;; *) SUFFIX=x86_64 ;; esac
fi

APP="dist/EasyBoard.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp dist/easyboard-bin "$APP/Contents/MacOS/easyboard"
cp LICENSE THIRD-PARTY.md "$APP/Contents/Resources/"

# icon: AppIcon.icns from assets/app_icon.png
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s assets/app_icon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) assets/app_icon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>EasyBoard</string>
  <key>CFBundleDisplayName</key><string>EasyBoard</string>
  <key>CFBundleIdentifier</key><string>com.mrredstonia.easyboard</string>
  <key>CFBundleExecutable</key><string>easyboard</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>EasyBoard records from your microphone in the Sound Editor and can mix it into the virtual cable.</string>
  <key>NSAudioCaptureUsageDescription</key><string>EasyBoard captures the audio of the apps you choose under App routing and mixes it into the virtual cable.</string>
</dict></plist>
PLIST

# Qt frameworks, plugins and the QML modules the app imports
"$QT/bin/macdeployqt" "$APP" -qmldir=qml
# EasyBoard uses no database: drop the SQL drivers macdeployqt copies anyway (they also complain
# about database libraries that aren't on this Mac)
rm -rf "$APP/Contents/PlugIns/sqldrivers"
lipo -archs "$APP/Contents/MacOS/easyboard"

# ffmpeg: EasyBoard looks next to its own executable
if [ ${#FFMPEGS[@]} -ge 2 ]; then
  lipo -create -output "$APP/Contents/MacOS/ffmpeg" "${FFMPEGS[0]}" "${FFMPEGS[1]}"
elif [ ${#FFMPEGS[@]} -eq 1 ]; then
  cp "${FFMPEGS[0]}" "$APP/Contents/MacOS/ffmpeg"
  case "$(lipo -archs "${FFMPEGS[0]}")" in
    *arm64*x86_64*|*x86_64*arm64*) ;;
    *) echo "WARNING: ffmpeg is only $(lipo -archs "${FFMPEGS[0]}"); saving as MP3/OGG/... won't work on the other kind of Mac." ;;
  esac
fi
[ -f "$APP/Contents/MacOS/ffmpeg" ] && chmod +x "$APP/Contents/MacOS/ffmpeg"
xattr -cr "$APP"

# Ad-hoc signature (a real Developer ID signature + notarization is needed to share the app without warnings)
codesign --force --deep --sign - "$APP"

rm -f "dist/EasyBoard-$VERSION-macOS-$SUFFIX.dmg"
hdiutil create -volname EasyBoard -srcfolder "$APP" -ov -format UDZO "dist/EasyBoard-$VERSION-macOS-$SUFFIX.dmg"
echo "Done: $APP and dist/EasyBoard-$VERSION-macOS-$SUFFIX.dmg"
