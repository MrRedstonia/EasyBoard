# Third-party software

EasyBoard itself is released under the MIT License (see [`LICENSE`](LICENSE)). It uses or ships the following.

## Qt 6 (LGPL v3)
Dynamically linked and shipped unmodified, so you can replace it with your own build:
next to `easyboard.exe` on Windows, in `EasyBoard.app/Contents/Frameworks` on macOS, and inside the
AppImage, `.deb`, `.rpm` and `.tar.gz` on Linux.
Qt is a product of The Qt Company and contributors.
Source and license: https://www.qt.io/licensing/ and https://download.qt.io/official_releases/qt/

## FFmpeg (LGPL v2.1+)
`ffmpeg` (`ffmpeg.exe` on Windows) is a separate program that EasyBoard starts to save sounds as
MP3, OGG, FLAC, Opus or M4A. EasyBoard is not linked against it.

It is our own minimal build of FFmpeg 7.1.1, made the same way for every platform, **without**
`--enable-gpl` and `--enable-nonfree`:

```
--disable-everything --disable-autodetect --disable-network --enable-small
--enable-protocol=file,pipe --enable-demuxer=wav --enable-decoder=pcm_s16le,pcm_s24le,pcm_f32le
--enable-encoder=libmp3lame,libvorbis,libopus,flac,aac,pcm_s16le
--enable-muxer=mp3,ogg,opus,flac,ipod,adts,wav --enable-parser=aac,flac,opus,vorbis
--enable-filter=aresample,aformat,anull,atrim
--enable-libmp3lame --enable-libvorbis --enable-libopus
```

- Source: https://ffmpeg.org/releases/ffmpeg-7.1.1.tar.xz. The build script is [`packaging/ffmpeg/build-ffmpeg.sh`](packaging/ffmpeg/build-ffmpeg.sh).
- License text: https://www.gnu.org/licenses/old-licenses/lgpl-2.1.txt
- Statically linked inside it: LAME 3.100 (LGPL v2+), libogg 1.3.5 and libvorbis 1.3.7 (BSD-3-Clause), libopus 1.5.2 (BSD-3-Clause).

FFmpeg is a trademark of Fabrice Bellard. EasyBoard is not affiliated with or endorsed by the FFmpeg project.

## PulseAudio client library (Linux, LGPL v2.1+)
`libpulse` is a system library, dynamically linked and not shipped with EasyBoard.

## Rust crates
Compiled into EasyBoard. Most are under MIT and/or Apache-2.0. The others:

| Crate | License |
| --- | --- |
| [Symphonia](https://github.com/pdeljanov/Symphonia) (audio decoding) | MPL-2.0. Unmodified; source at the link. |
| `option-ext` | MPL-2.0 |
| ICU4X crates (`icu_*`, `zerovec`, …) | Unicode-3.0 |
| `ring`, `rustls-webpki`, `untrusted`, `libloading` | ISC (`ring` also Apache-2.0) |
| `webpki-roots` | CDLA-Permissive-2.0 |
| `zlib-rs`, `foldhash` | Zlib |
| `bindgen`, `subtle` | BSD-3-Clause |

Run `cargo license` or `cargo about generate` in the source folder for the full list.

## VB-Audio Virtual Cable (Windows and macOS)
Not included. Users install it themselves from https://vb-audio.com/Cable/ (donationware; it may not be
redistributed without permission from VB-Audio).

## MyInstants (Sound library)
The Sound library lists and downloads sounds from https://www.myinstants.com using its public API
(https://www.myinstants.com/api/v1/).
EasyBoard is not affiliated with or endorsed by MyInstants. The sounds belong to their uploaders.
