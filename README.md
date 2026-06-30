# FFmpeg CMake [![Build Status]][actions]

[Build Status]: https://github.com/HaydnTrigg/FFmpeg-Cmake/actions/workflows/build.yml/badge.svg
[actions]: https://github.com/HaydnTrigg/FFmpeg-Cmake/actions

A CMake build system for [FFmpeg](https://ffmpeg.org) targeting Windows with MSVC. FFmpeg's upstream build uses a `./configure` script that requires a Unix-like environment (MSYS2, Cygwin, WSL). This project replaces that step with a self-contained CMakeLists.txt that works with Visual Studio and the MSVC toolchain.

FFmpeg is a collection of libraries and tools to process multimedia content such as audio, video, subtitles and related metadata.

## What this project provides

- A single `CMakeLists.txt` that builds FFmpeg's core libraries as Windows DLLs
- Pre-generated `config.h` and `config_components.h` tuned for Windows/MSVC (normally produced by `./configure`)
- Automatic NASM acquisition via vcpkg for x86/x64 SIMD assembly optimisations
- Support for Win32, x64, and ARM64 targets
- GitHub Actions CI that builds all three architectures across all four CMake build types
- Per-component build configuration: every codec, parser and bitstream filter is exposed as a CMake option

## Configuring which components are built

Every FFmpeg component (decoder, encoder, parser, bitstream filter, …) is exposed as a
`FFMPEG_CONFIG_<NAME>` CMake boolean that mirrors the corresponding `CONFIG_<NAME>` macro.
Disabling an option both sets `CONFIG_<NAME> 0` in the generated `config_components.h` and
removes the component from the generated `codec_list.c` / `parser_list.c` / `bsf_list.c`, so it
is genuinely excluded (no unresolved-symbol link errors).

- `FFMPEG_USE_DEFAULT_CONFIG` (default `ON`) controls the default state of every component option.
  Leave it on to build everything (the default), or set it to `OFF` to start from a blank slate and
  opt in to only the components you need.

```sh
# Default: build all components
cmake -B Build

# Build only what you opt into
cmake -B Build -DFFMPEG_USE_DEFAULT_CONFIG=OFF -DFFMPEG_CONFIG_AAC_DECODER=ON -DFFMPEG_CONFIG_H264_DECODER=ON

# Build everything except one codec
cmake -B Build -DFFMPEG_CONFIG_AAC_DECODER=OFF
```

## Libraries

* `libavcodec` provides implementation of a wider range of codecs.
* ~~`libavformat` implements streaming protocols, container formats and basic I/O access.~~
* `libavutil` includes hashers, decompressors and miscellaneous utility functions.
* ~~`libavfilter` provides means to alter decoded audio and video through a directed graph of connected filters.~~
* ~~`libavdevice` provides an abstraction to access capture and playback devices.~~
* `libswresample` implements audio mixing and resampling routines.
* ~~`libswscale` implements color conversion and scaling routines.~~

## FFmpeg source

The FFmpeg source tree is included as a git submodule pointing to the official [FFmpeg repository](https://github.com/FFmpeg/FFmpeg). It lives in the `FFmpeg/` subdirectory and is not modified by this project.

## License

FFmpeg is mainly LGPL-licensed with optional components licensed under GPL. This CMake build system wrapper is provided under the same terms. Refer to **FFmpeg/LICENSE.md** for detailed information.
