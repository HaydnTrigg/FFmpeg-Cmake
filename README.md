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
