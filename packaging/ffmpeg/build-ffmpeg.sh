#!/bin/bash
# Builds the minimal LGPL ffmpeg that EasyBoard ships (see THIRD-PARTY.md): only what saving sounds
# as MP3, OGG, FLAC, Opus, M4A and WAV needs, with LAME, libogg, libvorbis and libopus built in.
# Everything is built from source, so nothing GPL ends up in it.
#
# Runs on Linux, macOS and Windows (in an MSYS2 MINGW64 shell). Needs a C compiler, make, nasm,
# pkg-config, curl and tar.
#
# Usage: packaging/ffmpeg/build-ffmpeg.sh <output file> [arm64|x86_64]
#   The CPU type is for macOS only (default: this Mac's); the other one is cross-compiled.
#   Intermediate files go to $FFMPEG_WORK (default: a folder in /tmp).
set -euo pipefail

FFMPEG_VERSION=7.1.1
LAME_VERSION=3.100
OGG_VERSION=1.3.5
VORBIS_VERSION=1.3.7
OPUS_VERSION=1.5.2

OUT="${1:?usage: build-ffmpeg.sh <output file> [arm64|x86_64]}"
mkdir -p "$(dirname "$OUT")"
OUT="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"
OS="$(uname -s)"
JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"

HOST_ARGS=()       # for the libraries' configure scripts
FF_ARGS=()         # for ffmpeg's configure
case "$OS" in
  Darwin)
    ARCH="${2:-$(uname -m)}"
    export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-12.0}"
    export CC="clang -arch $ARCH"
    if [ "$ARCH" != "$(uname -m)" ]; then
      case "$ARCH" in arm64) HOST_ARGS=(--host=aarch64-apple-darwin) ;; *) HOST_ARGS=(--host=x86_64-apple-darwin) ;; esac
      FF_ARGS=(--enable-cross-compile --target-os=darwin --arch="$ARCH")
    fi
    FF_ARGS+=(--cc="$CC")
    ;;
  MINGW*|MSYS*)
    ARCH=x86_64
    export CC=gcc
    # no libgcc / winpthread DLLs needed next to ffmpeg.exe
    FF_ARGS=(--extra-ldflags=-static)
    ;;
  *)
    ARCH="$(uname -m)"
    export CC=gcc
    ;;
esac

WORK="$(mkdir -p "${FFMPEG_WORK:-/tmp/easyboard-ffmpeg-build}/$ARCH" && cd "${FFMPEG_WORK:-/tmp/easyboard-ffmpeg-build}/$ARCH" && pwd)"
PREFIX="$WORK/prefix"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
export CFLAGS="-O2 -I$PREFIX/include"
export LDFLAGS="-L$PREFIX/lib"
echo "ffmpeg $FFMPEG_VERSION for $OS $ARCH in $WORK"

# fetch <url>: downloads and unpacks into $WORK (once)
fetch() {
  local file="$WORK/$(basename "$1")"
  [ -f "$file" ] || curl -L --fail --retry 3 -o "$file" "$1"
  tar -xf "$file" -C "$WORK"
}

# autotools <folder> <configure args...>: builds and installs one library into $PREFIX
autotools() {
  local dir="$WORK/$1"; shift
  (cd "$dir" &&
    ./configure --prefix="$PREFIX" --disable-shared --enable-static --with-pic "${HOST_ARGS[@]+"${HOST_ARGS[@]}"}" "$@" &&
    make -j"$JOBS" && make install)
}

fetch "https://downloads.sourceforge.net/project/lame/lame/$LAME_VERSION/lame-$LAME_VERSION.tar.gz"
autotools "lame-$LAME_VERSION" --disable-frontend --disable-decoder

fetch "https://downloads.xiph.org/releases/ogg/libogg-$OGG_VERSION.tar.gz"
autotools "libogg-$OGG_VERSION"

fetch "https://downloads.xiph.org/releases/vorbis/libvorbis-$VORBIS_VERSION.tar.gz"
# newer Apple linkers reject this old flag
sed -i.bak 's/-force_cpusubtype_ALL//g' "$WORK/libvorbis-$VORBIS_VERSION/configure"
autotools "libvorbis-$VORBIS_VERSION" --with-ogg="$PREFIX" --disable-examples --disable-docs

fetch "https://downloads.xiph.org/releases/opus/opus-$OPUS_VERSION.tar.gz"
autotools "opus-$OPUS_VERSION" --disable-doc --disable-extra-programs

fetch "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz"
cd "$WORK/ffmpeg-$FFMPEG_VERSION"
./configure --prefix="$PREFIX" --pkg-config-flags=--static \
  --extra-cflags="-I$PREFIX/include" --extra-ldflags="-L$PREFIX/lib" \
  --disable-everything --disable-autodetect --disable-network --enable-small \
  --disable-doc --disable-ffplay --disable-ffprobe --disable-debug \
  --enable-protocol=file,pipe --enable-demuxer=wav --enable-decoder=pcm_s16le,pcm_s24le,pcm_f32le \
  --enable-encoder=libmp3lame,libvorbis,libopus,flac,aac,pcm_s16le \
  --enable-muxer=mp3,ogg,opus,flac,ipod,adts,wav --enable-parser=aac,flac,opus,vorbis \
  --enable-filter=aresample,aformat,anull,atrim \
  --enable-libmp3lame --enable-libvorbis --enable-libopus \
  "${FF_ARGS[@]+"${FF_ARGS[@]}"}"
make -j"$JOBS"

EXE=ffmpeg
[ -f ffmpeg.exe ] && EXE=ffmpeg.exe
cp "$EXE" "$OUT"
chmod +x "$OUT"
echo "Done: $OUT"
