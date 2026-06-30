cmake_minimum_required(VERSION 3.25)
project(FFmpeg LANGUAGES C)
set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

# ---------------------------------------------------------------------------
# Clang (incl. ClangCL toolset on Visual Studio) workaround
# ---------------------------------------------------------------------------
# Clang 20 — the LLVM bundled with Visual Studio 2026 — ships a broken
# avx10_2bf16intrin.h / avx10_2_512bf16intrin.h. immintrin.h pulls these in
# unconditionally (the include is guarded only by !defined(__SCE__)), and Clang
# always *parses* the bodies of target-attribute intrinsic functions, so the
# header bug is a hard compile error regardless of the target ISA flags. FFmpeg
# uses no AVX10.2 BF16 intrinsics, so skip those headers by predefining their
# include guards. Harmless on Clang versions where the header is correct.
if(CMAKE_C_COMPILER_ID MATCHES "Clang")
    add_compile_definitions(__AVX10_2BF16INTRIN_H __AVX10_2_512BF16INTRIN_H)

    # Clang 19/20 promoted -Wincompatible-pointer-types from a warning to a
    # default-on error (GCC 14 C99-conformance parity). FFmpeg's Win32 atomics
    # shim passes atomic_uint* (int*) to InterlockedExchangeAdd's volatile long*
    # parameter — a benign int*/long* mismatch on Windows (both 32-bit). Downgrade
    # it back to a warning so the Win32/ClangCL build isn't broken by the new default.
    add_compile_options($<$<COMPILE_LANGUAGE:C>:-Wno-error=incompatible-pointer-types>)

    # FFmpeg gives each library its own private copy of certain helper objects
    # (half2float.c, file_open.c, x86/emms.asm, ...). Because avutil is built with
    # WINDOWS_EXPORT_ALL_SYMBOLS, those internal ff_*/avpriv_* symbols are exported
    # from avutil.dll, so avcodec both defines them locally and imports them from
    # avutil. MSVC link.exe silently keeps the local definition; lld-link (used by
    # the ClangCL toolset) instead errors on the duplicate. /FORCE:MULTIPLE makes
    # lld-link match link.exe: the first (local) definition wins.
    add_link_options("/FORCE:MULTIPLE")
endif()

# FFmpeg source tree lives one level below this CMakeLists.txt
set(FFMPEG_SRC ${CMAKE_SOURCE_DIR}/FFmpeg)

# Usage:
#   cmake -B build -G "Visual Studio 18 2026" -A x64
#   cmake --build build --config Release

# ---------------------------------------------------------------------------
# Build configurations: Debug, Test (release-runtime + /Od + PDB), Release (LTO)
# ---------------------------------------------------------------------------
set(CMAKE_CONFIGURATION_TYPES "Debug;Test;Release" CACHE STRING "Available build configurations" FORCE)

# Test: release runtime (/MD), no optimization (/Od), full debug info (/Zi), no assertions
set(CMAKE_C_FLAGS_TEST             "/MD /Od /Zi /DNDEBUG"    CACHE STRING "C flags for Test"              FORCE)
set(CMAKE_SHARED_LINKER_FLAGS_TEST "/DEBUG /INCREMENTAL:NO"  CACHE STRING "Shared linker flags for Test"  FORCE)
set(CMAKE_EXE_LINKER_FLAGS_TEST    "/DEBUG /INCREMENTAL:NO"  CACHE STRING "Exe linker flags for Test"     FORCE)
set(CMAKE_STATIC_LINKER_FLAGS_TEST ""                        CACHE STRING "Static linker flags for Test"  FORCE)

# Release: maximum inlining (/Ob3), intrinsics (/Oi), function-level linking (/Gy),
# string pooling (/GF), skip security cookies (/GS-), then link dead-code elimination
# (/OPT:REF) and COMDAT folding (/OPT:ICF). No debug info.
# Note: MSVC /GL+/LTCG (WPO) is incompatible with CMake's WINDOWS_EXPORT_ALL_SYMBOLS
# because cmake -E __create_def cannot parse /GL "anonymous" LTCG objects.
set(CMAKE_C_FLAGS_RELEASE             "/MD /O2 /Ob3 /Oi /Gy /GF /GS- /DNDEBUG" CACHE STRING "C flags for Release"              FORCE)
set(CMAKE_SHARED_LINKER_FLAGS_RELEASE "/OPT:REF /OPT:ICF /INCREMENTAL:NO"       CACHE STRING "Shared linker flags for Release"  FORCE)
set(CMAKE_EXE_LINKER_FLAGS_RELEASE    "/OPT:REF /OPT:ICF /INCREMENTAL:NO"       CACHE STRING "Exe linker flags for Release"     FORCE)
set(CMAKE_STATIC_LINKER_FLAGS_RELEASE ""                                         CACHE STRING "Static linker flags for Release"  FORCE)


# ---------------------------------------------------------------------------
# vcpkg bootstrap/install helpers  (idempotent; used for NASM/YASM and zlib)
# Sets _vcpkg_root, _vcpkg_exe, _vcpkg_triplet, _vcpkg_installed in caller scope.
# ---------------------------------------------------------------------------
macro(_ffmpeg_vcpkg_ensure)
    if(NOT DEFINED _vcpkg_bootstrapped)
        if(DEFINED ENV{VCPKG_ROOT} AND NOT "$ENV{VCPKG_ROOT}" STREQUAL "")
            set(_vcpkg_root "$ENV{VCPKG_ROOT}")
        else()
            set(_vcpkg_root "${CMAKE_SOURCE_DIR}/vcpkg")
        endif()
        if(WIN32)
            set(_vcpkg_exe  "${_vcpkg_root}/vcpkg.exe")
            set(_vcpkg_boot "${_vcpkg_root}/bootstrap-vcpkg.bat")
            # Tools (NASM) always from x64-windows; libraries match the target platform
            set(_vcpkg_tool_triplet "x64-windows")
            if(CMAKE_GENERATOR_PLATFORM STREQUAL "Win32")
                set(_vcpkg_triplet "x86-windows")
            elseif(CMAKE_GENERATOR_PLATFORM STREQUAL "ARM64")
                set(_vcpkg_triplet "arm64-windows")
            else()
                set(_vcpkg_triplet "x64-windows")
            endif()
        else()
            set(_vcpkg_exe            "${_vcpkg_root}/vcpkg")
            set(_vcpkg_boot           "${_vcpkg_root}/bootstrap-vcpkg.sh")
            set(_vcpkg_triplet        "x64-linux")
            set(_vcpkg_tool_triplet   "x64-linux")
        endif()
        set(_vcpkg_installed      "${_vcpkg_root}/installed/${_vcpkg_triplet}")
        set(_vcpkg_tool_installed "${_vcpkg_root}/installed/${_vcpkg_tool_triplet}")
        if(NOT EXISTS "${_vcpkg_exe}")
            find_package(Git QUIET)
            if(Git_FOUND AND NOT EXISTS "${_vcpkg_root}/.git")
                message(STATUS "Cloning vcpkg into ${_vcpkg_root}")
                execute_process(
                    COMMAND ${GIT_EXECUTABLE} clone --depth 1 https://github.com/microsoft/vcpkg.git "${_vcpkg_root}"
                    RESULT_VARIABLE _vcpkg_clone_result
                )
                if(NOT _vcpkg_clone_result EQUAL 0)
                    message(FATAL_ERROR "Failed to clone vcpkg. Set VCPKG_ROOT or install dependencies manually.")
                endif()
            endif()
            if(EXISTS "${_vcpkg_boot}")
                message(STATUS "Bootstrapping vcpkg")
                execute_process(
                    COMMAND "${_vcpkg_boot}" -disableMetrics
                    WORKING_DIRECTORY "${_vcpkg_root}"
                    RESULT_VARIABLE _vcpkg_boot_result
                )
                if(NOT _vcpkg_boot_result EQUAL 0)
                    message(FATAL_ERROR "vcpkg bootstrap failed.")
                endif()
            endif()
        endif()
        set(_vcpkg_bootstrapped 1)
    endif()
endmacro()

macro(_ffmpeg_vcpkg_install _pkg)
    _ffmpeg_vcpkg_ensure()
    if(EXISTS "${_vcpkg_exe}")
        message(STATUS "Installing ${_pkg}:${_vcpkg_triplet} via vcpkg")
        # --classic forces classic (per-package) mode even when this project is embedded
        # in a parent that uses a vcpkg manifest. Without it, vcpkg walks up the directory
        # tree, finds the parent's vcpkg.json, enters manifest mode and rejects the package
        # argument ("vcpkg install does not support individual package arguments").
        # --vcpkg-root pins the install to THIS project's local vcpkg/installed tree.
        execute_process(
            COMMAND "${_vcpkg_exe}" install "${_pkg}:${_vcpkg_triplet}"
                    --classic --vcpkg-root "${_vcpkg_root}" --disable-metrics
            WORKING_DIRECTORY "${_vcpkg_root}"
            RESULT_VARIABLE _vcpkg_install_result
        )
        if(NOT _vcpkg_install_result EQUAL 0)
            message(WARNING "vcpkg install ${_pkg} failed")
        endif()
        list(PREPEND CMAKE_PREFIX_PATH "${_vcpkg_installed}")
    else()
        message(FATAL_ERROR "vcpkg not available. Set VCPKG_ROOT or install ${_pkg} manually.")
    endif()
endmacro()

# ---------------------------------------------------------------------------
# NASM detection  (global search first; fall back to vcpkg tools dir, then download)
# ARM64 is a cross-compile target — no x86 NASM assembly applies.
# ---------------------------------------------------------------------------
if(CMAKE_GENERATOR_PLATFORM STREQUAL "ARM64")
    set(HAVE_X86ASM 0)
else()
    _ffmpeg_vcpkg_ensure()
    # NASM is a build tool — always search the x64-windows tools dir regardless of target platform
    file(GLOB _vcpkg_nasm_hints "${_vcpkg_tool_installed}/tools/nasm/nasm-*/")
    find_program(FFMPEG_NASM_EXECUTABLE
        NAMES nasm
        HINTS
            ${_vcpkg_nasm_hints}
            "${_vcpkg_tool_installed}/tools/nasm"
            "${_vcpkg_tool_installed}/tools"
    )

    if(FFMPEG_NASM_EXECUTABLE)
        set(_asm_exe     "${FFMPEG_NASM_EXECUTABLE}")
        set(_asm_is_yasm 0)
        message(STATUS "NASM: ${FFMPEG_NASM_EXECUTABLE}")
    else()
        # NASM not found — download official win64 binary into vcpkg tools dir
        set(_nasm_ver "2.16.03")
        set(_nasm_dir "${_vcpkg_tool_installed}/tools/nasm/nasm-${_nasm_ver}")
        set(_nasm_zip "${_vcpkg_tool_installed}/tools/nasm/nasm-${_nasm_ver}-win64.zip")
        if(NOT EXISTS "${_nasm_dir}/nasm.exe")
            message(STATUS "NASM not found — downloading nasm ${_nasm_ver}")
            file(MAKE_DIRECTORY "${_vcpkg_tool_installed}/tools/nasm")
            file(DOWNLOAD
                "https://www.nasm.us/pub/nasm/releasebuilds/${_nasm_ver}/win64/nasm-${_nasm_ver}-win64.zip"
                "${_nasm_zip}"
                STATUS _dl_status
                SHOW_PROGRESS
            )
            list(GET _dl_status 0 _dl_code)
            if(_dl_code EQUAL 0)
                execute_process(
                    COMMAND "${CMAKE_COMMAND}" -E tar xf "${_nasm_zip}"
                    WORKING_DIRECTORY "${_vcpkg_tool_installed}/tools/nasm"
                )
                file(REMOVE "${_nasm_zip}")
            else()
                message(FATAL_ERROR "NASM download failed")
            endif()
        endif()
        find_program(FFMPEG_NASM_EXECUTABLE
            NAMES nasm
            HINTS "${_nasm_dir}"
            NO_DEFAULT_PATH
        )
        if(FFMPEG_NASM_EXECUTABLE)
            set(_asm_exe     "${FFMPEG_NASM_EXECUTABLE}")
            set(_asm_is_yasm 0)
            message(STATUS "NASM (downloaded): ${FFMPEG_NASM_EXECUTABLE}")
        endif()
    endif()

    if(NOT DEFINED _asm_exe)
        message(FATAL_ERROR "NASM assembler not found and could not be downloaded")
    endif()

    # Win32 vs x64 differ in ARCH_X86_32 / ARCH_X86_64
    if(CMAKE_GENERATOR_PLATFORM STREQUAL "Win32")
        set(_arch_x86_32 1)
        set(_arch_x86_64 0)
    else()
        set(_arch_x86_32 0)
        set(_arch_x86_64 1)
    endif()

    # Generate config.asm before enable_language so it exists for the compiler test
    file(WRITE "${CMAKE_BINARY_DIR}/config.asm" [=[
%define ARCH_X86    1
%define ARCH_X86_32 0
%define ARCH_X86_64 1
%define HAVE_ALIGNED_STACK       1
%define HAVE_MMX_EXTERNAL        1
%define HAVE_MMXEXT_EXTERNAL     1
%define HAVE_SSE_EXTERNAL        1
%define HAVE_SSE2_EXTERNAL       1
%define HAVE_SSE3_EXTERNAL       1
%define HAVE_SSSE3_EXTERNAL      1
%define HAVE_SSE4_EXTERNAL       1
%define HAVE_SSE42_EXTERNAL      1
%define HAVE_AVX_EXTERNAL        1
%define HAVE_AVX2_EXTERNAL       1
%define HAVE_FMA3_EXTERNAL       1
%define HAVE_FMA4_EXTERNAL       1
%define HAVE_XOP_EXTERNAL        1
%define HAVE_AVX512_EXTERNAL     1
%define HAVE_AVX512ICL_EXTERNAL  1
%define HAVE_AVXVNNI_EXTERNAL    0
%define HAVE_AESNI_EXTERNAL      0
%define HAVE_AMD3DNOW_EXTERNAL   0
%define HAVE_AMD3DNOWEXT_EXTERNAL 0
%define HAVE_MMX_INLINE          0
%define HAVE_X86_SSE2AVX         0
]=])
    # Patch the two arch flags that differ between Win32 and x64
    file(READ "${CMAKE_BINARY_DIR}/config.asm" _asm_tmp)
    string(REPLACE "%define ARCH_X86_32 0" "%define ARCH_X86_32 ${_arch_x86_32}" _asm_tmp "${_asm_tmp}")
    string(REPLACE "%define ARCH_X86_64 1" "%define ARCH_X86_64 ${_arch_x86_64}" _asm_tmp "${_asm_tmp}")
    file(WRITE "${CMAKE_BINARY_DIR}/config.asm" "${_asm_tmp}")
    unset(_asm_tmp)

    set(CMAKE_ASM_NASM_COMPILER "${_asm_exe}" CACHE FILEPATH "NASM assembler" FORCE)
    if(CMAKE_GENERATOR_PLATFORM STREQUAL "Win32")
        set(CMAKE_ASM_NASM_FLAGS "-P${CMAKE_BINARY_DIR}/config.asm -DPREFIX")
    else()
        set(CMAKE_ASM_NASM_FLAGS "-P${CMAKE_BINARY_DIR}/config.asm")
    endif()
    enable_language(ASM_NASM)
    set(HAVE_X86ASM 1)
endif()

# ---------------------------------------------------------------------------
# VS/NASM fix: CMake's VS generator writes <ObjectFileName> for NASM items,
# but nasm.targets uses %(NASM.OutputFormat) as both the Outputs= incremental
# check and the -o flag. With OutputFormat empty, MSBuild sees Outputs="" +
# non-empty Inputs and skips _NASM as "up-to-date" forever.
# The props file below maps OutputFormat to ObjectFileName so the check works,
# and creates the output subdirectories that NASM won't create itself.
# ---------------------------------------------------------------------------
if(MSVC AND HAVE_X86ASM)
    file(WRITE "${CMAKE_BINARY_DIR}/nasm_vs_fix.props" [=[
<?xml version="1.0" encoding="utf-8"?>
<Project xmlns="http://schemas.microsoft.com/developer/msbuild/2003">
  <!-- Re-import the default user props so we don't lose platform settings. -->
  <Import Project="$(UserRootDir)\Microsoft.Cpp.$(Platform).user.props"
          Condition="exists('$(UserRootDir)\Microsoft.Cpp.$(Platform).user.props')"
          Label="LocalAppDataPlatform"/>
  <!-- Force win32 output format on 32-bit builds so NASM defines WIN32 (not WIN64),
       enabling the underscore prefix for C symbol decoration in x86util.asm. -->
  <ItemDefinitionGroup Condition="'$(Platform)' == 'Win32'">
    <NASM>
      <Outputswitch>0</Outputswitch>
    </NASM>
  </ItemDefinitionGroup>
  <!-- Create NASM output subdirectories before assembling (NASM won't do it).
       OutputFormat is set per-item by CMake (via VS_SETTINGS), so %(OutputFormat)
       is non-empty and the MakeDir transform works correctly. -->
  <Target Name="_NASMMakeOutputDirs" BeforeTargets="_NASM" Condition="'@(NASM)' != ''">
    <ItemGroup>
      <_NASMOutFile Include="@(NASM->'%(OutputFormat)')"/>
    </ItemGroup>
    <MakeDir Directories="@(_NASMOutFile->'%(RootDir)%(Directory)')"/>
  </Target>
</Project>
]=])
endif()

# ---------------------------------------------------------------------------
# Output directories
# ---------------------------------------------------------------------------
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/lib)
set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/lib)

# ---------------------------------------------------------------------------
# MSVC compile settings
# ---------------------------------------------------------------------------
if(MSVC)
    add_compile_options(
        $<$<COMPILE_LANGUAGE:C>:/MP>
        $<$<COMPILE_LANGUAGE:C>:/W3>
        $<$<COMPILE_LANGUAGE:C>:/wd4018>
        $<$<COMPILE_LANGUAGE:C>:/wd4028>
        $<$<COMPILE_LANGUAGE:C>:/wd4090>
        $<$<COMPILE_LANGUAGE:C>:/wd4101>
        $<$<COMPILE_LANGUAGE:C>:/wd4113>
        $<$<COMPILE_LANGUAGE:C>:/wd4133>
        $<$<COMPILE_LANGUAGE:C>:/wd4146>
        $<$<COMPILE_LANGUAGE:C>:/wd4244>
        $<$<COMPILE_LANGUAGE:C>:/wd4267>
        $<$<COMPILE_LANGUAGE:C>:/wd4305>
        $<$<COMPILE_LANGUAGE:C>:/wd4334>
        $<$<COMPILE_LANGUAGE:C>:/wd4477>
        $<$<COMPILE_LANGUAGE:C>:/wd4700>
        $<$<COMPILE_LANGUAGE:C>:/wd4715>
        $<$<COMPILE_LANGUAGE:C>:/wd4723>
        $<$<COMPILE_LANGUAGE:C>:/wd4996>
        $<$<COMPILE_LANGUAGE:C>:/std:c11>
        $<$<COMPILE_LANGUAGE:C>:/fp:fast>
    )
    add_compile_definitions(
        $<$<COMPILE_LANGUAGE:C>:_CRT_SECURE_NO_WARNINGS>
        $<$<COMPILE_LANGUAGE:C>:_CRT_NONSTDC_NO_DEPRECATE>
        $<$<COMPILE_LANGUAGE:C>:_USE_MATH_DEFINES>
        $<$<COMPILE_LANGUAGE:C>:WIN32_LEAN_AND_MEAN>
        $<$<COMPILE_LANGUAGE:C>:NOMINMAX>
        "$<$<COMPILE_LANGUAGE:C>:restrict=__restrict>"
        $<$<COMPILE_LANGUAGE:C>:HAVE_AV_CONFIG_H>
        $<$<COMPILE_LANGUAGE:C>:_LARGEFILE64_SOURCE=0>
    )
endif()

# ---------------------------------------------------------------------------
# Generate config.h  (Windows x64 MSVC)
# ---------------------------------------------------------------------------
set(_HAVE_X86ASM ${HAVE_X86ASM})

file(WRITE "${CMAKE_BINARY_DIR}/config.h" [=[
#ifndef FFMPEG_CONFIG_H
#define FFMPEG_CONFIG_H

/* Architecture */
#define ARCH_AARCH64 0
#define ARCH_ALPHA   0
#define ARCH_ARM     0
#define ARCH_AVR32   0
#define ARCH_LOONGARCH 0
#define ARCH_MIPS    0
#define ARCH_MIPS64  0
#define ARCH_PARISC  0
#define ARCH_PPC     0
#define ARCH_PPC64   0
#define ARCH_RISCV   0
#define ARCH_S390    0
#define ARCH_SH4     0
#define ARCH_SPARC   0
#define ARCH_TILEGX  0
#define ARCH_TILEPRO 0
#define ARCH_TOMI    0
#define ARCH_X86     1
#define ARCH_X86_32  0
#define ARCH_X86_64  1

/* CPU features (runtime-detected) */
#define HAVE_ALTIVEC      0
#define HAVE_AMD3DNOW     0
#define HAVE_AMD3DNOWEXT  0
#define HAVE_AESNI        1
#define HAVE_AVX          1
#define HAVE_AVX2         1
#define HAVE_AVX512       0
#define HAVE_AVX512ICL    0
#define HAVE_AVXVNNI      0
#define HAVE_FMA3         1
#define HAVE_FMA4         0
#define HAVE_LASX         0
#define HAVE_LSX          0
#define HAVE_MIPSDSP      0
#define HAVE_MIPSDSPR2    0
#define HAVE_MIPSFPU      0
#define HAVE_MMI          0
#define HAVE_MMX          1
#define HAVE_MMXEXT       1
#define HAVE_MSA          0
#define HAVE_MSA2         0
#define HAVE_NEON         0
#define HAVE_POWER8       0
#define HAVE_RVV          0
#define HAVE_SSE          1
#define HAVE_SSE2         1
#define HAVE_SSE3         1
#define HAVE_SSE4         1
#define HAVE_SSE42        1
#define HAVE_SSSE3        1
#define HAVE_SVE          0
#define HAVE_SVE2         0
#define HAVE_VFP          0
#define HAVE_VFPV3        0
#define HAVE_VSX          0
#define HAVE_XOP          0
#define HAVE_CPUNOP       0

/* Inline / external assembly */
#define HAVE_INLINE_ASM   0
/* HAVE_X86ASM is set below depending on NASM availability */
#ifndef HAVE_X86ASM
#define HAVE_X86ASM       0
#endif
#define HAVE_NASM         HAVE_X86ASM

/* Endianness / alignment */
#define HAVE_BIGENDIAN      0
#define HAVE_FAST_UNALIGNED 1
#define HAVE_FAST_64BIT     1

/* Threading */
#define HAVE_PTHREADS    0
#define HAVE_OS2THREADS  0
#define HAVE_W32THREADS  1
#define HAVE_THREADS     1

/* OS */
#define OS_WIN32   1
#define OS_AMIGAOS 0
#define OS_DOS     0
#define OS_OS2     0
#define OS_UNIX    0

/* System headers */
#define HAVE_WINDOWS_H    1
#define HAVE_WINSOCK2_H   1
#define HAVE_WS2TCPIP_H   1
#define HAVE_IO_H         1
#define HAVE_DIRECT_H     1
#define HAVE_MALLOC_H     1
#define HAVE_UNISTD_H     0
#define HAVE_PTHREAD_H    0
#define HAVE_ALTIVEC_H    0
#define HAVE_BYTESWAP_H   0
#define HAVE_GLOB_H       0
#define HAVE_SYS_MMAN_H   0
#define HAVE_SYS_PARAM_H  0
#define HAVE_SYS_RESOURCE_H 0
#define HAVE_SYS_SELECT_H 0
#define HAVE_SYS_TIME_H   0
#define HAVE_SYS_UN_H     0
#define HAVE_TERMIOS_H    0
#define HAVE_VALGRIND_VALGRIND_H 0
#define HAVE_DISPATCH_DISPATCH_H 0

/* Available functions */
#define HAVE_ACCESS            1
#define HAVE_ALIGNED_MALLOC    1
#define HAVE_CLOSESOCKET       1
#define HAVE_COMMANDLINETOARGVW 1
#define HAVE_CREATEFILE        1
#define HAVE_CRYPTGENRANDOM    1
#define HAVE_FCNTL             0
#define HAVE_FORK              0
#define HAVE_GETADDRINFO       1
#define HAVE_GETHRTIME         0
#define HAVE_GETMODULEHANDLE   1
#define HAVE_GETPROCESSMEMORYINFO 1
#define HAVE_GETPROCESSTIMES   1
#define HAVE_GETRANDOM         0
#define HAVE_GETTIMEOFDAY      0
#define HAVE_GETSYSTEMTIMEASFILETIME 1
#define HAVE_GLOB              0
#define HAVE_GLRASTERPOS2D     0
#define HAVE_INET_ATON         0
#define HAVE_ISATTY            1
#define HAVE_KBHIT             1
#define HAVE_LOCALTIME_R       0
#define HAVE_LOCALTIME_S       1
#define HAVE_LSTAT             0
#define HAVE_MACH_ABSOLUTE_TIME 0
#define HAVE_MAPVIEWOFFILE     1
#define HAVE_MEMALIGN          0
#define HAVE_MKSTEMP           0
#define HAVE_MPROTECT          0
#define HAVE_NANOSLEEP         0
#define HAVE_PEEKNAMEDPIPE     1
#define HAVE_PIPE              1
#define HAVE_POSIX_MEMALIGN    0
#define HAVE_PTHREAD_CANCEL    0
#define HAVE_RTLGENRANDOM      1
#define HAVE_SCHED_GETAFFINITY 0
#define HAVE_SECUREZEROMEMORY  1
#define HAVE_SETCONSOLETEXTATTRIBUTE 1
#define HAVE_SETDLLDIRECTORY   1
#define HAVE_SETMODE           1
#define HAVE_SETSOCKOPT        1
#define HAVE_SETRLIMIT         0
#define HAVE_GETRUSAGE         0
#define HAVE_SLEEP             1
#define HAVE_SNPRINTF          1
#define HAVE_STRERROR_R        0
#define HAVE_STRTOD            1
#define HAVE_STRTOD_L          0
#define HAVE_STRTOF            1

/* Math functions — all available in MSVC 2019+ */
#define HAVE_ATANF    1
#define HAVE_ATAN2F   1
#define HAVE_CBRT     1
#define HAVE_CBRTF    1
#define HAVE_COPYSIGN 1
#define HAVE_COSF     1
#define HAVE_ERF      1
#define HAVE_EXP2     1
#define HAVE_EXP2F    1
#define HAVE_EXPF     1
#define HAVE_FABSF    1
#define HAVE_FLOORF   1
#define HAVE_HYPOT    1
#define HAVE_HYPOTF   1
#define HAVE_ISINF    1
#define HAVE_ISNAN    1
#define HAVE_ISFINITE 1
#define HAVE_LDEXPF   1
#define HAVE_LLRINT   1
#define HAVE_LLRINTF  1
#define HAVE_LOG2     1
#define HAVE_LOG2F    1
#define HAVE_LOG10F   1
#define HAVE_LRINT    1
#define HAVE_LRINTF   1
#define HAVE_POWF     1
#define HAVE_RINT     1
#define HAVE_ROUND    1
#define HAVE_ROUNDF   1
#define HAVE_SINF     1
#define HAVE_SQRTF    1
#define HAVE_TRUNC    1
#define HAVE_TRUNCF   1
#define HAVE_SYSCONF           0
#define HAVE_SYSCTL            0
#define HAVE_USLEEP            0
#define HAVE_UTIMENSAT         0
#define HAVE_VIRTUALALLOC      1
#define HAVE_WGLGETPROCADDRESS 1

/* Struct checks */
#define HAVE_STRUCT_ADDRINFO         1
#define HAVE_STRUCT_GROUP_SOURCE_REQ 1
#define HAVE_STRUCT_IP_MREQ_SOURCE   1
#define HAVE_STRUCT_IPV6_MREQ        1
#define HAVE_STRUCT_POLLFD           1
#define HAVE_STRUCT_RUSAGE_RU_MAXRSS 0
#define HAVE_STRUCT_SCTP_EVENT_SUBSCRIBE 0
#define HAVE_STRUCT_SOCKADDR_IN6     1
#define HAVE_STRUCT_SOCKADDR_SA_LEN  0
#define HAVE_STRUCT_SOCKADDR_STORAGE 1
#define HAVE_STRUCT_STAT_ST_MTIM_TV_NSEC 0
#define HAVE_STRUCT_V4L2_FRMIVALENUM_DISCRETE 0
#define HAVE_SOCKLEN_T               1

/* Build configuration */
/* SIMD alignment */
#define HAVE_SIMD_ALIGN_16 1
#define HAVE_SIMD_ALIGN_32 1
#define HAVE_SIMD_ALIGN_64 1

/* External assembly (NASM) — 0 when building without NASM */
#define HAVE_AESNI_EXTERNAL    0
#define HAVE_AMD3DNOW_EXTERNAL 0
#define HAVE_AMD3DNOWEXT_EXTERNAL 0
#define HAVE_AVX_EXTERNAL      0
#define HAVE_AVX2_EXTERNAL     0
#define HAVE_AVX512_EXTERNAL   0
#define HAVE_AVX512ICL_EXTERNAL 0
#define HAVE_AVXVNNI_EXTERNAL  0
#define HAVE_FMA3_EXTERNAL     0
#define HAVE_FMA4_EXTERNAL     0
#define HAVE_MMX_EXTERNAL      0
#define HAVE_MMXEXT_EXTERNAL   0
#define HAVE_SSE_EXTERNAL      0
#define HAVE_SSE2_EXTERNAL     0
#define HAVE_SSE3_EXTERNAL     0
#define HAVE_SSE4_EXTERNAL     0
#define HAVE_SSE42_EXTERNAL    0
#define HAVE_SSSE3_EXTERNAL    0
#define HAVE_XOP_EXTERNAL      0

/* Inline assembly — 0 for MSVC (no AT&T inline asm) */
#define HAVE_AESNI_INLINE    0
#define HAVE_AMD3DNOW_INLINE 0
#define HAVE_AMD3DNOWEXT_INLINE 0
#define HAVE_AVX_INLINE      0
#define HAVE_AVX2_INLINE     0
#define HAVE_FMA3_INLINE     0
#define HAVE_FMA4_INLINE     0
#define HAVE_MMX_INLINE      0
#define HAVE_MMXEXT_INLINE   0
#define HAVE_SSE_INLINE      0
#define HAVE_SSE2_INLINE     0
#define HAVE_SSE3_INLINE     0
#define HAVE_SSE4_INLINE     0
#define HAVE_SSE42_INLINE    0
#define HAVE_SSSE3_INLINE    0
#define HAVE_XOP_INLINE      0

/* External libraries */
#define HAVE_ZLIB 1

/* Memory debugging */
#define CONFIG_MEMORY_POISONING 0

#define CONFIG_SMALL               0
#define CONFIG_RUNTIME_CPUDETECT   1
#define CONFIG_SAFE_BITSTREAM_READER 1
#define CONFIG_SHARED              1
#define CONFIG_STATIC              0
#define CONFIG_GRAY                0
#define CONFIG_SWSCALE_ALPHA       0
#define CONFIG_NETWORK             0
#define CONFIG_GPL                 0
#define CONFIG_LGPLV3              0
#define CONFIG_NONFREE             0
#define CONFIG_VERSION3            0
#define CONFIG_OSSFUZZ             0

/* Library enables */
#define CONFIG_AVCODEC    1
#define CONFIG_AVDEVICE   0
#define CONFIG_AVFILTER   0
#define CONFIG_AVFORMAT   0
#define CONFIG_AVRESAMPLE 0
#define CONFIG_AVUTIL     1
#define CONFIG_POSTPROC   0
#define CONFIG_SWRESAMPLE 0
#define CONFIG_SWSCALE    0

/* External libraries — all disabled for base build */
#define CONFIG_LIBBS2B    0
#define CONFIG_LIBFDK_AAC 0
#define CONFIG_LIBGSM     0
#define CONFIG_LIBILBC    0
#define CONFIG_LIBMP3LAME 0
#define CONFIG_LIBOPENCV  0
#define CONFIG_LIBOPENH264 0
#define CONFIG_LIBOPENJPEG 0
#define CONFIG_LIBOPUS    0
#define CONFIG_LIBSPEEX   0
#define CONFIG_LIBTHEORA  0
#define CONFIG_LIBVORBIS  0
#define CONFIG_LIBVPX     0
#define CONFIG_LIBWAVPACK 0
#define CONFIG_LIBWEBP    0
#define CONFIG_LIBX264    0
#define CONFIG_LIBX265    0
#define CONFIG_LIBXVID    0
#define CONFIG_OPENCL     0
#define CONFIG_OPENSSL    0
#define CONFIG_VAAPI      0
#define CONFIG_VDPAU      0
#define CONFIG_VIDEOTOOLBOX 0
#define CONFIG_VULKAN     0
#define CONFIG_CUDA       0
#define CONFIG_D3D11VA    0
#define CONFIG_D3D12VA    0
#define CONFIG_DXVA2      0
#define CONFIG_NVDEC      0
#define CONFIG_NVENC      0
#define CONFIG_QSV        0

/* Misc */
#define CONFIG_THUMB      0
#define HAVE_ALTIVEC_H    0
#define SWS_MAX_FILTER_SIZE 256
#define CC_IDENT          "MSVC"
#define FFMPEG_CONFIGURATION ""
#define FFMPEG_LICENSE    "LGPL version 2.1 or later"

#include "config_components.h"

#endif /* FFMPEG_CONFIG_H */
]=])

# Patch HAVE_X86ASM and HAVE_*_EXTERNAL into config.h after writing it
if(HAVE_X86ASM)
    file(READ "${CMAKE_BINARY_DIR}/config.h" _cfg)
    string(REPLACE "#define HAVE_X86ASM       0" "#define HAVE_X86ASM       1" _cfg "${_cfg}")
    string(REPLACE "#define HAVE_NASM         HAVE_X86ASM" "#define HAVE_NASM         1" _cfg "${_cfg}")
    # Enable external-ASM feature flags to match config.asm
    string(REPLACE "#define HAVE_AVX_EXTERNAL      0" "#define HAVE_AVX_EXTERNAL      1" _cfg "${_cfg}")
    string(REPLACE "#define HAVE_AVX2_EXTERNAL     0" "#define HAVE_AVX2_EXTERNAL     1" _cfg "${_cfg}")
    string(REPLACE "#define HAVE_AVX512_EXTERNAL   0" "#define HAVE_AVX512_EXTERNAL   1" _cfg "${_cfg}")
    string(REPLACE "#define HAVE_AVX512ICL_EXTERNAL 0" "#define HAVE_AVX512ICL_EXTERNAL 1" _cfg "${_cfg}")
    string(REPLACE "#define HAVE_FMA3_EXTERNAL     0" "#define HAVE_FMA3_EXTERNAL     1" _cfg "${_cfg}")
    string(REPLACE "#define HAVE_FMA4_EXTERNAL     0" "#define HAVE_FMA4_EXTERNAL     1" _cfg "${_cfg}")
    string(REPLACE "#define HAVE_XOP_EXTERNAL      0" "#define HAVE_XOP_EXTERNAL      1" _cfg "${_cfg}")
    string(REPLACE "#define HAVE_MMX_EXTERNAL      0" "#define HAVE_MMX_EXTERNAL      1" _cfg "${_cfg}")
    string(REPLACE "#define HAVE_MMXEXT_EXTERNAL   0" "#define HAVE_MMXEXT_EXTERNAL   1" _cfg "${_cfg}")
    string(REPLACE "#define HAVE_SSE_EXTERNAL      0" "#define HAVE_SSE_EXTERNAL      1" _cfg "${_cfg}")
    string(REPLACE "#define HAVE_SSE2_EXTERNAL     0" "#define HAVE_SSE2_EXTERNAL     1" _cfg "${_cfg}")
    string(REPLACE "#define HAVE_SSE3_EXTERNAL     0" "#define HAVE_SSE3_EXTERNAL     1" _cfg "${_cfg}")
    string(REPLACE "#define HAVE_SSE4_EXTERNAL     0" "#define HAVE_SSE4_EXTERNAL     1" _cfg "${_cfg}")
    string(REPLACE "#define HAVE_SSE42_EXTERNAL    0" "#define HAVE_SSE42_EXTERNAL    1" _cfg "${_cfg}")
    string(REPLACE "#define HAVE_SSSE3_EXTERNAL    0" "#define HAVE_SSSE3_EXTERNAL    1" _cfg "${_cfg}")
    # Patch ARCH_X86_32/64 to match the build platform
    if(CMAKE_GENERATOR_PLATFORM STREQUAL "Win32")
        string(REPLACE "#define ARCH_X86_32  0" "#define ARCH_X86_32  1" _cfg "${_cfg}")
        string(REPLACE "#define ARCH_X86_64  1" "#define ARCH_X86_64  0" _cfg "${_cfg}")
    endif()
    file(WRITE "${CMAKE_BINARY_DIR}/config.h" "${_cfg}")
endif()

# ---------------------------------------------------------------------------
# Generate config_components.h  (enable all native codecs/parsers/BSFs)
# ---------------------------------------------------------------------------
# ============================================================
# FFmpeg component configuration (generated)
# Each CONFIG_<NAME> below is exposed as a CMake option FFMPEG_CONFIG_<NAME>.
# All default to ON unless FFMPEG_USE_DEFAULT_CONFIG is set to OFF.
# ============================================================
if(NOT DEFINED FFMPEG_USE_DEFAULT_CONFIG)
    set(FFMPEG_USE_DEFAULT_CONFIG ON CACHE BOOL "Enable all FFmpeg components by default" FORCE)
endif()

set(_FFMPEG_COMPONENTS
    012V_DECODER
    4XM_DECODER
    8BPS_DECODER
    8SVX_EXP_DECODER
    8SVX_FIB_DECODER
    AAC_DECODER
    AAC_FIXED_DECODER
    AAC_LATM_DECODER
    AASC_DECODER
    AC3_DECODER
    AC3_FIXED_DECODER
    AC3_PARSER
    ACELP_KELVIN_DECODER
    AGM_DECODER
    AHX_DECODER
    AIC_DECODER
    ALAC_DECODER
    ALAC_ENCODER
    ALS_DECODER
    AMR_NB_DECODER
    AMR_WB_DECODER
    AMRNB_DECODER
    AMRWB_DECODER
    AMV_DECODER
    AMV_ENCODER
    ANM_DECODER
    ANSI_DECODER
    APAC_DECODER
    APE_DECODER
    APNG_DECODER
    APNG_ENCODER
    APV_DECODER
    APTX_DECODER
    APTX_ENCODER
    APTX_HD_DECODER
    APTX_HD_ENCODER
    ARBC_DECODER
    ARGO_DECODER
    ASS_DECODER
    ASS_ENCODER
    ASV1_DECODER
    ASV1_ENCODER
    ASV2_DECODER
    ASV2_ENCODER
    ATRAC1_DECODER
    ATRAC3_DECODER
    ATRAC3AL_DECODER
    ATRAC3P_DECODER
    ATRAC3PAL_DECODER
    ATRAC9_DECODER
    AURA_DECODER
    AURA2_DECODER
    AVRN_DECODER
    AVRP_DECODER
    AVRP_ENCODER
    AVS_DECODER
    AVUI_DECODER
    AVUI_ENCODER
    BETHSOFTVID_DECODER
    BFI_DECODER
    BINK_DECODER
    BINKAUDIO_DCT_DECODER
    BINKAUDIO_RDFT_DECODER
    BITPACKED_DECODER
    BITPACKED_ENCODER
    BMP_DECODER
    BMP_ENCODER
    BMV_AUDIO_DECODER
    BMV_VIDEO_DECODER
    BONK_DECODER
    BRENDER_PIX_DECODER
    C93_DECODER
    CAVS_DECODER
    CBD2_DPCM_DECODER
    CCAPTION_DECODER
    CDGRAPHICS_DECODER
    CDTOONS_DECODER
    CDXL_DECODER
    CFHD_DECODER
    CFHD_ENCODER
    CINEPAK_DECODER
    CINEPAK_ENCODER
    CLEARVIDEO_DECODER
    CLJR_DECODER
    CLJR_ENCODER
    CLLC_DECODER
    COMFORTNOISE_DECODER
    COMFORTNOISE_ENCODER
    COOK_DECODER
    CPIA_DECODER
    CRI_DECODER
    CSCD_DECODER
    CYUV_DECODER
    DCA_DECODER
    DCA_ENCODER
    DDS_DECODER
    DERF_DPCM_DECODER
    DFA_DECODER
    DFPWM_DECODER
    DFPWM_ENCODER
    DIRAC_DECODER
    DNXHD_DECODER
    DNXHD_ENCODER
    DOLBY_E_DECODER
    DPX_DECODER
    DPX_ENCODER
    DSD_LSBF_DECODER
    DSD_LSBF_PLANAR_DECODER
    DSD_MSBF_DECODER
    DSD_MSBF_PLANAR_DECODER
    DSICINAUDIO_DECODER
    DSICINVIDEO_DECODER
    DSS_SP_DECODER
    DST_DECODER
    DVAUDIO_DECODER
    DVBSUB_DECODER
    DVBSUB_ENCODER
    DVDSUB_DECODER
    DVDSUB_ENCODER
    DVVIDEO_DECODER
    DVVIDEO_ENCODER
    DXA_DECODER
    DXTORY_DECODER
    DXV_DECODER
    DXV_ENCODER
    EAC3_DECODER
    EAC3_ENCODER
    EACMV_DECODER
    EAMAD_DECODER
    EATGQ_DECODER
    EATGV_DECODER
    EATQI_DECODER
    EIGHTBPS_DECODER
    EIGHTSVX_EXP_DECODER
    EIGHTSVX_FIB_DECODER
    ESCAPE124_DECODER
    ESCAPE130_DECODER
    EVRC_DECODER
    EXR_DECODER
    EXR_ENCODER
    FASTAUDIO_DECODER
    FFV1_DECODER
    FFV1_ENCODER
    FFVHUFF_DECODER
    FFVHUFF_ENCODER
    FFWAVESYNTH_DECODER
    FIC_DECODER
    FITS_DECODER
    FITS_ENCODER
    FLAC_DECODER
    FLAC_ENCODER
    FLASHSV_DECODER
    FLASHSV_ENCODER
    FLASHSV2_DECODER
    FLASHSV2_ENCODER
    FLIC_DECODER
    FLV_DECODER
    FLV_ENCODER
    FMVC_DECODER
    FOURXM_DECODER
    FRAPS_DECODER
    FRWU_DECODER
    FTR_DECODER
    G2M_DECODER
    G723_1_DECODER
    G723_1_ENCODER
    G728_DECODER
    G729_DECODER
    GDV_DECODER
    GEM_DECODER
    GIF_DECODER
    GIF_ENCODER
    GREMLIN_DPCM_DECODER
    GSM_DECODER
    GSM_MS_DECODER
    H261_DECODER
    H261_ENCODER
    H263_DECODER
    H263_ENCODER
    H263I_DECODER
    H263P_DECODER
    H263P_ENCODER
    H264_DECODER
    HAP_DECODER
    HAP_ENCODER
    HCA_DECODER
    HCOM_DECODER
    HDR_DECODER
    HDR_ENCODER
    HEVC_DECODER
    HNM4_VIDEO_DECODER
    HQ_HQA_DECODER
    HQX_DECODER
    HUFFYUV_DECODER
    HUFFYUV_ENCODER
    HYMT_DECODER
    IAC_DECODER
    IDCIN_DECODER
    IFF_ILBM_DECODER
    ILBC_DECODER
    IMC_DECODER
    IMM4_DECODER
    IMM5_DECODER
    INDEO2_DECODER
    INDEO3_DECODER
    INDEO4_DECODER
    INDEO5_DECODER
    INTERPLAY_ACM_DECODER
    INTERPLAY_DPCM_DECODER
    INTERPLAY_VIDEO_DECODER
    IPU_DECODER
    JACOSUB_DECODER
    JPEG2000_DECODER
    JPEG2000_ENCODER
    JPEGLS_DECODER
    JPEGLS_ENCODER
    JV_DECODER
    KGV1_DECODER
    KMVC_DECODER
    LAGARITH_DECODER
    LEAD_DECODER
    LJPEG_ENCODER
    LOCO_DECODER
    LSCR_DECODER
    M101_DECODER
    MACE3_DECODER
    MACE6_DECODER
    MAGICYUV_DECODER
    MAGICYUV_ENCODER
    MDEC_DECODER
    MEDIA100_DECODER
    METASOUND_DECODER
    MICRODVD_DECODER
    MIMIC_DECODER
    MISC4_DECODER
    MJPEG_DECODER
    MJPEG_ENCODER
    MJPEGB_DECODER
    MLP_DECODER
    MLP_ENCODER
    MMVIDEO_DECODER
    MOBICLIP_DECODER
    MOTIONPIXELS_DECODER
    MOVTEXT_DECODER
    MOVTEXT_ENCODER
    MP1_DECODER
    MP1FLOAT_DECODER
    MP2_DECODER
    MP2_ENCODER
    MP2FIXED_ENCODER
    MP2FLOAT_DECODER
    MP3_DECODER
    MP3ADU_DECODER
    MP3ADUFLOAT_DECODER
    MP3FLOAT_DECODER
    MP3ON4_DECODER
    MP3ON4FLOAT_DECODER
    MPC7_DECODER
    MPC8_DECODER
    MPL2_DECODER
    MPEG1VIDEO_DECODER
    MPEG1VIDEO_ENCODER
    MPEG2VIDEO_DECODER
    MPEG2VIDEO_ENCODER
    MPEG4_DECODER
    MPEG4_ENCODER
    MPEGVIDEO_DECODER
    MSA1_DECODER
    MSCC_DECODER
    MSMPEG4V1_DECODER
    MSMPEG4V2_DECODER
    MSMPEG4V2_ENCODER
    MSMPEG4V3_DECODER
    MSMPEG4V3_ENCODER
    MSNSIREN_DECODER
    MSP2_DECODER
    MSRLE_DECODER
    MSRLE_ENCODER
    MSS1_DECODER
    MSS2_DECODER
    MSVIDEO1_DECODER
    MSVIDEO1_ENCODER
    MSZH_DECODER
    MTS2_DECODER
    MV30_DECODER
    MVC1_DECODER
    MVC2_DECODER
    MVDV_DECODER
    MVHA_DECODER
    MVC_DECODER
    MWSC_DECODER
    MXPEG_DECODER
    NELLYMOSER_DECODER
    NELLYMOSER_ENCODER
    NOTCHLC_DECODER
    NUV_DECODER
    ON2AVC_DECODER
    OPUS_DECODER
    OPUS_ENCODER
    OSQ_DECODER
    PAF_AUDIO_DECODER
    PAF_VIDEO_DECODER
    PAM_DECODER
    PAM_ENCODER
    PBM_DECODER
    PBM_ENCODER
    PCM_ALAW_DECODER
    PCM_ALAW_ENCODER
    PCM_BLURAY_DECODER
    PCM_BLURAY_ENCODER
    PCM_DVD_DECODER
    PCM_DVD_ENCODER
    PCM_F16LE_DECODER
    PCM_F24LE_DECODER
    PCM_F32BE_DECODER
    PCM_F32BE_ENCODER
    PCM_F32LE_DECODER
    PCM_F32LE_ENCODER
    PCM_F64BE_DECODER
    PCM_F64BE_ENCODER
    PCM_F64LE_DECODER
    PCM_F64LE_ENCODER
    PCM_LXF_DECODER
    PCM_MULAW_DECODER
    PCM_MULAW_ENCODER
    PCM_S8_DECODER
    PCM_S8_ENCODER
    PCM_S8_PLANAR_DECODER
    PCM_S8_PLANAR_ENCODER
    PCM_S16BE_DECODER
    PCM_S16BE_ENCODER
    PCM_S16BE_PLANAR_DECODER
    PCM_S16BE_PLANAR_ENCODER
    PCM_S16LE_DECODER
    PCM_S16LE_ENCODER
    PCM_S16LE_PLANAR_DECODER
    PCM_S16LE_PLANAR_ENCODER
    PCM_S24BE_DECODER
    PCM_S24BE_ENCODER
    PCM_S24DAUD_DECODER
    PCM_S24DAUD_ENCODER
    PCM_S24LE_DECODER
    PCM_S24LE_ENCODER
    PCM_S24LE_PLANAR_DECODER
    PCM_S24LE_PLANAR_ENCODER
    PCM_S32BE_DECODER
    PCM_S32BE_ENCODER
    PCM_S32LE_DECODER
    PCM_S32LE_ENCODER
    PCM_S32LE_PLANAR_DECODER
    PCM_S32LE_PLANAR_ENCODER
    PCM_S64BE_DECODER
    PCM_S64BE_ENCODER
    PCM_S64LE_DECODER
    PCM_S64LE_ENCODER
    PCM_SGA_DECODER
    PCM_U8_DECODER
    PCM_U8_ENCODER
    PCM_U16BE_DECODER
    PCM_U16BE_ENCODER
    PCM_U16LE_DECODER
    PCM_U16LE_ENCODER
    PCM_U24BE_DECODER
    PCM_U24BE_ENCODER
    PCM_U24LE_DECODER
    PCM_U24LE_ENCODER
    PCM_U32BE_DECODER
    PCM_U32BE_ENCODER
    PCM_U32LE_DECODER
    PCM_U32LE_ENCODER
    PCM_VIDC_DECODER
    PCM_VIDC_ENCODER
    PCX_DECODER
    PCX_ENCODER
    PDV_DECODER
    PDV_ENCODER
    PFM_DECODER
    PFM_ENCODER
    PGMSUB_DECODER
    PGM_DECODER
    PGM_ENCODER
    PGMYUV_DECODER
    PGMYUV_ENCODER
    PGX_DECODER
    PGSSUB_DECODER
    PHM_DECODER
    PHM_ENCODER
    PHOTOCD_DECODER
    PICTOR_DECODER
    PIXLET_DECODER
    PJS_DECODER
    PNG_DECODER
    PNG_ENCODER
    PPM_DECODER
    PPM_ENCODER
    PRORES_DECODER
    PRORES_ENCODER
    PRORES_AW_ENCODER
    PRORES_KS_ENCODER
    PRORES_RAW_DECODER
    PROSUMER_DECODER
    PSD_DECODER
    PTX_DECODER
    QDRAW_DECODER
    QDMC_DECODER
    QDM2_DECODER
    QCELP_DECODER
    QOA_DECODER
    QOI_DECODER
    QOI_ENCODER
    QPEG_DECODER
    QTRLE_DECODER
    QTRLE_ENCODER
    R10K_DECODER
    R10K_ENCODER
    R210_DECODER
    R210_ENCODER
    RA_144_DECODER
    RA_144_ENCODER
    RA_288_DECODER
    RALF_DECODER
    RASC_DECODER
    RAWVIDEO_DECODER
    RAWVIDEO_ENCODER
    REALTEXT_DECODER
    RKA_DECODER
    RL2_DECODER
    ROQ_DECODER
    ROQ_DPCM_DECODER
    ROQ_DPCM_ENCODER
    ROQ_ENCODER
    RPZA_DECODER
    RPZA_ENCODER
    RSCC_DECODER
    RTV1_DECODER
    RV10_DECODER
    RV10_ENCODER
    RV20_DECODER
    RV20_ENCODER
    RV30_DECODER
    RV40_DECODER
    RV60_DECODER
    S302M_DECODER
    S302M_ENCODER
    SAMI_DECODER
    SANM_DECODER
    SBC_DECODER
    SBC_ENCODER
    SCPR_DECODER
    SCREENPRESSO_DECODER
    SDX2_DPCM_DECODER
    SGA_DECODER
    SGI_DECODER
    SGI_ENCODER
    SGIRLE_DECODER
    SHEERVIDEO_DECODER
    SHORTEN_DECODER
    SIMBIOSIS_IMX_DECODER
    SIPR_DECODER
    SIREN_DECODER
    SMACKER_DECODER
    SMACKAUD_DECODER
    SMC_DECODER
    SMC_ENCODER
    SMVJPEG_DECODER
    SNOW_DECODER
    SNOW_ENCODER
    SOL_DPCM_DECODER
    SP5X_DECODER
    SPEEDHQ_DECODER
    SPEEDHQ_ENCODER
    SPEEX_DECODER
    SRGC_DECODER
    SRT_DECODER
    SRT_ENCODER
    SSA_DECODER
    SSA_ENCODER
    STL_DECODER
    SUBRIP_DECODER
    SUBRIP_ENCODER
    SUBVIEWER_DECODER
    SUBVIEWER1_DECODER
    SUNRAST_DECODER
    SUNRAST_ENCODER
    SVQ1_DECODER
    SVQ1_ENCODER
    SVQ3_DECODER
    TAK_DECODER
    TARGA_DECODER
    TARGA_ENCODER
    TARGA_Y216_DECODER
    TDSC_DECODER
    TEXT_DECODER
    TEXT_ENCODER
    THEORA_DECODER
    THP_DECODER
    TIERTEXSEQVIDEO_DECODER
    TIFF_DECODER
    TIFF_ENCODER
    TMV_DECODER
    TRUEHD_DECODER
    TRUEHD_ENCODER
    TRUEMOTION1_DECODER
    TRUEMOTION2_DECODER
    TRUEMOTION2RT_DECODER
    TRUESPEECH_DECODER
    TSCC_DECODER
    TSCC2_DECODER
    TTA_DECODER
    TTA_ENCODER
    TTML_ENCODER
    TWINVQ_DECODER
    TXD_DECODER
    ULTI_DECODER
    UTVIDEO_DECODER
    UTVIDEO_ENCODER
    V210_DECODER
    V210_ENCODER
    V210X_DECODER
    VB_DECODER
    VBN_DECODER
    VBN_ENCODER
    VBLE_DECODER
    VC1_DECODER
    VC1IMAGE_DECODER
    VC2_ENCODER
    VCR1_DECODER
    VMDAUDIO_DECODER
    VMDVIDEO_DECODER
    VMIX_DECODER
    VMNC_DECODER
    VORBIS_DECODER
    VORBIS_ENCODER
    VP3_DECODER
    VP4_DECODER
    VP5_DECODER
    VP6_DECODER
    VP6A_DECODER
    VP6F_DECODER
    VP7_DECODER
    VP8_DECODER
    VP9_DECODER
    VPLAYER_DECODER
    VQA_DECODER
    VQC_DECODER
    VVC_DECODER
    WADY_DPCM_DECODER
    WAVARC_DECODER
    WAVPACK_DECODER
    WAVPACK_ENCODER
    WBMP_DECODER
    WBMP_ENCODER
    WEBP_DECODER
    WEBVTT_DECODER
    WEBVTT_ENCODER
    WCMV_DECODER
    WMALOSSLESS_DECODER
    WMAPRO_DECODER
    WMAV1_DECODER
    WMAV1_ENCODER
    WMAV2_DECODER
    WMAV2_ENCODER
    WMAVOICE_DECODER
    WMV1_DECODER
    WMV1_ENCODER
    WMV2_DECODER
    WMV2_ENCODER
    WMV3_DECODER
    WMV3IMAGE_DECODER
    WNV1_DECODER
    WRAPPED_AVFRAME_DECODER
    WRAPPED_AVFRAME_ENCODER
    WS_SND1_DECODER
    XAN_DPCM_DECODER
    XAN_WC3_DECODER
    XAN_WC4_DECODER
    XBM_DECODER
    XBM_ENCODER
    XFACE_DECODER
    XFACE_ENCODER
    XL_DECODER
    XMA1_DECODER
    XMA2_DECODER
    XPM_DECODER
    XSUB_DECODER
    XSUB_ENCODER
    XWD_DECODER
    XWD_ENCODER
    Y41P_DECODER
    Y41P_ENCODER
    YLC_DECODER
    YOP_DECODER
    YUV4_DECODER
    YUV4_ENCODER
    ZERO12V_DECODER
    ZEROCODEC_DECODER
    ZLIB_DECODER
    ZLIB_ENCODER
    ZMBV_DECODER
    ZMBV_ENCODER
    AAC_LATM_PARSER
    AAC_PARSER
    ADX_PARSER
    AHX_PARSER
    AMR_PARSER
    APV_PARSER
    AV1_PARSER
    AVS2_PARSER
    AVS3_PARSER
    BMP_PARSER
    CAVSVIDEO_PARSER
    COOK_PARSER
    CRI_PARSER
    DCA_PARSER
    DIRAC_PARSER
    DNXHD_PARSER
    DNXUC_PARSER
    DOLBY_E_PARSER
    DPX_PARSER
    DVAUDIO_PARSER
    DVBSUB_PARSER
    DVDSUB_PARSER
    DVD_NAV_PARSER
    EVC_PARSER
    FFV1_PARSER
    FLAC_PARSER
    FTR_PARSER
    G723_1_PARSER
    G729_PARSER
    GIF_PARSER
    GSM_PARSER
    H261_PARSER
    H263_PARSER
    H264_PARSER
    HDR_PARSER
    HEVC_PARSER
    IPU_PARSER
    JPEG2000_PARSER
    JPEGXL_PARSER
    JPEGXS_PARSER
    LCEVC_PARSER
    MISC4_PARSER
    MJPEG_PARSER
    MLP_PARSER
    MPEG4VIDEO_PARSER
    MPEGAUDIO_PARSER
    MPEGVIDEO_PARSER
    OPUS_PARSER
    PNG_PARSER
    PNM_PARSER
    PRORES_PARSER
    PRORES_RAW_PARSER
    QOI_PARSER
    RV34_PARSER
    SBC_PARSER
    SIPR_PARSER
    TAK_PARSER
    VC1_PARSER
    VORBIS_PARSER
    VP3_PARSER
    VP8_PARSER
    VP9_PARSER
    VVC_PARSER
    WEBP_PARSER
    XBM_PARSER
    XMA_PARSER
    XWD_PARSER
    AAC_ADTSTOASC_BSF
    AHX_TO_MP2_BSF
    APV_METADATA_BSF
    AV1_FRAME_MERGE_BSF
    AV1_FRAME_SPLIT_BSF
    AV1_METADATA_BSF
    CHOMP_BSF
    DCA_CORE_BSF
    DOVI_RPU_BSF
    DOVI_SPLIT_BSF
    DTS2PTS_BSF
    DV_ERROR_MARKER_BSF
    DUMP_EXTRADATA_BSF
    EAC3_CORE_BSF
    EIA608_TO_SMPTE436M_BSF
    EVC_FRAME_MERGE_BSF
    EXTRACT_EXTRADATA_BSF
    FILTER_UNITS_BSF
    H264_METADATA_BSF
    H264_MP4TOANNEXB_BSF
    H264_REDUNDANT_PPS_BSF
    HAPQA_EXTRACT_BSF
    HEVC_METADATA_BSF
    HEVC_MP4TOANNEXB_BSF
    IMX_DUMP_HEADER_BSF
    LCEVC_METADATA_BSF
    MEDIA100_TO_MJPEGB_BSF
    MJPEG2JPEG_BSF
    MJPEGA_DUMP_HEADER_BSF
    MOV2TEXTSUB_BSF
    MPEG2_METADATA_BSF
    MPEG4_UNPACK_BFRAMES_BSF
    NOISE_BSF
    NULL_BSF
    OPUS_METADATA_BSF
    PCM_RECHUNK_BSF
    PGS_FRAME_MERGE_BSF
    PRORES_METADATA_BSF
    REMOVE_EXTRADATA_BSF
    SETTS_BSF
    SHOWINFO_BSF
    SMPTE436M_TO_EIA608_BSF
    TEXT2MOVSUB_BSF
    TRACE_HEADERS_BSF
    TRUEHD_CORE_BSF
    VP9_METADATA_BSF
    VP9_RAW_REORDER_BSF
    VP9_SUPERFRAME_BSF
    VP9_SUPERFRAME_SPLIT_BSF
    VVC_METADATA_BSF
    VVC_MP4TOANNEXB_BSF
    CBS_AV1
    CBS_H264
    CBS_H265
    CBS_H266
    CBS_JPEG
    CBS_MPEG2
    CBS_VP8
    CBS_VP9
    CBS_APV
    CBS_LCEVC
    VNULL_DECODER
    VNULL_ENCODER
    ANULL_DECODER
    ANULL_ENCODER
    A64MULTI_ENCODER
    A64MULTI5_ENCODER
    AAC_ENCODER
    BINTEXT_DECODER
    FRAME_THREAD_ENCODER
    IDF_DECODER
    WEBP_ANIM_DECODER
    XBIN_DECODER
    ADPCM_4XM_DECODER
    ADPCM_ADX_DECODER
    ADPCM_AFC_DECODER
    ADPCM_AGM_DECODER
    ADPCM_AICA_DECODER
    ADPCM_ARGO_DECODER
    ADPCM_CIRCUS_DECODER
    ADPCM_CT_DECODER
    ADPCM_DTK_DECODER
    ADPCM_EA_DECODER
    ADPCM_EA_MAXIS_XA_DECODER
    ADPCM_EA_R1_DECODER
    ADPCM_EA_R2_DECODER
    ADPCM_EA_R3_DECODER
    ADPCM_EA_XAS_DECODER
    ADPCM_G722_DECODER
    ADPCM_G726_DECODER
    ADPCM_G726LE_DECODER
    ADPCM_IMA_ACORN_DECODER
    ADPCM_IMA_ALP_DECODER
    ADPCM_IMA_AMV_DECODER
    ADPCM_IMA_APC_DECODER
    ADPCM_IMA_APM_DECODER
    ADPCM_IMA_CUNNING_DECODER
    ADPCM_IMA_DAT4_DECODER
    ADPCM_IMA_DK3_DECODER
    ADPCM_IMA_DK4_DECODER
    ADPCM_IMA_EA_EACS_DECODER
    ADPCM_IMA_EA_SEAD_DECODER
    ADPCM_IMA_ESCAPE_DECODER
    ADPCM_IMA_HVQM2_DECODER
    ADPCM_IMA_HVQM4_DECODER
    ADPCM_IMA_ISS_DECODER
    ADPCM_IMA_MAGIX_DECODER
    ADPCM_IMA_MOFLEX_DECODER
    ADPCM_IMA_MTF_DECODER
    ADPCM_IMA_OKI_DECODER
    ADPCM_IMA_PDA_DECODER
    ADPCM_IMA_QT_DECODER
    ADPCM_IMA_RAD_DECODER
    ADPCM_IMA_SMJPEG_DECODER
    ADPCM_IMA_SSI_DECODER
    ADPCM_IMA_WAV_DECODER
    ADPCM_IMA_WS_DECODER
    ADPCM_IMA_XBOX_DECODER
    ADPCM_MS_DECODER
    ADPCM_MTAF_DECODER
    ADPCM_N64_DECODER
    ADPCM_PSX_DECODER
    ADPCM_PSXC_DECODER
    ADPCM_SANYO_DECODER
    ADPCM_SBPRO_2_DECODER
    ADPCM_SBPRO_3_DECODER
    ADPCM_SBPRO_4_DECODER
    ADPCM_SWF_DECODER
    ADPCM_THP_DECODER
    ADPCM_THP_LE_DECODER
    ADPCM_VIMA_DECODER
    ADPCM_XA_DECODER
    ADPCM_XMD_DECODER
    ADPCM_YAMAHA_DECODER
    ADPCM_ZORK_DECODER
    ADPCM_ADX_ENCODER
    ADPCM_ARGO_ENCODER
    ADPCM_G722_ENCODER
    ADPCM_G726_ENCODER
    ADPCM_G726LE_ENCODER
    ADPCM_IMA_ALP_ENCODER
    ADPCM_IMA_AMV_ENCODER
    ADPCM_IMA_APM_ENCODER
    ADPCM_IMA_QT_ENCODER
    ADPCM_IMA_SSI_ENCODER
    ADPCM_IMA_WAV_ENCODER
    ADPCM_IMA_WS_ENCODER
    ADPCM_MS_ENCODER
    ADPCM_SWF_ENCODER
    ADPCM_YAMAHA_ENCODER
)
set(_FFMPEG_ENABLED_COMPONENTS "")
foreach(_comp IN LISTS _FFMPEG_COMPONENTS)
    option(FFMPEG_CONFIG_${_comp} "Enable FFmpeg component ${_comp}" ${FFMPEG_USE_DEFAULT_CONFIG})
    if(FFMPEG_CONFIG_${_comp})
        list(APPEND _FFMPEG_ENABLED_COMPONENTS ${_comp})
    endif()
endforeach()

# ---------------------------------------------------------------------------
# Subset builds (FFMPEG_USE_DEFAULT_CONFIG=OFF): resolve the avcodec dependency
# closure now — before config_components.h is generated — so BOTH the internal
# capability flags (below) and the libavcodec source list (later) reflect only
# what the enabled components actually need. See cmake/ResolveAvcodecSrcs.cmake.
# Sets AVCODEC_RESOLVED_C / AVCODEC_RESOLVED_ASM / AVCODEC_CLOSURE_CONFIGS.
# ---------------------------------------------------------------------------
if(NOT FFMPEG_USE_DEFAULT_CONFIG)
    if(HAVE_X86ASM)
        set(_ffmpeg_x86asm_flag 1)
    else()
        set(_ffmpeg_x86asm_flag 0)
    endif()
    include("${CMAKE_SOURCE_DIR}/cmake/ResolveAvcodecSrcs.cmake")
    ffmpeg_resolve_avcodec_srcs(
        "${FFMPEG_SRC}" "${CMAKE_BINARY_DIR}/config.h" "${_ffmpeg_x86asm_flag}"
        AVCODEC_RESOLVED_C AVCODEC_RESOLVED_ASM AVCODEC_CLOSURE_CONFIGS
        ${_FFMPEG_ENABLED_COMPONENTS})
    list(LENGTH AVCODEC_RESOLVED_C _nc)
    list(LENGTH AVCODEC_RESOLVED_ASM _na)
    message(STATUS "avcodec subset: resolved ${_nc} C + ${_na} ASM sources")
endif()

# Helper: append a #define CONFIG_<name> with the option-driven value.
macro(_emit_cfg _name)
    if(FFMPEG_CONFIG_${_name})
        string(APPEND _cc "#define CONFIG_${_name} 1\n")
    else()
        string(APPEND _cc "#define CONFIG_${_name} 0\n")
    endif()
endmacro()

# Helper for FFmpeg's internal capability flags (IDCTDSP, MPEGVIDEO, ADTS_HEADER,
# ...). The full build force-enables them (everything is compiled). A subset must
# instead follow the dependency closure, or base files reference helpers whose
# sources weren't compiled. _full is the value used in default-config mode.
macro(_emit_internal _name _full)
    if(FFMPEG_USE_DEFAULT_CONFIG)
        string(APPEND _cc "#define CONFIG_${_name} ${_full}\n")
    elseif("${_name}" IN_LIST AVCODEC_CLOSURE_CONFIGS)
        string(APPEND _cc "#define CONFIG_${_name} 1\n")
    else()
        string(APPEND _cc "#define CONFIG_${_name} 0\n")
    endif()
endmacro()

set(_cc "")
string(APPEND _cc [==[
#ifndef FFMPEG_CONFIG_COMPONENTS_H
#define FFMPEG_CONFIG_COMPONENTS_H

]==])
string(APPEND _cc "\n")
string(APPEND _cc "/* ---- Video decoders ---- */\n")
_emit_cfg(012V_DECODER)
_emit_cfg(4XM_DECODER)
_emit_cfg(8BPS_DECODER)
_emit_cfg(8SVX_EXP_DECODER)
_emit_cfg(8SVX_FIB_DECODER)
_emit_cfg(AAC_DECODER)
_emit_cfg(AAC_FIXED_DECODER)
_emit_cfg(AAC_LATM_DECODER)
_emit_cfg(AASC_DECODER)
_emit_cfg(AC3_DECODER)
_emit_cfg(AC3_FIXED_DECODER)
_emit_cfg(AC3_PARSER)
_emit_cfg(ACELP_KELVIN_DECODER)
_emit_cfg(AGM_DECODER)
_emit_cfg(AHX_DECODER)
_emit_cfg(AIC_DECODER)
_emit_cfg(ALAC_DECODER)
_emit_cfg(ALAC_ENCODER)
_emit_cfg(ALS_DECODER)
_emit_cfg(AMR_NB_DECODER)
_emit_cfg(AMR_WB_DECODER)
_emit_cfg(AMRNB_DECODER)
_emit_cfg(AMRWB_DECODER)
_emit_cfg(AMV_DECODER)
_emit_cfg(AMV_ENCODER)
_emit_cfg(ANM_DECODER)
_emit_cfg(ANSI_DECODER)
_emit_cfg(APAC_DECODER)
_emit_cfg(APE_DECODER)
_emit_cfg(APNG_DECODER)
_emit_cfg(APNG_ENCODER)
_emit_cfg(APV_DECODER)
_emit_cfg(APTX_DECODER)
_emit_cfg(APTX_ENCODER)
_emit_cfg(APTX_HD_DECODER)
_emit_cfg(APTX_HD_ENCODER)
_emit_cfg(ARBC_DECODER)
_emit_cfg(ARGO_DECODER)
_emit_cfg(ASS_DECODER)
_emit_cfg(ASS_ENCODER)
_emit_cfg(ASV1_DECODER)
_emit_cfg(ASV1_ENCODER)
_emit_cfg(ASV2_DECODER)
_emit_cfg(ASV2_ENCODER)
_emit_cfg(ATRAC1_DECODER)
_emit_cfg(ATRAC3_DECODER)
_emit_cfg(ATRAC3AL_DECODER)
_emit_cfg(ATRAC3P_DECODER)
_emit_cfg(ATRAC3PAL_DECODER)
_emit_cfg(ATRAC9_DECODER)
_emit_cfg(AURA_DECODER)
_emit_cfg(AURA2_DECODER)
_emit_cfg(AVRN_DECODER)
_emit_cfg(AVRP_DECODER)
_emit_cfg(AVRP_ENCODER)
_emit_cfg(AVS_DECODER)
_emit_cfg(AVUI_DECODER)
_emit_cfg(AVUI_ENCODER)
_emit_cfg(BETHSOFTVID_DECODER)
_emit_cfg(BFI_DECODER)
_emit_cfg(BINK_DECODER)
_emit_cfg(BINKAUDIO_DCT_DECODER)
_emit_cfg(BINKAUDIO_RDFT_DECODER)
_emit_cfg(BITPACKED_DECODER)
_emit_cfg(BITPACKED_ENCODER)
_emit_cfg(BMP_DECODER)
_emit_cfg(BMP_ENCODER)
_emit_cfg(BMV_AUDIO_DECODER)
_emit_cfg(BMV_VIDEO_DECODER)
_emit_cfg(BONK_DECODER)
_emit_cfg(BRENDER_PIX_DECODER)
_emit_cfg(C93_DECODER)
_emit_cfg(CAVS_DECODER)
_emit_cfg(CBD2_DPCM_DECODER)
_emit_cfg(CCAPTION_DECODER)
_emit_cfg(CDGRAPHICS_DECODER)
_emit_cfg(CDTOONS_DECODER)
_emit_cfg(CDXL_DECODER)
_emit_cfg(CFHD_DECODER)
_emit_cfg(CFHD_ENCODER)
_emit_cfg(CINEPAK_DECODER)
_emit_cfg(CINEPAK_ENCODER)
_emit_cfg(CLEARVIDEO_DECODER)
_emit_cfg(CLJR_DECODER)
_emit_cfg(CLJR_ENCODER)
_emit_cfg(CLLC_DECODER)
_emit_cfg(COMFORTNOISE_DECODER)
_emit_cfg(COMFORTNOISE_ENCODER)
_emit_cfg(COOK_DECODER)
_emit_cfg(CPIA_DECODER)
_emit_cfg(CRI_DECODER)
_emit_cfg(CSCD_DECODER)
_emit_cfg(CYUV_DECODER)
_emit_cfg(DCA_DECODER)
_emit_cfg(DCA_ENCODER)
_emit_cfg(DDS_DECODER)
_emit_cfg(DERF_DPCM_DECODER)
_emit_cfg(DFA_DECODER)
_emit_cfg(DFPWM_DECODER)
_emit_cfg(DFPWM_ENCODER)
_emit_cfg(DIRAC_DECODER)
_emit_cfg(DNXHD_DECODER)
_emit_cfg(DNXHD_ENCODER)
_emit_cfg(DOLBY_E_DECODER)
_emit_cfg(DPX_DECODER)
_emit_cfg(DPX_ENCODER)
_emit_cfg(DSD_LSBF_DECODER)
_emit_cfg(DSD_LSBF_PLANAR_DECODER)
_emit_cfg(DSD_MSBF_DECODER)
_emit_cfg(DSD_MSBF_PLANAR_DECODER)
_emit_cfg(DSICINAUDIO_DECODER)
_emit_cfg(DSICINVIDEO_DECODER)
_emit_cfg(DSS_SP_DECODER)
_emit_cfg(DST_DECODER)
_emit_cfg(DVAUDIO_DECODER)
_emit_cfg(DVBSUB_DECODER)
_emit_cfg(DVBSUB_ENCODER)
_emit_cfg(DVDSUB_DECODER)
_emit_cfg(DVDSUB_ENCODER)
_emit_cfg(DVVIDEO_DECODER)
_emit_cfg(DVVIDEO_ENCODER)
_emit_cfg(DXA_DECODER)
_emit_cfg(DXTORY_DECODER)
_emit_cfg(DXV_DECODER)
_emit_cfg(DXV_ENCODER)
_emit_cfg(EAC3_DECODER)
_emit_cfg(EAC3_ENCODER)
_emit_cfg(EACMV_DECODER)
_emit_cfg(EAMAD_DECODER)
_emit_cfg(EATGQ_DECODER)
_emit_cfg(EATGV_DECODER)
_emit_cfg(EATQI_DECODER)
_emit_cfg(EIGHTBPS_DECODER)
_emit_cfg(EIGHTSVX_EXP_DECODER)
_emit_cfg(EIGHTSVX_FIB_DECODER)
_emit_cfg(ESCAPE124_DECODER)
_emit_cfg(ESCAPE130_DECODER)
_emit_cfg(EVRC_DECODER)
_emit_cfg(EXR_DECODER)
_emit_cfg(EXR_ENCODER)
_emit_cfg(FASTAUDIO_DECODER)
_emit_cfg(FFV1_DECODER)
_emit_cfg(FFV1_ENCODER)
_emit_cfg(FFVHUFF_DECODER)
_emit_cfg(FFVHUFF_ENCODER)
_emit_cfg(FFWAVESYNTH_DECODER)
_emit_cfg(FIC_DECODER)
_emit_cfg(FITS_DECODER)
_emit_cfg(FITS_ENCODER)
_emit_cfg(FLAC_DECODER)
_emit_cfg(FLAC_ENCODER)
_emit_cfg(FLASHSV_DECODER)
_emit_cfg(FLASHSV_ENCODER)
_emit_cfg(FLASHSV2_DECODER)
_emit_cfg(FLASHSV2_ENCODER)
_emit_cfg(FLIC_DECODER)
_emit_cfg(FLV_DECODER)
_emit_cfg(FLV_ENCODER)
_emit_cfg(FMVC_DECODER)
_emit_cfg(FOURXM_DECODER)
_emit_cfg(FRAPS_DECODER)
_emit_cfg(FRWU_DECODER)
_emit_cfg(FTR_DECODER)
_emit_cfg(G2M_DECODER)
_emit_cfg(G723_1_DECODER)
_emit_cfg(G723_1_ENCODER)
_emit_cfg(G728_DECODER)
_emit_cfg(G729_DECODER)
_emit_cfg(GDV_DECODER)
_emit_cfg(GEM_DECODER)
_emit_cfg(GIF_DECODER)
_emit_cfg(GIF_ENCODER)
_emit_cfg(GREMLIN_DPCM_DECODER)
_emit_cfg(GSM_DECODER)
_emit_cfg(GSM_MS_DECODER)
_emit_cfg(H261_DECODER)
_emit_cfg(H261_ENCODER)
_emit_cfg(H263_DECODER)
_emit_cfg(H263_ENCODER)
_emit_cfg(H263I_DECODER)
_emit_cfg(H263P_DECODER)
_emit_cfg(H263P_ENCODER)
_emit_cfg(H264_DECODER)
_emit_cfg(HAP_DECODER)
_emit_cfg(HAP_ENCODER)
_emit_cfg(HCA_DECODER)
_emit_cfg(HCOM_DECODER)
_emit_cfg(HDR_DECODER)
_emit_cfg(HDR_ENCODER)
_emit_cfg(HEVC_DECODER)
_emit_cfg(HNM4_VIDEO_DECODER)
_emit_cfg(HQ_HQA_DECODER)
_emit_cfg(HQX_DECODER)
_emit_cfg(HUFFYUV_DECODER)
_emit_cfg(HUFFYUV_ENCODER)
_emit_cfg(HYMT_DECODER)
_emit_cfg(IAC_DECODER)
_emit_cfg(IDCIN_DECODER)
_emit_cfg(IFF_ILBM_DECODER)
_emit_cfg(ILBC_DECODER)
_emit_cfg(IMC_DECODER)
_emit_cfg(IMM4_DECODER)
_emit_cfg(IMM5_DECODER)
_emit_cfg(INDEO2_DECODER)
_emit_cfg(INDEO3_DECODER)
_emit_cfg(INDEO4_DECODER)
_emit_cfg(INDEO5_DECODER)
_emit_cfg(INTERPLAY_ACM_DECODER)
_emit_cfg(INTERPLAY_DPCM_DECODER)
_emit_cfg(INTERPLAY_VIDEO_DECODER)
_emit_cfg(IPU_DECODER)
_emit_cfg(JACOSUB_DECODER)
_emit_cfg(JPEG2000_DECODER)
_emit_cfg(JPEG2000_ENCODER)
_emit_cfg(JPEGLS_DECODER)
_emit_cfg(JPEGLS_ENCODER)
_emit_cfg(JV_DECODER)
_emit_cfg(KGV1_DECODER)
_emit_cfg(KMVC_DECODER)
_emit_cfg(LAGARITH_DECODER)
_emit_cfg(LEAD_DECODER)
_emit_cfg(LJPEG_ENCODER)
_emit_cfg(LOCO_DECODER)
_emit_cfg(LSCR_DECODER)
_emit_cfg(M101_DECODER)
_emit_cfg(MACE3_DECODER)
_emit_cfg(MACE6_DECODER)
_emit_cfg(MAGICYUV_DECODER)
_emit_cfg(MAGICYUV_ENCODER)
_emit_cfg(MDEC_DECODER)
_emit_cfg(MEDIA100_DECODER)
_emit_cfg(METASOUND_DECODER)
_emit_cfg(MICRODVD_DECODER)
_emit_cfg(MIMIC_DECODER)
_emit_cfg(MISC4_DECODER)
_emit_cfg(MJPEG_DECODER)
_emit_cfg(MJPEG_ENCODER)
_emit_cfg(MJPEGB_DECODER)
_emit_cfg(MLP_DECODER)
_emit_cfg(MLP_ENCODER)
_emit_cfg(MMVIDEO_DECODER)
_emit_cfg(MOBICLIP_DECODER)
_emit_cfg(MOTIONPIXELS_DECODER)
_emit_cfg(MOVTEXT_DECODER)
_emit_cfg(MOVTEXT_ENCODER)
_emit_cfg(MP1_DECODER)
_emit_cfg(MP1FLOAT_DECODER)
_emit_cfg(MP2_DECODER)
_emit_cfg(MP2_ENCODER)
_emit_cfg(MP2FIXED_ENCODER)
_emit_cfg(MP2FLOAT_DECODER)
_emit_cfg(MP3_DECODER)
_emit_cfg(MP3ADU_DECODER)
_emit_cfg(MP3ADUFLOAT_DECODER)
_emit_cfg(MP3FLOAT_DECODER)
_emit_cfg(MP3ON4_DECODER)
_emit_cfg(MP3ON4FLOAT_DECODER)
_emit_cfg(MPC7_DECODER)
_emit_cfg(MPC8_DECODER)
_emit_cfg(MPL2_DECODER)
_emit_cfg(MPEG1VIDEO_DECODER)
_emit_cfg(MPEG1VIDEO_ENCODER)
_emit_cfg(MPEG2VIDEO_DECODER)
_emit_cfg(MPEG2VIDEO_ENCODER)
_emit_cfg(MPEG4_DECODER)
_emit_cfg(MPEG4_ENCODER)
_emit_cfg(MPEGVIDEO_DECODER)
_emit_cfg(MSA1_DECODER)
_emit_cfg(MSCC_DECODER)
_emit_cfg(MSMPEG4V1_DECODER)
_emit_cfg(MSMPEG4V2_DECODER)
_emit_cfg(MSMPEG4V2_ENCODER)
_emit_cfg(MSMPEG4V3_DECODER)
_emit_cfg(MSMPEG4V3_ENCODER)
_emit_cfg(MSNSIREN_DECODER)
_emit_cfg(MSP2_DECODER)
_emit_cfg(MSRLE_DECODER)
_emit_cfg(MSRLE_ENCODER)
_emit_cfg(MSS1_DECODER)
_emit_cfg(MSS2_DECODER)
_emit_cfg(MSVIDEO1_DECODER)
_emit_cfg(MSVIDEO1_ENCODER)
_emit_cfg(MSZH_DECODER)
_emit_cfg(MTS2_DECODER)
_emit_cfg(MV30_DECODER)
_emit_cfg(MVC1_DECODER)
_emit_cfg(MVC2_DECODER)
_emit_cfg(MVDV_DECODER)
_emit_cfg(MVHA_DECODER)
_emit_cfg(MVC_DECODER)
_emit_cfg(MWSC_DECODER)
_emit_cfg(MXPEG_DECODER)
_emit_cfg(NELLYMOSER_DECODER)
_emit_cfg(NELLYMOSER_ENCODER)
_emit_cfg(NOTCHLC_DECODER)
_emit_cfg(NUV_DECODER)
_emit_cfg(ON2AVC_DECODER)
_emit_cfg(OPUS_DECODER)
_emit_cfg(OPUS_ENCODER)
_emit_cfg(OSQ_DECODER)
_emit_cfg(PAF_AUDIO_DECODER)
_emit_cfg(PAF_VIDEO_DECODER)
_emit_cfg(PAM_DECODER)
_emit_cfg(PAM_ENCODER)
_emit_cfg(PBM_DECODER)
_emit_cfg(PBM_ENCODER)
_emit_cfg(PCM_ALAW_DECODER)
_emit_cfg(PCM_ALAW_ENCODER)
_emit_cfg(PCM_BLURAY_DECODER)
_emit_cfg(PCM_BLURAY_ENCODER)
_emit_cfg(PCM_DVD_DECODER)
_emit_cfg(PCM_DVD_ENCODER)
_emit_cfg(PCM_F16LE_DECODER)
_emit_cfg(PCM_F24LE_DECODER)
_emit_cfg(PCM_F32BE_DECODER)
_emit_cfg(PCM_F32BE_ENCODER)
_emit_cfg(PCM_F32LE_DECODER)
_emit_cfg(PCM_F32LE_ENCODER)
_emit_cfg(PCM_F64BE_DECODER)
_emit_cfg(PCM_F64BE_ENCODER)
_emit_cfg(PCM_F64LE_DECODER)
_emit_cfg(PCM_F64LE_ENCODER)
_emit_cfg(PCM_LXF_DECODER)
_emit_cfg(PCM_MULAW_DECODER)
_emit_cfg(PCM_MULAW_ENCODER)
_emit_cfg(PCM_S8_DECODER)
_emit_cfg(PCM_S8_ENCODER)
_emit_cfg(PCM_S8_PLANAR_DECODER)
_emit_cfg(PCM_S8_PLANAR_ENCODER)
_emit_cfg(PCM_S16BE_DECODER)
_emit_cfg(PCM_S16BE_ENCODER)
_emit_cfg(PCM_S16BE_PLANAR_DECODER)
_emit_cfg(PCM_S16BE_PLANAR_ENCODER)
_emit_cfg(PCM_S16LE_DECODER)
_emit_cfg(PCM_S16LE_ENCODER)
_emit_cfg(PCM_S16LE_PLANAR_DECODER)
_emit_cfg(PCM_S16LE_PLANAR_ENCODER)
_emit_cfg(PCM_S24BE_DECODER)
_emit_cfg(PCM_S24BE_ENCODER)
_emit_cfg(PCM_S24DAUD_DECODER)
_emit_cfg(PCM_S24DAUD_ENCODER)
_emit_cfg(PCM_S24LE_DECODER)
_emit_cfg(PCM_S24LE_ENCODER)
_emit_cfg(PCM_S24LE_PLANAR_DECODER)
_emit_cfg(PCM_S24LE_PLANAR_ENCODER)
_emit_cfg(PCM_S32BE_DECODER)
_emit_cfg(PCM_S32BE_ENCODER)
_emit_cfg(PCM_S32LE_DECODER)
_emit_cfg(PCM_S32LE_ENCODER)
_emit_cfg(PCM_S32LE_PLANAR_DECODER)
_emit_cfg(PCM_S32LE_PLANAR_ENCODER)
_emit_cfg(PCM_S64BE_DECODER)
_emit_cfg(PCM_S64BE_ENCODER)
_emit_cfg(PCM_S64LE_DECODER)
_emit_cfg(PCM_S64LE_ENCODER)
_emit_cfg(PCM_SGA_DECODER)
_emit_cfg(PCM_U8_DECODER)
_emit_cfg(PCM_U8_ENCODER)
_emit_cfg(PCM_U16BE_DECODER)
_emit_cfg(PCM_U16BE_ENCODER)
_emit_cfg(PCM_U16LE_DECODER)
_emit_cfg(PCM_U16LE_ENCODER)
_emit_cfg(PCM_U24BE_DECODER)
_emit_cfg(PCM_U24BE_ENCODER)
_emit_cfg(PCM_U24LE_DECODER)
_emit_cfg(PCM_U24LE_ENCODER)
_emit_cfg(PCM_U32BE_DECODER)
_emit_cfg(PCM_U32BE_ENCODER)
_emit_cfg(PCM_U32LE_DECODER)
_emit_cfg(PCM_U32LE_ENCODER)
_emit_cfg(PCM_VIDC_DECODER)
_emit_cfg(PCM_VIDC_ENCODER)
_emit_cfg(PCX_DECODER)
_emit_cfg(PCX_ENCODER)
_emit_cfg(PDV_DECODER)
_emit_cfg(PDV_ENCODER)
_emit_cfg(PFM_DECODER)
_emit_cfg(PFM_ENCODER)
_emit_cfg(PGMSUB_DECODER)
_emit_cfg(PGM_DECODER)
_emit_cfg(PGM_ENCODER)
_emit_cfg(PGMYUV_DECODER)
_emit_cfg(PGMYUV_ENCODER)
_emit_cfg(PGX_DECODER)
_emit_cfg(PGSSUB_DECODER)
_emit_cfg(PHM_DECODER)
_emit_cfg(PHM_ENCODER)
_emit_cfg(PHOTOCD_DECODER)
_emit_cfg(PICTOR_DECODER)
_emit_cfg(PIXLET_DECODER)
_emit_cfg(PJS_DECODER)
_emit_cfg(PNG_DECODER)
_emit_cfg(PNG_ENCODER)
_emit_cfg(PPM_DECODER)
_emit_cfg(PPM_ENCODER)
_emit_cfg(PRORES_DECODER)
_emit_cfg(PRORES_ENCODER)
_emit_cfg(PRORES_AW_ENCODER)
_emit_cfg(PRORES_KS_ENCODER)
_emit_cfg(PRORES_RAW_DECODER)
_emit_cfg(PROSUMER_DECODER)
_emit_cfg(PSD_DECODER)
_emit_cfg(PTX_DECODER)
_emit_cfg(QDRAW_DECODER)
_emit_cfg(QDMC_DECODER)
_emit_cfg(QDM2_DECODER)
_emit_cfg(QCELP_DECODER)
_emit_cfg(QOA_DECODER)
_emit_cfg(QOI_DECODER)
_emit_cfg(QOI_ENCODER)
_emit_cfg(QPEG_DECODER)
_emit_cfg(QTRLE_DECODER)
_emit_cfg(QTRLE_ENCODER)
_emit_cfg(R10K_DECODER)
_emit_cfg(R10K_ENCODER)
_emit_cfg(R210_DECODER)
_emit_cfg(R210_ENCODER)
_emit_cfg(RA_144_DECODER)
_emit_cfg(RA_144_ENCODER)
_emit_cfg(RA_288_DECODER)
_emit_cfg(RALF_DECODER)
_emit_cfg(RASC_DECODER)
_emit_cfg(RAWVIDEO_DECODER)
_emit_cfg(RAWVIDEO_ENCODER)
_emit_cfg(REALTEXT_DECODER)
_emit_cfg(RKA_DECODER)
_emit_cfg(RL2_DECODER)
_emit_cfg(ROQ_DECODER)
_emit_cfg(ROQ_DPCM_DECODER)
_emit_cfg(ROQ_DPCM_ENCODER)
_emit_cfg(ROQ_ENCODER)
_emit_cfg(RPZA_DECODER)
_emit_cfg(RPZA_ENCODER)
_emit_cfg(RSCC_DECODER)
_emit_cfg(RTV1_DECODER)
_emit_cfg(RV10_DECODER)
_emit_cfg(RV10_ENCODER)
_emit_cfg(RV20_DECODER)
_emit_cfg(RV20_ENCODER)
_emit_cfg(RV30_DECODER)
_emit_cfg(RV40_DECODER)
_emit_cfg(RV60_DECODER)
_emit_cfg(S302M_DECODER)
_emit_cfg(S302M_ENCODER)
_emit_cfg(SAMI_DECODER)
_emit_cfg(SANM_DECODER)
_emit_cfg(SBC_DECODER)
_emit_cfg(SBC_ENCODER)
_emit_cfg(SCPR_DECODER)
_emit_cfg(SCREENPRESSO_DECODER)
_emit_cfg(SDX2_DPCM_DECODER)
_emit_cfg(SGA_DECODER)
_emit_cfg(SGI_DECODER)
_emit_cfg(SGI_ENCODER)
_emit_cfg(SGIRLE_DECODER)
_emit_cfg(SHEERVIDEO_DECODER)
_emit_cfg(SHORTEN_DECODER)
_emit_cfg(SIMBIOSIS_IMX_DECODER)
_emit_cfg(SIPR_DECODER)
_emit_cfg(SIREN_DECODER)
_emit_cfg(SMACKER_DECODER)
_emit_cfg(SMACKAUD_DECODER)
_emit_cfg(SMC_DECODER)
_emit_cfg(SMC_ENCODER)
_emit_cfg(SMVJPEG_DECODER)
_emit_cfg(SNOW_DECODER)
_emit_cfg(SNOW_ENCODER)
_emit_cfg(SOL_DPCM_DECODER)
_emit_cfg(SP5X_DECODER)
_emit_cfg(SPEEDHQ_DECODER)
_emit_cfg(SPEEDHQ_ENCODER)
_emit_cfg(SPEEX_DECODER)
_emit_cfg(SRGC_DECODER)
_emit_cfg(SRT_DECODER)
_emit_cfg(SRT_ENCODER)
_emit_cfg(SSA_DECODER)
_emit_cfg(SSA_ENCODER)
_emit_cfg(STL_DECODER)
_emit_cfg(SUBRIP_DECODER)
_emit_cfg(SUBRIP_ENCODER)
_emit_cfg(SUBVIEWER_DECODER)
_emit_cfg(SUBVIEWER1_DECODER)
_emit_cfg(SUNRAST_DECODER)
_emit_cfg(SUNRAST_ENCODER)
_emit_cfg(SVQ1_DECODER)
_emit_cfg(SVQ1_ENCODER)
_emit_cfg(SVQ3_DECODER)
_emit_cfg(TAK_DECODER)
_emit_cfg(TARGA_DECODER)
_emit_cfg(TARGA_ENCODER)
_emit_cfg(TARGA_Y216_DECODER)
_emit_cfg(TDSC_DECODER)
_emit_cfg(TEXT_DECODER)
_emit_cfg(TEXT_ENCODER)
_emit_cfg(THEORA_DECODER)
_emit_cfg(THP_DECODER)
_emit_cfg(TIERTEXSEQVIDEO_DECODER)
_emit_cfg(TIFF_DECODER)
_emit_cfg(TIFF_ENCODER)
_emit_cfg(TMV_DECODER)
_emit_cfg(TRUEHD_DECODER)
_emit_cfg(TRUEHD_ENCODER)
_emit_cfg(TRUEMOTION1_DECODER)
_emit_cfg(TRUEMOTION2_DECODER)
_emit_cfg(TRUEMOTION2RT_DECODER)
_emit_cfg(TRUESPEECH_DECODER)
_emit_cfg(TSCC_DECODER)
_emit_cfg(TSCC2_DECODER)
_emit_cfg(TTA_DECODER)
_emit_cfg(TTA_ENCODER)
_emit_cfg(TTML_ENCODER)
_emit_cfg(TWINVQ_DECODER)
_emit_cfg(TXD_DECODER)
_emit_cfg(ULTI_DECODER)
_emit_cfg(UTVIDEO_DECODER)
_emit_cfg(UTVIDEO_ENCODER)
_emit_cfg(V210_DECODER)
_emit_cfg(V210_ENCODER)
_emit_cfg(V210X_DECODER)
_emit_cfg(VB_DECODER)
_emit_cfg(VBN_DECODER)
_emit_cfg(VBN_ENCODER)
_emit_cfg(VBLE_DECODER)
_emit_cfg(VC1_DECODER)
_emit_cfg(VC1IMAGE_DECODER)
_emit_cfg(VC2_ENCODER)
_emit_cfg(VCR1_DECODER)
_emit_cfg(VMDAUDIO_DECODER)
_emit_cfg(VMDVIDEO_DECODER)
_emit_cfg(VMIX_DECODER)
_emit_cfg(VMNC_DECODER)
_emit_cfg(VORBIS_DECODER)
_emit_cfg(VORBIS_ENCODER)
_emit_cfg(VP3_DECODER)
_emit_cfg(VP4_DECODER)
_emit_cfg(VP5_DECODER)
_emit_cfg(VP6_DECODER)
_emit_cfg(VP6A_DECODER)
_emit_cfg(VP6F_DECODER)
_emit_cfg(VP7_DECODER)
_emit_cfg(VP8_DECODER)
_emit_cfg(VP9_DECODER)
_emit_cfg(VPLAYER_DECODER)
_emit_cfg(VQA_DECODER)
_emit_cfg(VQC_DECODER)
_emit_cfg(VVC_DECODER)
_emit_cfg(WADY_DPCM_DECODER)
_emit_cfg(WAVARC_DECODER)
_emit_cfg(WAVPACK_DECODER)
_emit_cfg(WAVPACK_ENCODER)
_emit_cfg(WBMP_DECODER)
_emit_cfg(WBMP_ENCODER)
_emit_cfg(WEBP_DECODER)
_emit_cfg(WEBVTT_DECODER)
_emit_cfg(WEBVTT_ENCODER)
_emit_cfg(WCMV_DECODER)
_emit_cfg(WMALOSSLESS_DECODER)
_emit_cfg(WMAPRO_DECODER)
_emit_cfg(WMAV1_DECODER)
_emit_cfg(WMAV1_ENCODER)
_emit_cfg(WMAV2_DECODER)
_emit_cfg(WMAV2_ENCODER)
_emit_cfg(WMAVOICE_DECODER)
_emit_cfg(WMV1_DECODER)
_emit_cfg(WMV1_ENCODER)
_emit_cfg(WMV2_DECODER)
_emit_cfg(WMV2_ENCODER)
_emit_cfg(WMV3_DECODER)
_emit_cfg(WMV3IMAGE_DECODER)
_emit_cfg(WNV1_DECODER)
_emit_cfg(WRAPPED_AVFRAME_DECODER)
_emit_cfg(WRAPPED_AVFRAME_ENCODER)
_emit_cfg(WS_SND1_DECODER)
_emit_cfg(XAN_DPCM_DECODER)
_emit_cfg(XAN_WC3_DECODER)
_emit_cfg(XAN_WC4_DECODER)
_emit_cfg(XBM_DECODER)
_emit_cfg(XBM_ENCODER)
_emit_cfg(XFACE_DECODER)
_emit_cfg(XFACE_ENCODER)
_emit_cfg(XL_DECODER)
_emit_cfg(XMA1_DECODER)
_emit_cfg(XMA2_DECODER)
_emit_cfg(XPM_DECODER)
_emit_cfg(XSUB_DECODER)
_emit_cfg(XSUB_ENCODER)
_emit_cfg(XWD_DECODER)
_emit_cfg(XWD_ENCODER)
_emit_cfg(Y41P_DECODER)
_emit_cfg(Y41P_ENCODER)
_emit_cfg(YLC_DECODER)
_emit_cfg(YOP_DECODER)
_emit_cfg(YUV4_DECODER)
_emit_cfg(YUV4_ENCODER)
_emit_cfg(ZERO12V_DECODER)
_emit_cfg(ZEROCODEC_DECODER)
_emit_cfg(ZLIB_DECODER)
_emit_cfg(ZLIB_ENCODER)
_emit_cfg(ZMBV_DECODER)
_emit_cfg(ZMBV_ENCODER)
string(APPEND _cc "\n")
string(APPEND _cc [==[
/* ---- Hardware accelerators — disabled ---- */
#define CONFIG_AV1_D3D12VA_HWACCEL   0
#define CONFIG_AV1_DXVA2_HWACCEL     0
#define CONFIG_AV1_NVDEC_HWACCEL     0
#define CONFIG_AV1_VAAPI_HWACCEL     0
#define CONFIG_AV1_VULKAN_HWACCEL    0
#define CONFIG_H264_D3D11VA_HWACCEL  0
#define CONFIG_H264_D3D11VA2_HWACCEL 0
#define CONFIG_H264_D3D12VA_HWACCEL  0
#define CONFIG_H264_DXVA2_HWACCEL    0
#define CONFIG_H264_NVDEC_HWACCEL    0
#define CONFIG_H264_VAAPI_HWACCEL    0
#define CONFIG_H264_VDPAU_HWACCEL    0
#define CONFIG_H264_VIDEOTOOLBOX_HWACCEL 0
#define CONFIG_H264_VULKAN_HWACCEL   0
#define CONFIG_HEVC_D3D11VA_HWACCEL  0
#define CONFIG_HEVC_D3D12VA_HWACCEL  0
#define CONFIG_HEVC_DXVA2_HWACCEL    0
#define CONFIG_HEVC_NVDEC_HWACCEL    0
#define CONFIG_HEVC_VAAPI_HWACCEL    0
#define CONFIG_HEVC_VDPAU_HWACCEL    0
#define CONFIG_HEVC_VULKAN_HWACCEL   0
#define CONFIG_MPEG1_NVDEC_HWACCEL   0
#define CONFIG_MPEG2_D3D11VA_HWACCEL 0
#define CONFIG_MPEG2_D3D12VA_HWACCEL 0
#define CONFIG_MPEG2_DXVA2_HWACCEL   0
#define CONFIG_MPEG2_NVDEC_HWACCEL   0
#define CONFIG_MPEG2_VAAPI_HWACCEL   0
#define CONFIG_MPEG2_VDPAU_HWACCEL   0
#define CONFIG_MPEG4_NVDEC_HWACCEL   0
#define CONFIG_MPEG4_VAAPI_HWACCEL   0
#define CONFIG_MPEG4_VDPAU_HWACCEL   0
#define CONFIG_VC1_D3D11VA_HWACCEL   0
#define CONFIG_VC1_D3D12VA_HWACCEL   0
#define CONFIG_VC1_DXVA2_HWACCEL     0
#define CONFIG_VC1_NVDEC_HWACCEL     0
#define CONFIG_VC1_VAAPI_HWACCEL     0
#define CONFIG_VC1_VDPAU_HWACCEL     0
#define CONFIG_VP8_NVDEC_HWACCEL     0
#define CONFIG_VP9_D3D11VA_HWACCEL   0
#define CONFIG_VP9_D3D12VA_HWACCEL   0
#define CONFIG_VP9_DXVA2_HWACCEL     0
#define CONFIG_VP9_NVDEC_HWACCEL     0
#define CONFIG_VP9_VAAPI_HWACCEL     0
#define CONFIG_VP9_VDPAU_HWACCEL     0
#define CONFIG_VP9_VULKAN_HWACCEL    0

]==])
string(APPEND _cc "\n")
string(APPEND _cc "/* ---- Parsers ---- */\n")
_emit_cfg(AAC_LATM_PARSER)
_emit_cfg(AAC_PARSER)
_emit_cfg(ADX_PARSER)
_emit_cfg(AHX_PARSER)
_emit_cfg(AMR_PARSER)
_emit_cfg(APV_PARSER)
_emit_cfg(AV1_PARSER)
_emit_cfg(AVS2_PARSER)
_emit_cfg(AVS3_PARSER)
_emit_cfg(BMP_PARSER)
_emit_cfg(CAVSVIDEO_PARSER)
_emit_cfg(COOK_PARSER)
_emit_cfg(CRI_PARSER)
_emit_cfg(DCA_PARSER)
_emit_cfg(DIRAC_PARSER)
_emit_cfg(DNXHD_PARSER)
_emit_cfg(DNXUC_PARSER)
_emit_cfg(DOLBY_E_PARSER)
_emit_cfg(DPX_PARSER)
_emit_cfg(DVAUDIO_PARSER)
_emit_cfg(DVBSUB_PARSER)
_emit_cfg(DVDSUB_PARSER)
_emit_cfg(DVD_NAV_PARSER)
_emit_cfg(EVC_PARSER)
_emit_cfg(FFV1_PARSER)
_emit_cfg(FLAC_PARSER)
_emit_cfg(FTR_PARSER)
_emit_cfg(G723_1_PARSER)
_emit_cfg(G729_PARSER)
_emit_cfg(GIF_PARSER)
_emit_cfg(GSM_PARSER)
_emit_cfg(H261_PARSER)
_emit_cfg(H263_PARSER)
_emit_cfg(H264_PARSER)
_emit_cfg(HDR_PARSER)
_emit_cfg(HEVC_PARSER)
_emit_cfg(IPU_PARSER)
_emit_cfg(JPEG2000_PARSER)
_emit_cfg(JPEGXL_PARSER)
_emit_cfg(JPEGXS_PARSER)
_emit_cfg(LCEVC_PARSER)
_emit_cfg(MISC4_PARSER)
_emit_cfg(MJPEG_PARSER)
_emit_cfg(MLP_PARSER)
_emit_cfg(MPEG4VIDEO_PARSER)
_emit_cfg(MPEGAUDIO_PARSER)
_emit_cfg(MPEGVIDEO_PARSER)
_emit_cfg(OPUS_PARSER)
_emit_cfg(PNG_PARSER)
_emit_cfg(PNM_PARSER)
_emit_cfg(PRORES_PARSER)
_emit_cfg(PRORES_RAW_PARSER)
_emit_cfg(QOI_PARSER)
_emit_cfg(RV34_PARSER)
_emit_cfg(SBC_PARSER)
_emit_cfg(SIPR_PARSER)
_emit_cfg(TAK_PARSER)
_emit_cfg(VC1_PARSER)
_emit_cfg(VORBIS_PARSER)
_emit_cfg(VP3_PARSER)
_emit_cfg(VP8_PARSER)
_emit_cfg(VP9_PARSER)
_emit_cfg(VVC_PARSER)
_emit_cfg(WEBP_PARSER)
_emit_cfg(XBM_PARSER)
_emit_cfg(XMA_PARSER)
_emit_cfg(XWD_PARSER)
string(APPEND _cc "\n")
string(APPEND _cc "/* ---- Bitstream filters ---- */\n")
_emit_cfg(AAC_ADTSTOASC_BSF)
_emit_cfg(AHX_TO_MP2_BSF)
_emit_cfg(APV_METADATA_BSF)
_emit_cfg(AV1_FRAME_MERGE_BSF)
_emit_cfg(AV1_FRAME_SPLIT_BSF)
_emit_cfg(AV1_METADATA_BSF)
_emit_cfg(CHOMP_BSF)
_emit_cfg(DCA_CORE_BSF)
_emit_cfg(DOVI_RPU_BSF)
_emit_cfg(DOVI_SPLIT_BSF)
_emit_cfg(DTS2PTS_BSF)
_emit_cfg(DV_ERROR_MARKER_BSF)
_emit_cfg(DUMP_EXTRADATA_BSF)
_emit_cfg(EAC3_CORE_BSF)
_emit_cfg(EIA608_TO_SMPTE436M_BSF)
_emit_cfg(EVC_FRAME_MERGE_BSF)
_emit_cfg(EXTRACT_EXTRADATA_BSF)
_emit_cfg(FILTER_UNITS_BSF)
_emit_cfg(H264_METADATA_BSF)
_emit_cfg(H264_MP4TOANNEXB_BSF)
_emit_cfg(H264_REDUNDANT_PPS_BSF)
_emit_cfg(HAPQA_EXTRACT_BSF)
_emit_cfg(HEVC_METADATA_BSF)
_emit_cfg(HEVC_MP4TOANNEXB_BSF)
_emit_cfg(IMX_DUMP_HEADER_BSF)
_emit_cfg(LCEVC_METADATA_BSF)
_emit_cfg(MEDIA100_TO_MJPEGB_BSF)
_emit_cfg(MJPEG2JPEG_BSF)
_emit_cfg(MJPEGA_DUMP_HEADER_BSF)
_emit_cfg(MOV2TEXTSUB_BSF)
_emit_cfg(MPEG2_METADATA_BSF)
_emit_cfg(MPEG4_UNPACK_BFRAMES_BSF)
_emit_cfg(NOISE_BSF)
_emit_cfg(NULL_BSF)
_emit_cfg(OPUS_METADATA_BSF)
_emit_cfg(PCM_RECHUNK_BSF)
_emit_cfg(PGS_FRAME_MERGE_BSF)
_emit_cfg(PRORES_METADATA_BSF)
_emit_cfg(REMOVE_EXTRADATA_BSF)
_emit_cfg(SETTS_BSF)
_emit_cfg(SHOWINFO_BSF)
_emit_cfg(SMPTE436M_TO_EIA608_BSF)
_emit_cfg(TEXT2MOVSUB_BSF)
_emit_cfg(TRACE_HEADERS_BSF)
_emit_cfg(TRUEHD_CORE_BSF)
_emit_cfg(VP9_METADATA_BSF)
_emit_cfg(VP9_RAW_REORDER_BSF)
_emit_cfg(VP9_SUPERFRAME_BSF)
_emit_cfg(VP9_SUPERFRAME_SPLIT_BSF)
_emit_cfg(VVC_METADATA_BSF)
_emit_cfg(VVC_MP4TOANNEXB_BSF)
string(APPEND _cc "\n")
string(APPEND _cc "/* ---- CBS (Coded Bitstream) ---- */\n")
_emit_cfg(CBS_AV1)
_emit_cfg(CBS_H264)
_emit_cfg(CBS_H265)
_emit_cfg(CBS_H266)
_emit_cfg(CBS_JPEG)
_emit_cfg(CBS_MPEG2)
_emit_cfg(CBS_VP8)
_emit_cfg(CBS_VP9)
_emit_cfg(CBS_APV)
_emit_cfg(CBS_LCEVC)
string(APPEND _cc "\n")
string(APPEND _cc "/* ---- Null / wrapped codecs ---- */\n")
_emit_cfg(VNULL_DECODER)
_emit_cfg(VNULL_ENCODER)
_emit_cfg(ANULL_DECODER)
_emit_cfg(ANULL_ENCODER)
string(APPEND _cc "\n")
string(APPEND _cc "/* ---- Native codecs missing from initial list ---- */\n")
_emit_cfg(A64MULTI_ENCODER)
_emit_cfg(A64MULTI5_ENCODER)
_emit_cfg(AAC_ENCODER)
_emit_cfg(BINTEXT_DECODER)
_emit_cfg(FRAME_THREAD_ENCODER)
_emit_cfg(IDF_DECODER)
_emit_cfg(WEBP_ANIM_DECODER)
_emit_cfg(XBIN_DECODER)
string(APPEND _cc "\n")
string(APPEND _cc "/* ---- ADPCM decoders ---- */\n")
_emit_cfg(ADPCM_4XM_DECODER)
_emit_cfg(ADPCM_ADX_DECODER)
_emit_cfg(ADPCM_AFC_DECODER)
_emit_cfg(ADPCM_AGM_DECODER)
_emit_cfg(ADPCM_AICA_DECODER)
_emit_cfg(ADPCM_ARGO_DECODER)
_emit_cfg(ADPCM_CIRCUS_DECODER)
_emit_cfg(ADPCM_CT_DECODER)
_emit_cfg(ADPCM_DTK_DECODER)
_emit_cfg(ADPCM_EA_DECODER)
_emit_cfg(ADPCM_EA_MAXIS_XA_DECODER)
_emit_cfg(ADPCM_EA_R1_DECODER)
_emit_cfg(ADPCM_EA_R2_DECODER)
_emit_cfg(ADPCM_EA_R3_DECODER)
_emit_cfg(ADPCM_EA_XAS_DECODER)
_emit_cfg(ADPCM_G722_DECODER)
_emit_cfg(ADPCM_G726_DECODER)
_emit_cfg(ADPCM_G726LE_DECODER)
_emit_cfg(ADPCM_IMA_ACORN_DECODER)
_emit_cfg(ADPCM_IMA_ALP_DECODER)
_emit_cfg(ADPCM_IMA_AMV_DECODER)
_emit_cfg(ADPCM_IMA_APC_DECODER)
_emit_cfg(ADPCM_IMA_APM_DECODER)
_emit_cfg(ADPCM_IMA_CUNNING_DECODER)
_emit_cfg(ADPCM_IMA_DAT4_DECODER)
_emit_cfg(ADPCM_IMA_DK3_DECODER)
_emit_cfg(ADPCM_IMA_DK4_DECODER)
_emit_cfg(ADPCM_IMA_EA_EACS_DECODER)
_emit_cfg(ADPCM_IMA_EA_SEAD_DECODER)
_emit_cfg(ADPCM_IMA_ESCAPE_DECODER)
_emit_cfg(ADPCM_IMA_HVQM2_DECODER)
_emit_cfg(ADPCM_IMA_HVQM4_DECODER)
_emit_cfg(ADPCM_IMA_ISS_DECODER)
_emit_cfg(ADPCM_IMA_MAGIX_DECODER)
_emit_cfg(ADPCM_IMA_MOFLEX_DECODER)
_emit_cfg(ADPCM_IMA_MTF_DECODER)
_emit_cfg(ADPCM_IMA_OKI_DECODER)
_emit_cfg(ADPCM_IMA_PDA_DECODER)
_emit_cfg(ADPCM_IMA_QT_DECODER)
_emit_cfg(ADPCM_IMA_RAD_DECODER)
_emit_cfg(ADPCM_IMA_SMJPEG_DECODER)
_emit_cfg(ADPCM_IMA_SSI_DECODER)
_emit_cfg(ADPCM_IMA_WAV_DECODER)
_emit_cfg(ADPCM_IMA_WS_DECODER)
_emit_cfg(ADPCM_IMA_XBOX_DECODER)
_emit_cfg(ADPCM_MS_DECODER)
_emit_cfg(ADPCM_MTAF_DECODER)
_emit_cfg(ADPCM_N64_DECODER)
_emit_cfg(ADPCM_PSX_DECODER)
_emit_cfg(ADPCM_PSXC_DECODER)
_emit_cfg(ADPCM_SANYO_DECODER)
_emit_cfg(ADPCM_SBPRO_2_DECODER)
_emit_cfg(ADPCM_SBPRO_3_DECODER)
_emit_cfg(ADPCM_SBPRO_4_DECODER)
_emit_cfg(ADPCM_SWF_DECODER)
_emit_cfg(ADPCM_THP_DECODER)
_emit_cfg(ADPCM_THP_LE_DECODER)
_emit_cfg(ADPCM_VIMA_DECODER)
_emit_cfg(ADPCM_XA_DECODER)
_emit_cfg(ADPCM_XMD_DECODER)
_emit_cfg(ADPCM_YAMAHA_DECODER)
_emit_cfg(ADPCM_ZORK_DECODER)
string(APPEND _cc "\n")
string(APPEND _cc "/* ---- ADPCM encoders ---- */\n")
_emit_cfg(ADPCM_ADX_ENCODER)
_emit_cfg(ADPCM_ARGO_ENCODER)
_emit_cfg(ADPCM_G722_ENCODER)
_emit_cfg(ADPCM_G726_ENCODER)
_emit_cfg(ADPCM_G726LE_ENCODER)
_emit_cfg(ADPCM_IMA_ALP_ENCODER)
_emit_cfg(ADPCM_IMA_AMV_ENCODER)
_emit_cfg(ADPCM_IMA_APM_ENCODER)
_emit_cfg(ADPCM_IMA_QT_ENCODER)
_emit_cfg(ADPCM_IMA_SSI_ENCODER)
_emit_cfg(ADPCM_IMA_WAV_ENCODER)
_emit_cfg(ADPCM_IMA_WS_ENCODER)
_emit_cfg(ADPCM_MS_ENCODER)
_emit_cfg(ADPCM_SWF_ENCODER)
_emit_cfg(ADPCM_YAMAHA_ENCODER)
string(APPEND _cc "\n")
string(APPEND _cc [==[
/* ---- Internal capability flags ---- */
#define CONFIG_HARDCODED_TABLES      0
#define CONFIG_FTRAPV                0
#define CONFIG_DEFLATE_WRAPPER       1
#define CONFIG_INFLATE_WRAPPER       1
]==])
# Codec/DSP-internal helpers: force-on for the full build (everything compiles),
# but closure-driven for subset builds so base files don't reference helpers whose
# sources weren't compiled. See _emit_internal / AVCODEC_CLOSURE_CONFIGS above.
_emit_internal(ERROR_RESILIENCE    1)
_emit_internal(FAANDCT             1)
_emit_internal(FAANIDCT            1)
_emit_internal(FDCTDSP             1)
_emit_internal(IDCTDSP             1)
_emit_internal(ME_CMP              1)
_emit_internal(MPEGVIDEO           1)
_emit_internal(MPEGVIDEODEC        1)
_emit_internal(MPEGVIDEOENCDSP     1)
_emit_internal(MSMPEG4DEC          1)
_emit_internal(MSMPEG4ENC          1)
_emit_internal(H264                1)
_emit_internal(H264_SEI            1)
_emit_internal(H264_VUI_PARAMETERS 1)
_emit_internal(HEVC                1)
_emit_internal(HEVC_SEI            1)
_emit_internal(HEVC_VUI_PARAMETERS 1)
_emit_internal(VVC_SEI             1)
_emit_internal(AV1                 1)
_emit_internal(ADTS_HEADER         1)
_emit_internal(ATSC_A53            1)
_emit_internal(DIRAC_PARSE         1)
_emit_internal(DVPROFILE           1)
_emit_internal(PIXBLOCKDSP         1)
# These four codecs are registered unconditionally by the generated codec_list.c
# (their entries were unguarded). They have no FFMPEG_CONFIG_* option, so define
# the macros here: present in the full build, absent in a subset.
_emit_internal(ALIAS_PIX_ENCODER   1)
_emit_internal(ALIAS_PIX_DECODER   1)
_emit_internal(AC3_ENCODER         1)
_emit_internal(AC3_FIXED_ENCODER   1)
string(APPEND _cc [==[
#define CONFIG_ENCODER               1
#define CONFIG_ENCODER_DEVICE        1
#define CONFIG_ENCODER_FRAMES        1
#define CONFIG_HWACCEL               0
#define CONFIG_INTRAREFRESHVOPTYPE   0
#define CONFIG_EXT_FILL              0
#define CONFIG_EXT_LOUDNESS_INFO     0
#define CONFIG_EXT_STREAM_ID         0
#define CONFIG_D3D12_INTRA_REFRESH   0
#define CONFIG_D3D12VA_ME_PRECISION_EIGHTH_PIXEL 0
#define CONFIG_ALPHA_MODE            0
#define CONFIG_ZLIB                  1
#define CONFIG_ICONV                 0
#define CONFIG_LCMS2                 0
#define CONFIG_LZMA                  0
#define CONFIG_LIBLCEVC_DEC          0
#define CONFIG_MEDIACODEC            0
#define CONFIG_JNI                   0
#define CONFIG_OMX_RPI               0
#define CONFIG_LIBX264_HDR10         0
#define CONFIG_VAAPI_1               0
#define CONFIG_LIBOPENCORE_AMRNB     0

/* ---- Hardware / external-library codecs — disabled ---- */
#define CONFIG_AAC_MEDIACODEC_DECODER        0
#define CONFIG_AC3_AT_DECODER                0
#define CONFIG_AMRNB_MEDIACODEC_DECODER      0
#define CONFIG_AMRWB_MEDIACODEC_DECODER      0
#define CONFIG_APV_VULKAN_HWACCEL            0
#define CONFIG_AV1_CUVID_DECODER             0
#define CONFIG_AV1_D3D11VA_HWACCEL           0
#define CONFIG_AV1_D3D11VA2_HWACCEL          0
#define CONFIG_AV1_D3D12VA_ENCODER           0
#define CONFIG_AV1_MEDIACODEC_DECODER        0
#define CONFIG_AV1_MEDIACODEC_ENCODER        0
#define CONFIG_AV1_NVENC_ENCODER             0
#define CONFIG_AV1_QSV_DECODER               0
#define CONFIG_AV1_VDPAU_HWACCEL             0
#define CONFIG_AV1_VIDEOTOOLBOX_HWACCEL      0
#define CONFIG_DPX_VULKAN_HWACCEL            0
#define CONFIG_EAC3_AT_DECODER               0
#define CONFIG_FFV1_VULKAN_HWACCEL           0
#define CONFIG_H263_VAAPI_HWACCEL            0
#define CONFIG_H263_VIDEOTOOLBOX_HWACCEL     0
#define CONFIG_H264_CUVID_DECODER            0
#define CONFIG_H264_MEDIACODEC_DECODER       0
#define CONFIG_H264_MEDIACODEC_ENCODER       0
#define CONFIG_H264_OH_DECODER               0
#define CONFIG_H264_OH_ENCODER               0
#define CONFIG_H264_QSV_DECODER              0
#define CONFIG_H264_RKMPP_ENCODER            0
#define CONFIG_HEVC_CUVID_DECODER            0
#define CONFIG_HEVC_D3D11VA2_HWACCEL         0
#define CONFIG_HEVC_MEDIACODEC_DECODER       0
#define CONFIG_HEVC_MEDIACODEC_ENCODER       0
#define CONFIG_HEVC_OH_DECODER               0
#define CONFIG_HEVC_OH_ENCODER               0
#define CONFIG_HEVC_QSV_DECODER              0
#define CONFIG_HEVC_RKMPP_ENCODER            0
#define CONFIG_HEVC_VIDEOTOOLBOX_HWACCEL     0
#define CONFIG_LIBGSM_DECODER                0
#define CONFIG_LIBGSM_ENCODER                0
#define CONFIG_LIBGSM_MS_DECODER             0
#define CONFIG_LIBGSM_MS_ENCODER             0
#define CONFIG_LIBOPENCORE_AMRNB_DECODER     0
#define CONFIG_LIBOPENCORE_AMRNB_ENCODER     0
#define CONFIG_LIBOPENCORE_AMRWB_DECODER     0
#define CONFIG_LIBVPX_VP8_DECODER            0
#define CONFIG_LIBVPX_VP8_ENCODER            0
#define CONFIG_LIBVPX_VP9_DECODER            0
#define CONFIG_LIBVPX_VP9_ENCODER            0
#define CONFIG_LIBX262_ENCODER               0
#define CONFIG_LIBX264_ENCODER               0
#define CONFIG_LIBX264RGB_ENCODER            0
#define CONFIG_MJPEG_CUVID_DECODER           0
#define CONFIG_MJPEG_NVDEC_HWACCEL           0
#define CONFIG_MJPEG_QSV_DECODER             0
#define CONFIG_MJPEG_VAAPI_HWACCEL           0
#define CONFIG_MP1_AT_DECODER                0
#define CONFIG_MP2_AT_DECODER                0
#define CONFIG_MP3_AT_DECODER                0
#define CONFIG_MP3_MEDIACODEC_DECODER        0
#define CONFIG_MPEG1_CUVID_DECODER           0
#define CONFIG_MPEG1_VDPAU_HWACCEL           0
#define CONFIG_MPEG1_VIDEOTOOLBOX_HWACCEL    0
#define CONFIG_MPEG2_CUVID_DECODER           0
#define CONFIG_MPEG2_D3D11VA2_HWACCEL        0
#define CONFIG_MPEG2_MEDIACODEC_DECODER      0
#define CONFIG_MPEG2_QSV_DECODER             0
#define CONFIG_MPEG2_VIDEOTOOLBOX_HWACCEL    0
#define CONFIG_MPEG4_CUVID_DECODER           0
#define CONFIG_MPEG4_MEDIACODEC_DECODER      0
#define CONFIG_MPEG4_MEDIACODEC_ENCODER      0
#define CONFIG_MPEG4_VIDEOTOOLBOX_HWACCEL    0
#define CONFIG_PRORES_RAW_VIDEOTOOLBOX_HWACCEL 0
#define CONFIG_PRORES_RAW_VULKAN_HWACCEL     0
#define CONFIG_PRORES_VIDEOTOOLBOX_HWACCEL   0
#define CONFIG_PRORES_VULKAN_HWACCEL         0
#define CONFIG_VC1_CUVID_DECODER             0
#define CONFIG_VC1_D3D11VA2_HWACCEL          0
#define CONFIG_VC1_QSV_DECODER               0
#define CONFIG_VP8_CUVID_DECODER             0
#define CONFIG_VP8_MEDIACODEC_DECODER        0
#define CONFIG_VP8_MEDIACODEC_ENCODER        0
#define CONFIG_VP8_QSV_DECODER               0
#define CONFIG_VP8_VAAPI_HWACCEL             0
#define CONFIG_VP9_CUVID_DECODER             0
#define CONFIG_VP9_D3D11VA2_HWACCEL          0
#define CONFIG_VP9_MEDIACODEC_DECODER        0
#define CONFIG_VP9_MEDIACODEC_ENCODER        0
#define CONFIG_VP9_QSV_DECODER               0
#define CONFIG_VP9_VIDEOTOOLBOX_HWACCEL      0
#define CONFIG_VVC_QSV_DECODER               0
#define CONFIG_VVC_VAAPI_HWACCEL             0
#define CONFIG_WMV3_D3D11VA_HWACCEL          0
#define CONFIG_WMV3_D3D11VA2_HWACCEL         0
#define CONFIG_WMV3_D3D12VA_HWACCEL          0
#define CONFIG_WMV3_DXVA2_HWACCEL            0
#define CONFIG_WMV3_NVDEC_HWACCEL            0
#define CONFIG_WMV3_VAAPI_HWACCEL            0
#define CONFIG_WMV3_VDPAU_HWACCEL            0

#endif /* FFMPEG_CONFIG_COMPONENTS_H */
]==])
string(APPEND _cc "\n")
file(WRITE "${CMAKE_BINARY_DIR}/config_components.h" "${_cc}")

# Generate config_components.asm for NASM (same defines, %define syntax)
if(HAVE_X86ASM)
    file(READ "${CMAKE_BINARY_DIR}/config_components.h" _cc_h)
    string(REGEX MATCHALL "#define CONFIG_[A-Z0-9_]+ [01]" _cc_defs "${_cc_h}")
    string(REPLACE ";" "\n" _cc_defs "${_cc_defs}")
    string(REPLACE "#define " "%define " _cc_defs "${_cc_defs}")
    file(WRITE "${CMAKE_BINARY_DIR}/config_components.asm" "; Automatically generated - do not modify!\n${_cc_defs}\n")
endif()

# ---------------------------------------------------------------------------
# Generate codec_list.c, parser_list.c, bsf_list.c into build/libavcodec/
# (allcodecs.c / parsers.c / bitstream_filters.c use  #include "libavcodec/X")
# ---------------------------------------------------------------------------
file(MAKE_DIRECTORY "${CMAKE_BINARY_DIR}/libavcodec")

file(WRITE "${CMAKE_BINARY_DIR}/libavcodec/codec_list.c" [=[
#include "config_components.h"
/* Auto-generated by CMakeLists.txt — native software codecs only */
static const FFCodec * const codec_list[] = {
    /* video */
    #if CONFIG_A64MULTI_ENCODER
        &ff_a64multi_encoder,
    #endif
    #if CONFIG_A64MULTI5_ENCODER
        &ff_a64multi5_encoder,
    #endif
    #if CONFIG_AASC_DECODER
        &ff_aasc_decoder,
    #endif
    #if CONFIG_AIC_DECODER
        &ff_aic_decoder,
    #endif
    #if CONFIG_ALIAS_PIX_ENCODER
        &ff_alias_pix_encoder,
    #endif
    #if CONFIG_ALIAS_PIX_DECODER
        &ff_alias_pix_decoder,
    #endif
    #if CONFIG_AGM_DECODER
        &ff_agm_decoder,
    #endif
    #if CONFIG_AMV_ENCODER
        &ff_amv_encoder,
    #endif
    #if CONFIG_AMV_DECODER
        &ff_amv_decoder,
    #endif
    #if CONFIG_ANM_DECODER
        &ff_anm_decoder,
    #endif
    #if CONFIG_ANSI_DECODER
        &ff_ansi_decoder,
    #endif
    #if CONFIG_APNG_ENCODER
        &ff_apng_encoder,
    #endif
    #if CONFIG_APNG_DECODER
        &ff_apng_decoder,
    #endif
    #if CONFIG_APV_DECODER
        &ff_apv_decoder,
    #endif
    #if CONFIG_ARBC_DECODER
        &ff_arbc_decoder,
    #endif
    #if CONFIG_ARGO_DECODER
        &ff_argo_decoder,
    #endif
    #if CONFIG_ASV1_ENCODER
        &ff_asv1_encoder,
    #endif
    #if CONFIG_ASV1_DECODER
        &ff_asv1_decoder,
    #endif
    #if CONFIG_ASV2_ENCODER
        &ff_asv2_encoder,
    #endif
    #if CONFIG_ASV2_DECODER
        &ff_asv2_decoder,
    #endif
    #if CONFIG_AURA_DECODER
        &ff_aura_decoder,
    #endif
    #if CONFIG_AURA2_DECODER
        &ff_aura2_decoder,
    #endif
    #if CONFIG_AVRP_ENCODER
        &ff_avrp_encoder,
    #endif
    #if CONFIG_AVRP_DECODER
        &ff_avrp_decoder,
    #endif
    #if CONFIG_AVRN_DECODER
        &ff_avrn_decoder,
    #endif
    #if CONFIG_AVS_DECODER
        &ff_avs_decoder,
    #endif
    #if CONFIG_AVUI_ENCODER
        &ff_avui_encoder,
    #endif
    #if CONFIG_AVUI_DECODER
        &ff_avui_decoder,
    #endif
    #if CONFIG_BETHSOFTVID_DECODER
        &ff_bethsoftvid_decoder,
    #endif
    #if CONFIG_BFI_DECODER
        &ff_bfi_decoder,
    #endif
    #if CONFIG_BINK_DECODER
        &ff_bink_decoder,
    #endif
    #if CONFIG_BITPACKED_DECODER
        &ff_bitpacked_decoder,
    #endif
    #if CONFIG_BITPACKED_ENCODER
        &ff_bitpacked_encoder,
    #endif
    #if CONFIG_BMP_ENCODER
        &ff_bmp_encoder,
    #endif
    #if CONFIG_BMP_DECODER
        &ff_bmp_decoder,
    #endif
    #if CONFIG_BMV_VIDEO_DECODER
        &ff_bmv_video_decoder,
    #endif
    #if CONFIG_BRENDER_PIX_DECODER
        &ff_brender_pix_decoder,
    #endif
    #if CONFIG_C93_DECODER
        &ff_c93_decoder,
    #endif
    #if CONFIG_CAVS_DECODER
        &ff_cavs_decoder,
    #endif
    #if CONFIG_CDGRAPHICS_DECODER
        &ff_cdgraphics_decoder,
    #endif
    #if CONFIG_CDTOONS_DECODER
        &ff_cdtoons_decoder,
    #endif
    #if CONFIG_CDXL_DECODER
        &ff_cdxl_decoder,
    #endif
    #if CONFIG_CFHD_ENCODER
        &ff_cfhd_encoder,
    #endif
    #if CONFIG_CFHD_DECODER
        &ff_cfhd_decoder,
    #endif
    #if CONFIG_CINEPAK_ENCODER
        &ff_cinepak_encoder,
    #endif
    #if CONFIG_CINEPAK_DECODER
        &ff_cinepak_decoder,
    #endif
    #if CONFIG_CLEARVIDEO_DECODER
        &ff_clearvideo_decoder,
    #endif
    #if CONFIG_CLJR_ENCODER
        &ff_cljr_encoder,
    #endif
    #if CONFIG_CLJR_DECODER
        &ff_cljr_decoder,
    #endif
    #if CONFIG_CLLC_DECODER
        &ff_cllc_decoder,
    #endif
    #if CONFIG_COMFORTNOISE_ENCODER
        &ff_comfortnoise_encoder,
    #endif
    #if CONFIG_COMFORTNOISE_DECODER
        &ff_comfortnoise_decoder,
    #endif
    #if CONFIG_CPIA_DECODER
        &ff_cpia_decoder,
    #endif
    #if CONFIG_CRI_DECODER
        &ff_cri_decoder,
    #endif
    #if CONFIG_CSCD_DECODER
        &ff_cscd_decoder,
    #endif
    #if CONFIG_CYUV_DECODER
        &ff_cyuv_decoder,
    #endif
    #if CONFIG_DDS_DECODER
        &ff_dds_decoder,
    #endif
    #if CONFIG_DFA_DECODER
        &ff_dfa_decoder,
    #endif
    #if CONFIG_DIRAC_DECODER
        &ff_dirac_decoder,
    #endif
    #if CONFIG_DNXHD_ENCODER
        &ff_dnxhd_encoder,
    #endif
    #if CONFIG_DNXHD_DECODER
        &ff_dnxhd_decoder,
    #endif
    #if CONFIG_DPX_ENCODER
        &ff_dpx_encoder,
    #endif
    #if CONFIG_DPX_DECODER
        &ff_dpx_decoder,
    #endif
    #if CONFIG_DSICINVIDEO_DECODER
        &ff_dsicinvideo_decoder,
    #endif
    #if CONFIG_DVAUDIO_DECODER
        &ff_dvaudio_decoder,
    #endif
    #if CONFIG_DVVIDEO_ENCODER
        &ff_dvvideo_encoder,
    #endif
    #if CONFIG_DVVIDEO_DECODER
        &ff_dvvideo_decoder,
    #endif
    #if CONFIG_DXA_DECODER
        &ff_dxa_decoder,
    #endif
    #if CONFIG_DXTORY_DECODER
        &ff_dxtory_decoder,
    #endif
    #if CONFIG_DXV_ENCODER
        &ff_dxv_encoder,
    #endif
    #if CONFIG_DXV_DECODER
        &ff_dxv_decoder,
    #endif
    #if CONFIG_EACMV_DECODER
        &ff_eacmv_decoder,
    #endif
    #if CONFIG_EAMAD_DECODER
        &ff_eamad_decoder,
    #endif
    #if CONFIG_EATGQ_DECODER
        &ff_eatgq_decoder,
    #endif
    #if CONFIG_EATGV_DECODER
        &ff_eatgv_decoder,
    #endif
    #if CONFIG_EATQI_DECODER
        &ff_eatqi_decoder,
    #endif
    #if CONFIG_EIGHTBPS_DECODER
        &ff_eightbps_decoder,
    #endif
    #if CONFIG_EIGHTSVX_EXP_DECODER
        &ff_eightsvx_exp_decoder,
    #endif
    #if CONFIG_EIGHTSVX_FIB_DECODER
        &ff_eightsvx_fib_decoder,
    #endif
    #if CONFIG_ESCAPE124_DECODER
        &ff_escape124_decoder,
    #endif
    #if CONFIG_ESCAPE130_DECODER
        &ff_escape130_decoder,
    #endif
    #if CONFIG_EXR_ENCODER
        &ff_exr_encoder,
    #endif
    #if CONFIG_EXR_DECODER
        &ff_exr_decoder,
    #endif
    #if CONFIG_FFV1_ENCODER
        &ff_ffv1_encoder,
    #endif
    #if CONFIG_FFV1_DECODER
        &ff_ffv1_decoder,
    #endif
    #if CONFIG_FFVHUFF_ENCODER
        &ff_ffvhuff_encoder,
    #endif
    #if CONFIG_FFVHUFF_DECODER
        &ff_ffvhuff_decoder,
    #endif
    #if CONFIG_FIC_DECODER
        &ff_fic_decoder,
    #endif
    #if CONFIG_FITS_ENCODER
        &ff_fits_encoder,
    #endif
    #if CONFIG_FITS_DECODER
        &ff_fits_decoder,
    #endif
    #if CONFIG_FLASHSV_ENCODER
        &ff_flashsv_encoder,
    #endif
    #if CONFIG_FLASHSV_DECODER
        &ff_flashsv_decoder,
    #endif
    #if CONFIG_FLASHSV2_ENCODER
        &ff_flashsv2_encoder,
    #endif
    #if CONFIG_FLASHSV2_DECODER
        &ff_flashsv2_decoder,
    #endif
    #if CONFIG_FLIC_DECODER
        &ff_flic_decoder,
    #endif
    #if CONFIG_FLV_ENCODER
        &ff_flv_encoder,
    #endif
    #if CONFIG_FLV_DECODER
        &ff_flv_decoder,
    #endif
    #if CONFIG_FMVC_DECODER
        &ff_fmvc_decoder,
    #endif
    #if CONFIG_FOURXM_DECODER
        &ff_fourxm_decoder,
    #endif
    #if CONFIG_FRAPS_DECODER
        &ff_fraps_decoder,
    #endif
    #if CONFIG_FRWU_DECODER
        &ff_frwu_decoder,
    #endif
    #if CONFIG_G2M_DECODER
        &ff_g2m_decoder,
    #endif
    #if CONFIG_GDV_DECODER
        &ff_gdv_decoder,
    #endif
    #if CONFIG_GEM_DECODER
        &ff_gem_decoder,
    #endif
    #if CONFIG_GIF_ENCODER
        &ff_gif_encoder,
    #endif
    #if CONFIG_GIF_DECODER
        &ff_gif_decoder,
    #endif
    #if CONFIG_H261_ENCODER
        &ff_h261_encoder,
    #endif
    #if CONFIG_H261_DECODER
        &ff_h261_decoder,
    #endif
    #if CONFIG_H263_ENCODER
        &ff_h263_encoder,
    #endif
    #if CONFIG_H263_DECODER
        &ff_h263_decoder,
    #endif
    #if CONFIG_H263I_DECODER
        &ff_h263i_decoder,
    #endif
    #if CONFIG_H263P_ENCODER
        &ff_h263p_encoder,
    #endif
    #if CONFIG_H263P_DECODER
        &ff_h263p_decoder,
    #endif
    #if CONFIG_H264_DECODER
        &ff_h264_decoder,
    #endif
    #if CONFIG_HAP_DECODER
        &ff_hap_decoder,
    #endif
    #if CONFIG_HEVC_DECODER
        &ff_hevc_decoder,
    #endif
    #if CONFIG_HNM4_VIDEO_DECODER
        &ff_hnm4_video_decoder,
    #endif
    #if CONFIG_HQ_HQA_DECODER
        &ff_hq_hqa_decoder,
    #endif
    #if CONFIG_HQX_DECODER
        &ff_hqx_decoder,
    #endif
    #if CONFIG_HUFFYUV_ENCODER
        &ff_huffyuv_encoder,
    #endif
    #if CONFIG_HUFFYUV_DECODER
        &ff_huffyuv_decoder,
    #endif
    #if CONFIG_HYMT_DECODER
        &ff_hymt_decoder,
    #endif
    #if CONFIG_IDCIN_DECODER
        &ff_idcin_decoder,
    #endif
    #if CONFIG_IFF_ILBM_DECODER
        &ff_iff_ilbm_decoder,
    #endif
    #if CONFIG_IMM4_DECODER
        &ff_imm4_decoder,
    #endif
    #if CONFIG_IMM5_DECODER
        &ff_imm5_decoder,
    #endif
    #if CONFIG_INDEO2_DECODER
        &ff_indeo2_decoder,
    #endif
    #if CONFIG_INDEO3_DECODER
        &ff_indeo3_decoder,
    #endif
    #if CONFIG_INDEO4_DECODER
        &ff_indeo4_decoder,
    #endif
    #if CONFIG_INDEO5_DECODER
        &ff_indeo5_decoder,
    #endif
    #if CONFIG_INTERPLAY_VIDEO_DECODER
        &ff_interplay_video_decoder,
    #endif
    #if CONFIG_IPU_DECODER
        &ff_ipu_decoder,
    #endif
    #if CONFIG_JPEG2000_ENCODER
        &ff_jpeg2000_encoder,
    #endif
    #if CONFIG_JPEG2000_DECODER
        &ff_jpeg2000_decoder,
    #endif
    #if CONFIG_JPEGLS_ENCODER
        &ff_jpegls_encoder,
    #endif
    #if CONFIG_JPEGLS_DECODER
        &ff_jpegls_decoder,
    #endif
    #if CONFIG_JV_DECODER
        &ff_jv_decoder,
    #endif
    #if CONFIG_KGV1_DECODER
        &ff_kgv1_decoder,
    #endif
    #if CONFIG_KMVC_DECODER
        &ff_kmvc_decoder,
    #endif
    #if CONFIG_LAGARITH_DECODER
        &ff_lagarith_decoder,
    #endif
    #if CONFIG_LEAD_DECODER
        &ff_lead_decoder,
    #endif
    #if CONFIG_LJPEG_ENCODER
        &ff_ljpeg_encoder,
    #endif
    #if CONFIG_LOCO_DECODER
        &ff_loco_decoder,
    #endif
    #if CONFIG_LSCR_DECODER
        &ff_lscr_decoder,
    #endif
    #if CONFIG_M101_DECODER
        &ff_m101_decoder,
    #endif
    #if CONFIG_MAGICYUV_ENCODER
        &ff_magicyuv_encoder,
    #endif
    #if CONFIG_MAGICYUV_DECODER
        &ff_magicyuv_decoder,
    #endif
    #if CONFIG_MDEC_DECODER
        &ff_mdec_decoder,
    #endif
    #if CONFIG_MEDIA100_DECODER
        &ff_media100_decoder,
    #endif
    #if CONFIG_MIMIC_DECODER
        &ff_mimic_decoder,
    #endif
    #if CONFIG_MJPEG_ENCODER
        &ff_mjpeg_encoder,
    #endif
    #if CONFIG_MJPEG_DECODER
        &ff_mjpeg_decoder,
    #endif
    #if CONFIG_MJPEGB_DECODER
        &ff_mjpegb_decoder,
    #endif
    #if CONFIG_MMVIDEO_DECODER
        &ff_mmvideo_decoder,
    #endif
    #if CONFIG_MOBICLIP_DECODER
        &ff_mobiclip_decoder,
    #endif
    #if CONFIG_MOTIONPIXELS_DECODER
        &ff_motionpixels_decoder,
    #endif
    #if CONFIG_MPEG1VIDEO_ENCODER
        &ff_mpeg1video_encoder,
    #endif
    #if CONFIG_MPEG1VIDEO_DECODER
        &ff_mpeg1video_decoder,
    #endif
    #if CONFIG_MPEG2VIDEO_ENCODER
        &ff_mpeg2video_encoder,
    #endif
    #if CONFIG_MPEG2VIDEO_DECODER
        &ff_mpeg2video_decoder,
    #endif
    #if CONFIG_MPEG4_ENCODER
        &ff_mpeg4_encoder,
    #endif
    #if CONFIG_MPEG4_DECODER
        &ff_mpeg4_decoder,
    #endif
    #if CONFIG_MPEGVIDEO_DECODER
        &ff_mpegvideo_decoder,
    #endif
    #if CONFIG_MSA1_DECODER
        &ff_msa1_decoder,
    #endif
    #if CONFIG_MSCC_DECODER
        &ff_mscc_decoder,
    #endif
    #if CONFIG_MSMPEG4V1_DECODER
        &ff_msmpeg4v1_decoder,
    #endif
    #if CONFIG_MSMPEG4V2_ENCODER
        &ff_msmpeg4v2_encoder,
    #endif
    #if CONFIG_MSMPEG4V2_DECODER
        &ff_msmpeg4v2_decoder,
    #endif
    #if CONFIG_MSMPEG4V3_ENCODER
        &ff_msmpeg4v3_encoder,
    #endif
    #if CONFIG_MSMPEG4V3_DECODER
        &ff_msmpeg4v3_decoder,
    #endif
    #if CONFIG_MSP2_DECODER
        &ff_msp2_decoder,
    #endif
    #if CONFIG_MSRLE_ENCODER
        &ff_msrle_encoder,
    #endif
    #if CONFIG_MSRLE_DECODER
        &ff_msrle_decoder,
    #endif
    #if CONFIG_MSS1_DECODER
        &ff_mss1_decoder,
    #endif
    #if CONFIG_MSS2_DECODER
        &ff_mss2_decoder,
    #endif
    #if CONFIG_MSVIDEO1_ENCODER
        &ff_msvideo1_encoder,
    #endif
    #if CONFIG_MSVIDEO1_DECODER
        &ff_msvideo1_decoder,
    #endif
    #if CONFIG_MSZH_DECODER
        &ff_mszh_decoder,
    #endif
    #if CONFIG_MTS2_DECODER
        &ff_mts2_decoder,
    #endif
    #if CONFIG_MV30_DECODER
        &ff_mv30_decoder,
    #endif
    #if CONFIG_MVC1_DECODER
        &ff_mvc1_decoder,
    #endif
    #if CONFIG_MVC2_DECODER
        &ff_mvc2_decoder,
    #endif
    #if CONFIG_MVDV_DECODER
        &ff_mvdv_decoder,
    #endif
    #if CONFIG_MVHA_DECODER
        &ff_mvha_decoder,
    #endif
    #if CONFIG_MWSC_DECODER
        &ff_mwsc_decoder,
    #endif
    #if CONFIG_MXPEG_DECODER
        &ff_mxpeg_decoder,
    #endif
    #if CONFIG_NOTCHLC_DECODER
        &ff_notchlc_decoder,
    #endif
    #if CONFIG_NUV_DECODER
        &ff_nuv_decoder,
    #endif
    #if CONFIG_PAF_VIDEO_DECODER
        &ff_paf_video_decoder,
    #endif
    #if CONFIG_PAM_ENCODER
        &ff_pam_encoder,
    #endif
    #if CONFIG_PAM_DECODER
        &ff_pam_decoder,
    #endif
    #if CONFIG_PBM_ENCODER
        &ff_pbm_encoder,
    #endif
    #if CONFIG_PBM_DECODER
        &ff_pbm_decoder,
    #endif
    #if CONFIG_PCX_ENCODER
        &ff_pcx_encoder,
    #endif
    #if CONFIG_PCX_DECODER
        &ff_pcx_decoder,
    #endif
    #if CONFIG_PDV_ENCODER
        &ff_pdv_encoder,
    #endif
    #if CONFIG_PDV_DECODER
        &ff_pdv_decoder,
    #endif
    #if CONFIG_PFM_ENCODER
        &ff_pfm_encoder,
    #endif
    #if CONFIG_PFM_DECODER
        &ff_pfm_decoder,
    #endif
    #if CONFIG_PGM_ENCODER
        &ff_pgm_encoder,
    #endif
    #if CONFIG_PGM_DECODER
        &ff_pgm_decoder,
    #endif
    #if CONFIG_PGMYUV_ENCODER
        &ff_pgmyuv_encoder,
    #endif
    #if CONFIG_PGMYUV_DECODER
        &ff_pgmyuv_decoder,
    #endif
    #if CONFIG_PGX_DECODER
        &ff_pgx_decoder,
    #endif
    #if CONFIG_PHM_ENCODER
        &ff_phm_encoder,
    #endif
    #if CONFIG_PHM_DECODER
        &ff_phm_decoder,
    #endif
    #if CONFIG_PHOTOCD_DECODER
        &ff_photocd_decoder,
    #endif
    #if CONFIG_PICTOR_DECODER
        &ff_pictor_decoder,
    #endif
    #if CONFIG_PIXLET_DECODER
        &ff_pixlet_decoder,
    #endif
    #if CONFIG_PNG_ENCODER
        &ff_png_encoder,
    #endif
    #if CONFIG_PNG_DECODER
        &ff_png_decoder,
    #endif
    #if CONFIG_PPM_ENCODER
        &ff_ppm_encoder,
    #endif
    #if CONFIG_PPM_DECODER
        &ff_ppm_decoder,
    #endif
    #if CONFIG_PRORES_ENCODER
        &ff_prores_encoder,
    #endif
    #if CONFIG_PRORES_DECODER
        &ff_prores_decoder,
    #endif
    #if CONFIG_PRORES_AW_ENCODER
        &ff_prores_aw_encoder,
    #endif
    #if CONFIG_PRORES_KS_ENCODER
        &ff_prores_ks_encoder,
    #endif
    #if CONFIG_PRORES_RAW_DECODER
        &ff_prores_raw_decoder,
    #endif
    #if CONFIG_PROSUMER_DECODER
        &ff_prosumer_decoder,
    #endif
    #if CONFIG_PSD_DECODER
        &ff_psd_decoder,
    #endif
    #if CONFIG_PTX_DECODER
        &ff_ptx_decoder,
    #endif
    #if CONFIG_QDRAW_DECODER
        &ff_qdraw_decoder,
    #endif
    #if CONFIG_QOI_ENCODER
        &ff_qoi_encoder,
    #endif
    #if CONFIG_QOI_DECODER
        &ff_qoi_decoder,
    #endif
    #if CONFIG_QPEG_DECODER
        &ff_qpeg_decoder,
    #endif
    #if CONFIG_QTRLE_ENCODER
        &ff_qtrle_encoder,
    #endif
    #if CONFIG_QTRLE_DECODER
        &ff_qtrle_decoder,
    #endif
    #if CONFIG_R10K_ENCODER
        &ff_r10k_encoder,
    #endif
    #if CONFIG_R10K_DECODER
        &ff_r10k_decoder,
    #endif
    #if CONFIG_R210_ENCODER
        &ff_r210_encoder,
    #endif
    #if CONFIG_R210_DECODER
        &ff_r210_decoder,
    #endif
    #if CONFIG_RASC_DECODER
        &ff_rasc_decoder,
    #endif
    #if CONFIG_RAWVIDEO_ENCODER
        &ff_rawvideo_encoder,
    #endif
    #if CONFIG_RAWVIDEO_DECODER
        &ff_rawvideo_decoder,
    #endif
    #if CONFIG_RKA_DECODER
        &ff_rka_decoder,
    #endif
    #if CONFIG_RL2_DECODER
        &ff_rl2_decoder,
    #endif
    #if CONFIG_ROQ_ENCODER
        &ff_roq_encoder,
    #endif
    #if CONFIG_ROQ_DECODER
        &ff_roq_decoder,
    #endif
    #if CONFIG_RPZA_ENCODER
        &ff_rpza_encoder,
    #endif
    #if CONFIG_RPZA_DECODER
        &ff_rpza_decoder,
    #endif
    #if CONFIG_RSCC_DECODER
        &ff_rscc_decoder,
    #endif
    #if CONFIG_RTV1_DECODER
        &ff_rtv1_decoder,
    #endif
    #if CONFIG_RV10_ENCODER
        &ff_rv10_encoder,
    #endif
    #if CONFIG_RV10_DECODER
        &ff_rv10_decoder,
    #endif
    #if CONFIG_RV20_ENCODER
        &ff_rv20_encoder,
    #endif
    #if CONFIG_RV20_DECODER
        &ff_rv20_decoder,
    #endif
    #if CONFIG_RV30_DECODER
        &ff_rv30_decoder,
    #endif
    #if CONFIG_RV40_DECODER
        &ff_rv40_decoder,
    #endif
    #if CONFIG_RV60_DECODER
        &ff_rv60_decoder,
    #endif
    #if CONFIG_S302M_ENCODER
        &ff_s302m_encoder,
    #endif
    #if CONFIG_S302M_DECODER
        &ff_s302m_decoder,
    #endif
    #if CONFIG_SANM_DECODER
        &ff_sanm_decoder,
    #endif
    #if CONFIG_SCPR_DECODER
        &ff_scpr_decoder,
    #endif
    #if CONFIG_SCREENPRESSO_DECODER
        &ff_screenpresso_decoder,
    #endif
    #if CONFIG_SGA_DECODER
        &ff_sga_decoder,
    #endif
    #if CONFIG_SGI_ENCODER
        &ff_sgi_encoder,
    #endif
    #if CONFIG_SGI_DECODER
        &ff_sgi_decoder,
    #endif
    #if CONFIG_SGIRLE_DECODER
        &ff_sgirle_decoder,
    #endif
    #if CONFIG_SHEERVIDEO_DECODER
        &ff_sheervideo_decoder,
    #endif
    #if CONFIG_SIMBIOSIS_IMX_DECODER
        &ff_simbiosis_imx_decoder,
    #endif
    #if CONFIG_SMACKER_DECODER
        &ff_smacker_decoder,
    #endif
    #if CONFIG_SMC_ENCODER
        &ff_smc_encoder,
    #endif
    #if CONFIG_SMC_DECODER
        &ff_smc_decoder,
    #endif
    #if CONFIG_SMVJPEG_DECODER
        &ff_smvjpeg_decoder,
    #endif
    #if CONFIG_SNOW_ENCODER
        &ff_snow_encoder,
    #endif
    #if CONFIG_SNOW_DECODER
        &ff_snow_decoder,
    #endif
    #if CONFIG_SP5X_DECODER
        &ff_sp5x_decoder,
    #endif
    #if CONFIG_SPEEDHQ_DECODER
        &ff_speedhq_decoder,
    #endif
    #if CONFIG_SPEEDHQ_ENCODER
        &ff_speedhq_encoder,
    #endif
    #if CONFIG_SRGC_DECODER
        &ff_srgc_decoder,
    #endif
    #if CONFIG_SUNRAST_ENCODER
        &ff_sunrast_encoder,
    #endif
    #if CONFIG_SUNRAST_DECODER
        &ff_sunrast_decoder,
    #endif
    #if CONFIG_SVQ1_ENCODER
        &ff_svq1_encoder,
    #endif
    #if CONFIG_SVQ1_DECODER
        &ff_svq1_decoder,
    #endif
    #if CONFIG_SVQ3_DECODER
        &ff_svq3_decoder,
    #endif
    #if CONFIG_TARGA_ENCODER
        &ff_targa_encoder,
    #endif
    #if CONFIG_TARGA_DECODER
        &ff_targa_decoder,
    #endif
    #if CONFIG_TARGA_Y216_DECODER
        &ff_targa_y216_decoder,
    #endif
    #if CONFIG_TDSC_DECODER
        &ff_tdsc_decoder,
    #endif
    #if CONFIG_THEORA_DECODER
        &ff_theora_decoder,
    #endif
    #if CONFIG_THP_DECODER
        &ff_thp_decoder,
    #endif
    #if CONFIG_TIERTEXSEQVIDEO_DECODER
        &ff_tiertexseqvideo_decoder,
    #endif
    #if CONFIG_TIFF_ENCODER
        &ff_tiff_encoder,
    #endif
    #if CONFIG_TIFF_DECODER
        &ff_tiff_decoder,
    #endif
    #if CONFIG_TMV_DECODER
        &ff_tmv_decoder,
    #endif
    #if CONFIG_TRUEMOTION1_DECODER
        &ff_truemotion1_decoder,
    #endif
    #if CONFIG_TRUEMOTION2_DECODER
        &ff_truemotion2_decoder,
    #endif
    #if CONFIG_TRUEMOTION2RT_DECODER
        &ff_truemotion2rt_decoder,
    #endif
    #if CONFIG_TSCC_DECODER
        &ff_tscc_decoder,
    #endif
    #if CONFIG_TSCC2_DECODER
        &ff_tscc2_decoder,
    #endif
    #if CONFIG_TXD_DECODER
        &ff_txd_decoder,
    #endif
    #if CONFIG_ULTI_DECODER
        &ff_ulti_decoder,
    #endif
    #if CONFIG_UTVIDEO_ENCODER
        &ff_utvideo_encoder,
    #endif
    #if CONFIG_UTVIDEO_DECODER
        &ff_utvideo_decoder,
    #endif
    #if CONFIG_V210_ENCODER
        &ff_v210_encoder,
    #endif
    #if CONFIG_V210_DECODER
        &ff_v210_decoder,
    #endif
    #if CONFIG_V210X_DECODER
        &ff_v210x_decoder,
    #endif
    #if CONFIG_VB_DECODER
        &ff_vb_decoder,
    #endif
    #if CONFIG_VBN_ENCODER
        &ff_vbn_encoder,
    #endif
    #if CONFIG_VBN_DECODER
        &ff_vbn_decoder,
    #endif
    #if CONFIG_VBLE_DECODER
        &ff_vble_decoder,
    #endif
    #if CONFIG_VC1_DECODER
        &ff_vc1_decoder,
    #endif
    #if CONFIG_VC1IMAGE_DECODER
        &ff_vc1image_decoder,
    #endif
    #if CONFIG_VC2_ENCODER
        &ff_vc2_encoder,
    #endif
    #if CONFIG_VCR1_DECODER
        &ff_vcr1_decoder,
    #endif
    #if CONFIG_VMDVIDEO_DECODER
        &ff_vmdvideo_decoder,
    #endif
    #if CONFIG_VMIX_DECODER
        &ff_vmix_decoder,
    #endif
    #if CONFIG_VMNC_DECODER
        &ff_vmnc_decoder,
    #endif
    #if CONFIG_VP3_DECODER
        &ff_vp3_decoder,
    #endif
    #if CONFIG_VP4_DECODER
        &ff_vp4_decoder,
    #endif
    #if CONFIG_VP5_DECODER
        &ff_vp5_decoder,
    #endif
    #if CONFIG_VP6_DECODER
        &ff_vp6_decoder,
    #endif
    #if CONFIG_VP6A_DECODER
        &ff_vp6a_decoder,
    #endif
    #if CONFIG_VP6F_DECODER
        &ff_vp6f_decoder,
    #endif
    #if CONFIG_VP7_DECODER
        &ff_vp7_decoder,
    #endif
    #if CONFIG_VP8_DECODER
        &ff_vp8_decoder,
    #endif
    #if CONFIG_VP9_DECODER
        &ff_vp9_decoder,
    #endif
    #if CONFIG_VQA_DECODER
        &ff_vqa_decoder,
    #endif
    #if CONFIG_VQC_DECODER
        &ff_vqc_decoder,
    #endif
    #if CONFIG_VVC_DECODER
        &ff_vvc_decoder,
    #endif
    #if CONFIG_WBMP_DECODER
        &ff_wbmp_decoder,
    #endif
    #if CONFIG_WBMP_ENCODER
        &ff_wbmp_encoder,
    #endif
    #if CONFIG_WEBP_ANIM_DECODER
        &ff_webp_anim_decoder,
    #endif
    #if CONFIG_WEBP_DECODER
        &ff_webp_decoder,
    #endif
    #if CONFIG_WCMV_DECODER
        &ff_wcmv_decoder,
    #endif
    #if CONFIG_WRAPPED_AVFRAME_ENCODER
        &ff_wrapped_avframe_encoder,
    #endif
    #if CONFIG_WRAPPED_AVFRAME_DECODER
        &ff_wrapped_avframe_decoder,
    #endif
    #if CONFIG_WMV1_ENCODER
        &ff_wmv1_encoder,
    #endif
    #if CONFIG_WMV1_DECODER
        &ff_wmv1_decoder,
    #endif
    #if CONFIG_WMV2_ENCODER
        &ff_wmv2_encoder,
    #endif
    #if CONFIG_WMV2_DECODER
        &ff_wmv2_decoder,
    #endif
    #if CONFIG_WMV3_DECODER
        &ff_wmv3_decoder,
    #endif
    #if CONFIG_WMV3IMAGE_DECODER
        &ff_wmv3image_decoder,
    #endif
    #if CONFIG_WNV1_DECODER
        &ff_wnv1_decoder,
    #endif
    #if CONFIG_XAN_WC3_DECODER
        &ff_xan_wc3_decoder,
    #endif
    #if CONFIG_XAN_WC4_DECODER
        &ff_xan_wc4_decoder,
    #endif
    #if CONFIG_XBM_ENCODER
        &ff_xbm_encoder,
    #endif
    #if CONFIG_XBM_DECODER
        &ff_xbm_decoder,
    #endif
    #if CONFIG_XFACE_ENCODER
        &ff_xface_encoder,
    #endif
    #if CONFIG_XFACE_DECODER
        &ff_xface_decoder,
    #endif
    #if CONFIG_XL_DECODER
        &ff_xl_decoder,
    #endif
    #if CONFIG_XPM_DECODER
        &ff_xpm_decoder,
    #endif
    #if CONFIG_XWD_ENCODER
        &ff_xwd_encoder,
    #endif
    #if CONFIG_XWD_DECODER
        &ff_xwd_decoder,
    #endif
    #if CONFIG_Y41P_ENCODER
        &ff_y41p_encoder,
    #endif
    #if CONFIG_Y41P_DECODER
        &ff_y41p_decoder,
    #endif
    #if CONFIG_YLC_DECODER
        &ff_ylc_decoder,
    #endif
    #if CONFIG_YOP_DECODER
        &ff_yop_decoder,
    #endif
    #if CONFIG_YUV4_ENCODER
        &ff_yuv4_encoder,
    #endif
    #if CONFIG_YUV4_DECODER
        &ff_yuv4_decoder,
    #endif
    #if CONFIG_ZERO12V_DECODER
        &ff_zero12v_decoder,
    #endif
    #if CONFIG_ZEROCODEC_DECODER
        &ff_zerocodec_decoder,
    #endif
    #if CONFIG_ZLIB_ENCODER
        &ff_zlib_encoder,
    #endif
    #if CONFIG_ZLIB_DECODER
        &ff_zlib_decoder,
    #endif
    #if CONFIG_ZMBV_ENCODER
        &ff_zmbv_encoder,
    #endif
    #if CONFIG_ZMBV_DECODER
        &ff_zmbv_decoder,
    #endif
    /* audio */
    #if CONFIG_AAC_ENCODER
        &ff_aac_encoder,
    #endif
    #if CONFIG_AAC_DECODER
        &ff_aac_decoder,
    #endif
    #if CONFIG_AAC_FIXED_DECODER
        &ff_aac_fixed_decoder,
    #endif
    #if CONFIG_AAC_LATM_DECODER
        &ff_aac_latm_decoder,
    #endif
    #if CONFIG_AC3_ENCODER
        &ff_ac3_encoder,
    #endif
    #if CONFIG_AC3_DECODER
        &ff_ac3_decoder,
    #endif
    #if CONFIG_AC3_FIXED_ENCODER
        &ff_ac3_fixed_encoder,
    #endif
    #if CONFIG_AC3_FIXED_DECODER
        &ff_ac3_fixed_decoder,
    #endif
    #if CONFIG_ACELP_KELVIN_DECODER
        &ff_acelp_kelvin_decoder,
    #endif
    #if CONFIG_AHX_DECODER
        &ff_ahx_decoder,
    #endif
    #if CONFIG_ALAC_ENCODER
        &ff_alac_encoder,
    #endif
    #if CONFIG_ALAC_DECODER
        &ff_alac_decoder,
    #endif
    #if CONFIG_ALS_DECODER
        &ff_als_decoder,
    #endif
    #if CONFIG_AMRNB_DECODER
        &ff_amrnb_decoder,
    #endif
    #if CONFIG_AMRWB_DECODER
        &ff_amrwb_decoder,
    #endif
    #if CONFIG_APAC_DECODER
        &ff_apac_decoder,
    #endif
    #if CONFIG_APE_DECODER
        &ff_ape_decoder,
    #endif
    #if CONFIG_APTX_ENCODER
        &ff_aptx_encoder,
    #endif
    #if CONFIG_APTX_DECODER
        &ff_aptx_decoder,
    #endif
    #if CONFIG_APTX_HD_ENCODER
        &ff_aptx_hd_encoder,
    #endif
    #if CONFIG_APTX_HD_DECODER
        &ff_aptx_hd_decoder,
    #endif
    #if CONFIG_ATRAC1_DECODER
        &ff_atrac1_decoder,
    #endif
    #if CONFIG_ATRAC3_DECODER
        &ff_atrac3_decoder,
    #endif
    #if CONFIG_ATRAC3AL_DECODER
        &ff_atrac3al_decoder,
    #endif
    #if CONFIG_ATRAC3P_DECODER
        &ff_atrac3p_decoder,
    #endif
    #if CONFIG_ATRAC3PAL_DECODER
        &ff_atrac3pal_decoder,
    #endif
    #if CONFIG_ATRAC9_DECODER
        &ff_atrac9_decoder,
    #endif
    #if CONFIG_BINKAUDIO_DCT_DECODER
        &ff_binkaudio_dct_decoder,
    #endif
    #if CONFIG_BINKAUDIO_RDFT_DECODER
        &ff_binkaudio_rdft_decoder,
    #endif
    #if CONFIG_BMV_AUDIO_DECODER
        &ff_bmv_audio_decoder,
    #endif
    #if CONFIG_BONK_DECODER
        &ff_bonk_decoder,
    #endif
    #if CONFIG_COOK_DECODER
        &ff_cook_decoder,
    #endif
    #if CONFIG_DCA_ENCODER
        &ff_dca_encoder,
    #endif
    #if CONFIG_DCA_DECODER
        &ff_dca_decoder,
    #endif
    #if CONFIG_DFPWM_ENCODER
        &ff_dfpwm_encoder,
    #endif
    #if CONFIG_DFPWM_DECODER
        &ff_dfpwm_decoder,
    #endif
    #if CONFIG_DOLBY_E_DECODER
        &ff_dolby_e_decoder,
    #endif
    #if CONFIG_DSD_LSBF_DECODER
        &ff_dsd_lsbf_decoder,
    #endif
    #if CONFIG_DSD_MSBF_DECODER
        &ff_dsd_msbf_decoder,
    #endif
    #if CONFIG_DSD_LSBF_PLANAR_DECODER
        &ff_dsd_lsbf_planar_decoder,
    #endif
    #if CONFIG_DSD_MSBF_PLANAR_DECODER
        &ff_dsd_msbf_planar_decoder,
    #endif
    #if CONFIG_DSICINAUDIO_DECODER
        &ff_dsicinaudio_decoder,
    #endif
    #if CONFIG_DSS_SP_DECODER
        &ff_dss_sp_decoder,
    #endif
    #if CONFIG_DST_DECODER
        &ff_dst_decoder,
    #endif
    #if CONFIG_EAC3_ENCODER
        &ff_eac3_encoder,
    #endif
    #if CONFIG_EAC3_DECODER
        &ff_eac3_decoder,
    #endif
    #if CONFIG_EVRC_DECODER
        &ff_evrc_decoder,
    #endif
    #if CONFIG_FASTAUDIO_DECODER
        &ff_fastaudio_decoder,
    #endif
    #if CONFIG_FFWAVESYNTH_DECODER
        &ff_ffwavesynth_decoder,
    #endif
    #if CONFIG_FLAC_ENCODER
        &ff_flac_encoder,
    #endif
    #if CONFIG_FLAC_DECODER
        &ff_flac_decoder,
    #endif
    #if CONFIG_FTR_DECODER
        &ff_ftr_decoder,
    #endif
    #if CONFIG_G723_1_ENCODER
        &ff_g723_1_encoder,
    #endif
    #if CONFIG_G723_1_DECODER
        &ff_g723_1_decoder,
    #endif
    #if CONFIG_G728_DECODER
        &ff_g728_decoder,
    #endif
    #if CONFIG_G729_DECODER
        &ff_g729_decoder,
    #endif
    #if CONFIG_GSM_DECODER
        &ff_gsm_decoder,
    #endif
    #if CONFIG_GSM_MS_DECODER
        &ff_gsm_ms_decoder,
    #endif
    #if CONFIG_HCA_DECODER
        &ff_hca_decoder,
    #endif
    #if CONFIG_HCOM_DECODER
        &ff_hcom_decoder,
    #endif
    #if CONFIG_HDR_ENCODER
        &ff_hdr_encoder,
    #endif
    #if CONFIG_HDR_DECODER
        &ff_hdr_decoder,
    #endif
    #if CONFIG_IAC_DECODER
        &ff_iac_decoder,
    #endif
    #if CONFIG_ILBC_DECODER
        &ff_ilbc_decoder,
    #endif
    #if CONFIG_IMC_DECODER
        &ff_imc_decoder,
    #endif
    #if CONFIG_INTERPLAY_ACM_DECODER
        &ff_interplay_acm_decoder,
    #endif
    #if CONFIG_MACE3_DECODER
        &ff_mace3_decoder,
    #endif
    #if CONFIG_MACE6_DECODER
        &ff_mace6_decoder,
    #endif
    #if CONFIG_METASOUND_DECODER
        &ff_metasound_decoder,
    #endif
    #if CONFIG_MISC4_DECODER
        &ff_misc4_decoder,
    #endif
    #if CONFIG_MLP_ENCODER
        &ff_mlp_encoder,
    #endif
    #if CONFIG_MLP_DECODER
        &ff_mlp_decoder,
    #endif
    #if CONFIG_MP1_DECODER
        &ff_mp1_decoder,
    #endif
    #if CONFIG_MP1FLOAT_DECODER
        &ff_mp1float_decoder,
    #endif
    #if CONFIG_MP2_ENCODER
        &ff_mp2_encoder,
    #endif
    #if CONFIG_MP2_DECODER
        &ff_mp2_decoder,
    #endif
    #if CONFIG_MP2FLOAT_DECODER
        &ff_mp2float_decoder,
    #endif
    #if CONFIG_MP2FIXED_ENCODER
        &ff_mp2fixed_encoder,
    #endif
    #if CONFIG_MP3FLOAT_DECODER
        &ff_mp3float_decoder,
    #endif
    #if CONFIG_MP3_DECODER
        &ff_mp3_decoder,
    #endif
    #if CONFIG_MP3ADUFLOAT_DECODER
        &ff_mp3adufloat_decoder,
    #endif
    #if CONFIG_MP3ADU_DECODER
        &ff_mp3adu_decoder,
    #endif
    #if CONFIG_MP3ON4FLOAT_DECODER
        &ff_mp3on4float_decoder,
    #endif
    #if CONFIG_MP3ON4_DECODER
        &ff_mp3on4_decoder,
    #endif
    #if CONFIG_MPC7_DECODER
        &ff_mpc7_decoder,
    #endif
    #if CONFIG_MPC8_DECODER
        &ff_mpc8_decoder,
    #endif
    #if CONFIG_MSNSIREN_DECODER
        &ff_msnsiren_decoder,
    #endif
    #if CONFIG_NELLYMOSER_ENCODER
        &ff_nellymoser_encoder,
    #endif
    #if CONFIG_NELLYMOSER_DECODER
        &ff_nellymoser_decoder,
    #endif
    #if CONFIG_ON2AVC_DECODER
        &ff_on2avc_decoder,
    #endif
    #if CONFIG_OPUS_ENCODER
        &ff_opus_encoder,
    #endif
    #if CONFIG_OPUS_DECODER
        &ff_opus_decoder,
    #endif
    #if CONFIG_OSQ_DECODER
        &ff_osq_decoder,
    #endif
    #if CONFIG_PAF_AUDIO_DECODER
        &ff_paf_audio_decoder,
    #endif
    #if CONFIG_QCELP_DECODER
        &ff_qcelp_decoder,
    #endif
    #if CONFIG_QDM2_DECODER
        &ff_qdm2_decoder,
    #endif
    #if CONFIG_QDMC_DECODER
        &ff_qdmc_decoder,
    #endif
    #if CONFIG_QOA_DECODER
        &ff_qoa_decoder,
    #endif
    #if CONFIG_RA_144_ENCODER
        &ff_ra_144_encoder,
    #endif
    #if CONFIG_RA_144_DECODER
        &ff_ra_144_decoder,
    #endif
    #if CONFIG_RA_288_DECODER
        &ff_ra_288_decoder,
    #endif
    #if CONFIG_RALF_DECODER
        &ff_ralf_decoder,
    #endif
    #if CONFIG_SBC_ENCODER
        &ff_sbc_encoder,
    #endif
    #if CONFIG_SBC_DECODER
        &ff_sbc_decoder,
    #endif
    #if CONFIG_SHORTEN_DECODER
        &ff_shorten_decoder,
    #endif
    #if CONFIG_SIPR_DECODER
        &ff_sipr_decoder,
    #endif
    #if CONFIG_SIREN_DECODER
        &ff_siren_decoder,
    #endif
    #if CONFIG_SMACKAUD_DECODER
        &ff_smackaud_decoder,
    #endif
    #if CONFIG_SPEEX_DECODER
        &ff_speex_decoder,
    #endif
    #if CONFIG_TAK_DECODER
        &ff_tak_decoder,
    #endif
    #if CONFIG_TRUEHD_ENCODER
        &ff_truehd_encoder,
    #endif
    #if CONFIG_TRUEHD_DECODER
        &ff_truehd_decoder,
    #endif
    #if CONFIG_TRUESPEECH_DECODER
        &ff_truespeech_decoder,
    #endif
    #if CONFIG_TTA_ENCODER
        &ff_tta_encoder,
    #endif
    #if CONFIG_TTA_DECODER
        &ff_tta_decoder,
    #endif
    #if CONFIG_TWINVQ_DECODER
        &ff_twinvq_decoder,
    #endif
    #if CONFIG_VMDAUDIO_DECODER
        &ff_vmdaudio_decoder,
    #endif
    #if CONFIG_VORBIS_ENCODER
        &ff_vorbis_encoder,
    #endif
    #if CONFIG_VORBIS_DECODER
        &ff_vorbis_decoder,
    #endif
    #if CONFIG_WAVARC_DECODER
        &ff_wavarc_decoder,
    #endif
    #if CONFIG_WAVPACK_ENCODER
        &ff_wavpack_encoder,
    #endif
    #if CONFIG_WAVPACK_DECODER
        &ff_wavpack_decoder,
    #endif
    #if CONFIG_WMALOSSLESS_DECODER
        &ff_wmalossless_decoder,
    #endif
    #if CONFIG_WMAPRO_DECODER
        &ff_wmapro_decoder,
    #endif
    #if CONFIG_WMAV1_ENCODER
        &ff_wmav1_encoder,
    #endif
    #if CONFIG_WMAV1_DECODER
        &ff_wmav1_decoder,
    #endif
    #if CONFIG_WMAV2_ENCODER
        &ff_wmav2_encoder,
    #endif
    #if CONFIG_WMAV2_DECODER
        &ff_wmav2_decoder,
    #endif
    #if CONFIG_WMAVOICE_DECODER
        &ff_wmavoice_decoder,
    #endif
    #if CONFIG_WS_SND1_DECODER
        &ff_ws_snd1_decoder,
    #endif
    #if CONFIG_XMA1_DECODER
        &ff_xma1_decoder,
    #endif
    #if CONFIG_XMA2_DECODER
        &ff_xma2_decoder,
    #endif
    /* PCM */
    #if CONFIG_PCM_ALAW_ENCODER
        &ff_pcm_alaw_encoder,
    #endif
    #if CONFIG_PCM_ALAW_DECODER
        &ff_pcm_alaw_decoder,
    #endif
    #if CONFIG_PCM_BLURAY_ENCODER
        &ff_pcm_bluray_encoder,
    #endif
    #if CONFIG_PCM_BLURAY_DECODER
        &ff_pcm_bluray_decoder,
    #endif
    #if CONFIG_PCM_DVD_ENCODER
        &ff_pcm_dvd_encoder,
    #endif
    #if CONFIG_PCM_DVD_DECODER
        &ff_pcm_dvd_decoder,
    #endif
    #if CONFIG_PCM_F16LE_DECODER
        &ff_pcm_f16le_decoder,
    #endif
    #if CONFIG_PCM_F24LE_DECODER
        &ff_pcm_f24le_decoder,
    #endif
    #if CONFIG_PCM_F32BE_ENCODER
        &ff_pcm_f32be_encoder,
    #endif
    #if CONFIG_PCM_F32BE_DECODER
        &ff_pcm_f32be_decoder,
    #endif
    #if CONFIG_PCM_F32LE_ENCODER
        &ff_pcm_f32le_encoder,
    #endif
    #if CONFIG_PCM_F32LE_DECODER
        &ff_pcm_f32le_decoder,
    #endif
    #if CONFIG_PCM_F64BE_ENCODER
        &ff_pcm_f64be_encoder,
    #endif
    #if CONFIG_PCM_F64BE_DECODER
        &ff_pcm_f64be_decoder,
    #endif
    #if CONFIG_PCM_F64LE_ENCODER
        &ff_pcm_f64le_encoder,
    #endif
    #if CONFIG_PCM_F64LE_DECODER
        &ff_pcm_f64le_decoder,
    #endif
    #if CONFIG_PCM_LXF_DECODER
        &ff_pcm_lxf_decoder,
    #endif
    #if CONFIG_PCM_MULAW_ENCODER
        &ff_pcm_mulaw_encoder,
    #endif
    #if CONFIG_PCM_MULAW_DECODER
        &ff_pcm_mulaw_decoder,
    #endif
    #if CONFIG_PCM_S8_ENCODER
        &ff_pcm_s8_encoder,
    #endif
    #if CONFIG_PCM_S8_DECODER
        &ff_pcm_s8_decoder,
    #endif
    #if CONFIG_PCM_S8_PLANAR_ENCODER
        &ff_pcm_s8_planar_encoder,
    #endif
    #if CONFIG_PCM_S8_PLANAR_DECODER
        &ff_pcm_s8_planar_decoder,
    #endif
    #if CONFIG_PCM_S16BE_ENCODER
        &ff_pcm_s16be_encoder,
    #endif
    #if CONFIG_PCM_S16BE_DECODER
        &ff_pcm_s16be_decoder,
    #endif
    #if CONFIG_PCM_S16BE_PLANAR_ENCODER
        &ff_pcm_s16be_planar_encoder,
    #endif
    #if CONFIG_PCM_S16BE_PLANAR_DECODER
        &ff_pcm_s16be_planar_decoder,
    #endif
    #if CONFIG_PCM_S16LE_ENCODER
        &ff_pcm_s16le_encoder,
    #endif
    #if CONFIG_PCM_S16LE_DECODER
        &ff_pcm_s16le_decoder,
    #endif
    #if CONFIG_PCM_S16LE_PLANAR_ENCODER
        &ff_pcm_s16le_planar_encoder,
    #endif
    #if CONFIG_PCM_S16LE_PLANAR_DECODER
        &ff_pcm_s16le_planar_decoder,
    #endif
    #if CONFIG_PCM_S24BE_ENCODER
        &ff_pcm_s24be_encoder,
    #endif
    #if CONFIG_PCM_S24BE_DECODER
        &ff_pcm_s24be_decoder,
    #endif
    #if CONFIG_PCM_S24DAUD_ENCODER
        &ff_pcm_s24daud_encoder,
    #endif
    #if CONFIG_PCM_S24DAUD_DECODER
        &ff_pcm_s24daud_decoder,
    #endif
    #if CONFIG_PCM_S24LE_ENCODER
        &ff_pcm_s24le_encoder,
    #endif
    #if CONFIG_PCM_S24LE_DECODER
        &ff_pcm_s24le_decoder,
    #endif
    #if CONFIG_PCM_S24LE_PLANAR_ENCODER
        &ff_pcm_s24le_planar_encoder,
    #endif
    #if CONFIG_PCM_S24LE_PLANAR_DECODER
        &ff_pcm_s24le_planar_decoder,
    #endif
    #if CONFIG_PCM_S32BE_ENCODER
        &ff_pcm_s32be_encoder,
    #endif
    #if CONFIG_PCM_S32BE_DECODER
        &ff_pcm_s32be_decoder,
    #endif
    #if CONFIG_PCM_S32LE_ENCODER
        &ff_pcm_s32le_encoder,
    #endif
    #if CONFIG_PCM_S32LE_DECODER
        &ff_pcm_s32le_decoder,
    #endif
    #if CONFIG_PCM_S32LE_PLANAR_ENCODER
        &ff_pcm_s32le_planar_encoder,
    #endif
    #if CONFIG_PCM_S32LE_PLANAR_DECODER
        &ff_pcm_s32le_planar_decoder,
    #endif
    #if CONFIG_PCM_S64BE_ENCODER
        &ff_pcm_s64be_encoder,
    #endif
    #if CONFIG_PCM_S64BE_DECODER
        &ff_pcm_s64be_decoder,
    #endif
    #if CONFIG_PCM_S64LE_ENCODER
        &ff_pcm_s64le_encoder,
    #endif
    #if CONFIG_PCM_S64LE_DECODER
        &ff_pcm_s64le_decoder,
    #endif
    #if CONFIG_PCM_SGA_DECODER
        &ff_pcm_sga_decoder,
    #endif
    #if CONFIG_PCM_U8_ENCODER
        &ff_pcm_u8_encoder,
    #endif
    #if CONFIG_PCM_U8_DECODER
        &ff_pcm_u8_decoder,
    #endif
    #if CONFIG_PCM_U16BE_ENCODER
        &ff_pcm_u16be_encoder,
    #endif
    #if CONFIG_PCM_U16BE_DECODER
        &ff_pcm_u16be_decoder,
    #endif
    #if CONFIG_PCM_U16LE_ENCODER
        &ff_pcm_u16le_encoder,
    #endif
    #if CONFIG_PCM_U16LE_DECODER
        &ff_pcm_u16le_decoder,
    #endif
    #if CONFIG_PCM_U24BE_ENCODER
        &ff_pcm_u24be_encoder,
    #endif
    #if CONFIG_PCM_U24BE_DECODER
        &ff_pcm_u24be_decoder,
    #endif
    #if CONFIG_PCM_U24LE_ENCODER
        &ff_pcm_u24le_encoder,
    #endif
    #if CONFIG_PCM_U24LE_DECODER
        &ff_pcm_u24le_decoder,
    #endif
    #if CONFIG_PCM_U32BE_ENCODER
        &ff_pcm_u32be_encoder,
    #endif
    #if CONFIG_PCM_U32BE_DECODER
        &ff_pcm_u32be_decoder,
    #endif
    #if CONFIG_PCM_U32LE_ENCODER
        &ff_pcm_u32le_encoder,
    #endif
    #if CONFIG_PCM_U32LE_DECODER
        &ff_pcm_u32le_decoder,
    #endif
    #if CONFIG_PCM_VIDC_ENCODER
        &ff_pcm_vidc_encoder,
    #endif
    #if CONFIG_PCM_VIDC_DECODER
        &ff_pcm_vidc_decoder,
    #endif
    /* DPCM */
    #if CONFIG_CBD2_DPCM_DECODER
        &ff_cbd2_dpcm_decoder,
    #endif
    #if CONFIG_DERF_DPCM_DECODER
        &ff_derf_dpcm_decoder,
    #endif
    #if CONFIG_GREMLIN_DPCM_DECODER
        &ff_gremlin_dpcm_decoder,
    #endif
    #if CONFIG_INTERPLAY_DPCM_DECODER
        &ff_interplay_dpcm_decoder,
    #endif
    #if CONFIG_ROQ_DPCM_ENCODER
        &ff_roq_dpcm_encoder,
    #endif
    #if CONFIG_ROQ_DPCM_DECODER
        &ff_roq_dpcm_decoder,
    #endif
    #if CONFIG_SDX2_DPCM_DECODER
        &ff_sdx2_dpcm_decoder,
    #endif
    #if CONFIG_SOL_DPCM_DECODER
        &ff_sol_dpcm_decoder,
    #endif
    #if CONFIG_XAN_DPCM_DECODER
        &ff_xan_dpcm_decoder,
    #endif
    #if CONFIG_WADY_DPCM_DECODER
        &ff_wady_dpcm_decoder,
    #endif
    /* ADPCM */
    #if CONFIG_ADPCM_4XM_DECODER
        &ff_adpcm_4xm_decoder,
    #endif
    #if CONFIG_ADPCM_ADX_ENCODER
        &ff_adpcm_adx_encoder,
    #endif
    #if CONFIG_ADPCM_ADX_DECODER
        &ff_adpcm_adx_decoder,
    #endif
    #if CONFIG_ADPCM_AFC_DECODER
        &ff_adpcm_afc_decoder,
    #endif
    #if CONFIG_ADPCM_AGM_DECODER
        &ff_adpcm_agm_decoder,
    #endif
    #if CONFIG_ADPCM_AICA_DECODER
        &ff_adpcm_aica_decoder,
    #endif
    #if CONFIG_ADPCM_ARGO_DECODER
        &ff_adpcm_argo_decoder,
    #endif
    #if CONFIG_ADPCM_ARGO_ENCODER
        &ff_adpcm_argo_encoder,
    #endif
    #if CONFIG_ADPCM_CIRCUS_DECODER
        &ff_adpcm_circus_decoder,
    #endif
    #if CONFIG_ADPCM_CT_DECODER
        &ff_adpcm_ct_decoder,
    #endif
    #if CONFIG_ADPCM_DTK_DECODER
        &ff_adpcm_dtk_decoder,
    #endif
    #if CONFIG_ADPCM_EA_DECODER
        &ff_adpcm_ea_decoder,
    #endif
    #if CONFIG_ADPCM_EA_MAXIS_XA_DECODER
        &ff_adpcm_ea_maxis_xa_decoder,
    #endif
    #if CONFIG_ADPCM_EA_R1_DECODER
        &ff_adpcm_ea_r1_decoder,
    #endif
    #if CONFIG_ADPCM_EA_R2_DECODER
        &ff_adpcm_ea_r2_decoder,
    #endif
    #if CONFIG_ADPCM_EA_R3_DECODER
        &ff_adpcm_ea_r3_decoder,
    #endif
    #if CONFIG_ADPCM_EA_XAS_DECODER
        &ff_adpcm_ea_xas_decoder,
    #endif
    #if CONFIG_ADPCM_G722_ENCODER
        &ff_adpcm_g722_encoder,
    #endif
    #if CONFIG_ADPCM_G722_DECODER
        &ff_adpcm_g722_decoder,
    #endif
    #if CONFIG_ADPCM_G726_ENCODER
        &ff_adpcm_g726_encoder,
    #endif
    #if CONFIG_ADPCM_G726_DECODER
        &ff_adpcm_g726_decoder,
    #endif
    #if CONFIG_ADPCM_G726LE_ENCODER
        &ff_adpcm_g726le_encoder,
    #endif
    #if CONFIG_ADPCM_G726LE_DECODER
        &ff_adpcm_g726le_decoder,
    #endif
    #if CONFIG_ADPCM_IMA_ACORN_DECODER
        &ff_adpcm_ima_acorn_decoder,
    #endif
    #if CONFIG_ADPCM_IMA_AMV_DECODER
        &ff_adpcm_ima_amv_decoder,
    #endif
    #if CONFIG_ADPCM_IMA_AMV_ENCODER
        &ff_adpcm_ima_amv_encoder,
    #endif
    #if CONFIG_ADPCM_IMA_ALP_DECODER
        &ff_adpcm_ima_alp_decoder,
    #endif
    #if CONFIG_ADPCM_IMA_ALP_ENCODER
        &ff_adpcm_ima_alp_encoder,
    #endif
    #if CONFIG_ADPCM_IMA_APC_DECODER
        &ff_adpcm_ima_apc_decoder,
    #endif
    #if CONFIG_ADPCM_IMA_APM_DECODER
        &ff_adpcm_ima_apm_decoder,
    #endif
    #if CONFIG_ADPCM_IMA_APM_ENCODER
        &ff_adpcm_ima_apm_encoder,
    #endif
    #if CONFIG_ADPCM_IMA_CUNNING_DECODER
        &ff_adpcm_ima_cunning_decoder,
    #endif
    #if CONFIG_ADPCM_IMA_DAT4_DECODER
        &ff_adpcm_ima_dat4_decoder,
    #endif
    #if CONFIG_ADPCM_IMA_DK3_DECODER
        &ff_adpcm_ima_dk3_decoder,
    #endif
    #if CONFIG_ADPCM_IMA_DK4_DECODER
        &ff_adpcm_ima_dk4_decoder,
    #endif
    #if CONFIG_ADPCM_IMA_EA_EACS_DECODER
        &ff_adpcm_ima_ea_eacs_decoder,
    #endif
    #if CONFIG_ADPCM_IMA_EA_SEAD_DECODER
        &ff_adpcm_ima_ea_sead_decoder,
    #endif
    #if CONFIG_ADPCM_IMA_ESCAPE_DECODER
        &ff_adpcm_ima_escape_decoder,
    #endif
    #if CONFIG_ADPCM_IMA_HVQM2_DECODER
        &ff_adpcm_ima_hvqm2_decoder,
    #endif
    #if CONFIG_ADPCM_IMA_HVQM4_DECODER
        &ff_adpcm_ima_hvqm4_decoder,
    #endif
    #if CONFIG_ADPCM_IMA_ISS_DECODER
        &ff_adpcm_ima_iss_decoder,
    #endif
    #if CONFIG_ADPCM_IMA_MAGIX_DECODER
        &ff_adpcm_ima_magix_decoder,
    #endif
    #if CONFIG_ADPCM_IMA_MOFLEX_DECODER
        &ff_adpcm_ima_moflex_decoder,
    #endif
    #if CONFIG_ADPCM_IMA_MTF_DECODER
        &ff_adpcm_ima_mtf_decoder,
    #endif
    #if CONFIG_ADPCM_IMA_OKI_DECODER
        &ff_adpcm_ima_oki_decoder,
    #endif
    #if CONFIG_ADPCM_IMA_PDA_DECODER
        &ff_adpcm_ima_pda_decoder,
    #endif
    #if CONFIG_ADPCM_IMA_QT_ENCODER
        &ff_adpcm_ima_qt_encoder,
    #endif
    #if CONFIG_ADPCM_IMA_QT_DECODER
        &ff_adpcm_ima_qt_decoder,
    #endif
    #if CONFIG_ADPCM_IMA_RAD_DECODER
        &ff_adpcm_ima_rad_decoder,
    #endif
    #if CONFIG_ADPCM_IMA_SSI_DECODER
        &ff_adpcm_ima_ssi_decoder,
    #endif
    #if CONFIG_ADPCM_IMA_SSI_ENCODER
        &ff_adpcm_ima_ssi_encoder,
    #endif
    #if CONFIG_ADPCM_IMA_SMJPEG_DECODER
        &ff_adpcm_ima_smjpeg_decoder,
    #endif
    #if CONFIG_ADPCM_IMA_WAV_ENCODER
        &ff_adpcm_ima_wav_encoder,
    #endif
    #if CONFIG_ADPCM_IMA_WAV_DECODER
        &ff_adpcm_ima_wav_decoder,
    #endif
    #if CONFIG_ADPCM_IMA_WS_ENCODER
        &ff_adpcm_ima_ws_encoder,
    #endif
    #if CONFIG_ADPCM_IMA_WS_DECODER
        &ff_adpcm_ima_ws_decoder,
    #endif
    #if CONFIG_ADPCM_IMA_XBOX_DECODER
        &ff_adpcm_ima_xbox_decoder,
    #endif
    #if CONFIG_ADPCM_MS_ENCODER
        &ff_adpcm_ms_encoder,
    #endif
    #if CONFIG_ADPCM_MS_DECODER
        &ff_adpcm_ms_decoder,
    #endif
    #if CONFIG_ADPCM_MTAF_DECODER
        &ff_adpcm_mtaf_decoder,
    #endif
    #if CONFIG_ADPCM_N64_DECODER
        &ff_adpcm_n64_decoder,
    #endif
    #if CONFIG_ADPCM_PSX_DECODER
        &ff_adpcm_psx_decoder,
    #endif
    #if CONFIG_ADPCM_PSXC_DECODER
        &ff_adpcm_psxc_decoder,
    #endif
    #if CONFIG_ADPCM_SANYO_DECODER
        &ff_adpcm_sanyo_decoder,
    #endif
    #if CONFIG_ADPCM_SBPRO_2_DECODER
        &ff_adpcm_sbpro_2_decoder,
    #endif
    #if CONFIG_ADPCM_SBPRO_3_DECODER
        &ff_adpcm_sbpro_3_decoder,
    #endif
    #if CONFIG_ADPCM_SBPRO_4_DECODER
        &ff_adpcm_sbpro_4_decoder,
    #endif
    #if CONFIG_ADPCM_SWF_ENCODER
        &ff_adpcm_swf_encoder,
    #endif
    #if CONFIG_ADPCM_SWF_DECODER
        &ff_adpcm_swf_decoder,
    #endif
    #if CONFIG_ADPCM_THP_DECODER
        &ff_adpcm_thp_decoder,
    #endif
    #if CONFIG_ADPCM_THP_LE_DECODER
        &ff_adpcm_thp_le_decoder,
    #endif
    #if CONFIG_ADPCM_VIMA_DECODER
        &ff_adpcm_vima_decoder,
    #endif
    #if CONFIG_ADPCM_XA_DECODER
        &ff_adpcm_xa_decoder,
    #endif
    #if CONFIG_ADPCM_XMD_DECODER
        &ff_adpcm_xmd_decoder,
    #endif
    #if CONFIG_ADPCM_YAMAHA_ENCODER
        &ff_adpcm_yamaha_encoder,
    #endif
    #if CONFIG_ADPCM_YAMAHA_DECODER
        &ff_adpcm_yamaha_decoder,
    #endif
    #if CONFIG_ADPCM_ZORK_DECODER
        &ff_adpcm_zork_decoder,
    #endif
    /* subtitles */
    #if CONFIG_SSA_ENCODER
        &ff_ssa_encoder,
    #endif
    #if CONFIG_SSA_DECODER
        &ff_ssa_decoder,
    #endif
    #if CONFIG_ASS_ENCODER
        &ff_ass_encoder,
    #endif
    #if CONFIG_ASS_DECODER
        &ff_ass_decoder,
    #endif
    #if CONFIG_CCAPTION_DECODER
        &ff_ccaption_decoder,
    #endif
    #if CONFIG_DVBSUB_ENCODER
        &ff_dvbsub_encoder,
    #endif
    #if CONFIG_DVBSUB_DECODER
        &ff_dvbsub_decoder,
    #endif
    #if CONFIG_DVDSUB_ENCODER
        &ff_dvdsub_encoder,
    #endif
    #if CONFIG_DVDSUB_DECODER
        &ff_dvdsub_decoder,
    #endif
    #if CONFIG_JACOSUB_DECODER
        &ff_jacosub_decoder,
    #endif
    #if CONFIG_MICRODVD_DECODER
        &ff_microdvd_decoder,
    #endif
    #if CONFIG_MOVTEXT_ENCODER
        &ff_movtext_encoder,
    #endif
    #if CONFIG_MOVTEXT_DECODER
        &ff_movtext_decoder,
    #endif
    #if CONFIG_MPL2_DECODER
        &ff_mpl2_decoder,
    #endif
    #if CONFIG_PGSSUB_DECODER
        &ff_pgssub_decoder,
    #endif
    #if CONFIG_PJS_DECODER
        &ff_pjs_decoder,
    #endif
    #if CONFIG_REALTEXT_DECODER
        &ff_realtext_decoder,
    #endif
    #if CONFIG_SAMI_DECODER
        &ff_sami_decoder,
    #endif
    #if CONFIG_SRT_ENCODER
        &ff_srt_encoder,
    #endif
    #if CONFIG_SRT_DECODER
        &ff_srt_decoder,
    #endif
    #if CONFIG_STL_DECODER
        &ff_stl_decoder,
    #endif
    #if CONFIG_SUBRIP_ENCODER
        &ff_subrip_encoder,
    #endif
    #if CONFIG_SUBRIP_DECODER
        &ff_subrip_decoder,
    #endif
    #if CONFIG_SUBVIEWER_DECODER
        &ff_subviewer_decoder,
    #endif
    #if CONFIG_SUBVIEWER1_DECODER
        &ff_subviewer1_decoder,
    #endif
    #if CONFIG_TEXT_ENCODER
        &ff_text_encoder,
    #endif
    #if CONFIG_TEXT_DECODER
        &ff_text_decoder,
    #endif
    #if CONFIG_TTML_ENCODER
        &ff_ttml_encoder,
    #endif
    #if CONFIG_VPLAYER_DECODER
        &ff_vplayer_decoder,
    #endif
    #if CONFIG_WEBVTT_ENCODER
        &ff_webvtt_encoder,
    #endif
    #if CONFIG_WEBVTT_DECODER
        &ff_webvtt_decoder,
    #endif
    #if CONFIG_XSUB_ENCODER
        &ff_xsub_encoder,
    #endif
    #if CONFIG_XSUB_DECODER
        &ff_xsub_decoder,
    #endif
    /* null */
    #if CONFIG_VNULL_DECODER
        &ff_vnull_decoder,
    #endif
    #if CONFIG_VNULL_ENCODER
        &ff_vnull_encoder,
    #endif
    #if CONFIG_ANULL_DECODER
        &ff_anull_decoder,
    #endif
    #if CONFIG_ANULL_ENCODER
        &ff_anull_encoder,
    #endif
    NULL
};
]=])

file(WRITE "${CMAKE_BINARY_DIR}/libavcodec/parser_list.c" [=[
#include "config_components.h"
/* Auto-generated by CMakeLists.txt */
static const FFCodecParser * const parser_list[] = {
    #if CONFIG_AAC_PARSER
        &ff_aac_parser,
    #endif
    #if CONFIG_AAC_LATM_PARSER
        &ff_aac_latm_parser,
    #endif
    #if CONFIG_AC3_PARSER
        &ff_ac3_parser,
    #endif
    #if CONFIG_ADX_PARSER
        &ff_adx_parser,
    #endif
    #if CONFIG_AHX_PARSER
        &ff_ahx_parser,
    #endif
    #if CONFIG_AMR_PARSER
        &ff_amr_parser,
    #endif
    #if CONFIG_APV_PARSER
        &ff_apv_parser,
    #endif
    #if CONFIG_AV1_PARSER
        &ff_av1_parser,
    #endif
    #if CONFIG_AVS2_PARSER
        &ff_avs2_parser,
    #endif
    #if CONFIG_AVS3_PARSER
        &ff_avs3_parser,
    #endif
    #if CONFIG_BMP_PARSER
        &ff_bmp_parser,
    #endif
    #if CONFIG_CAVSVIDEO_PARSER
        &ff_cavsvideo_parser,
    #endif
    #if CONFIG_COOK_PARSER
        &ff_cook_parser,
    #endif
    #if CONFIG_CRI_PARSER
        &ff_cri_parser,
    #endif
    #if CONFIG_DCA_PARSER
        &ff_dca_parser,
    #endif
    #if CONFIG_DIRAC_PARSER
        &ff_dirac_parser,
    #endif
    #if CONFIG_DNXHD_PARSER
        &ff_dnxhd_parser,
    #endif
    #if CONFIG_DNXUC_PARSER
        &ff_dnxuc_parser,
    #endif
    #if CONFIG_DOLBY_E_PARSER
        &ff_dolby_e_parser,
    #endif
    #if CONFIG_DPX_PARSER
        &ff_dpx_parser,
    #endif
    #if CONFIG_DVAUDIO_PARSER
        &ff_dvaudio_parser,
    #endif
    #if CONFIG_DVBSUB_PARSER
        &ff_dvbsub_parser,
    #endif
    #if CONFIG_DVDSUB_PARSER
        &ff_dvdsub_parser,
    #endif
    #if CONFIG_DVD_NAV_PARSER
        &ff_dvd_nav_parser,
    #endif
    #if CONFIG_EVC_PARSER
        &ff_evc_parser,
    #endif
    #if CONFIG_FFV1_PARSER
        &ff_ffv1_parser,
    #endif
    #if CONFIG_FLAC_PARSER
        &ff_flac_parser,
    #endif
    #if CONFIG_FTR_PARSER
        &ff_ftr_parser,
    #endif
    #if CONFIG_G723_1_PARSER
        &ff_g723_1_parser,
    #endif
    #if CONFIG_G729_PARSER
        &ff_g729_parser,
    #endif
    #if CONFIG_GIF_PARSER
        &ff_gif_parser,
    #endif
    #if CONFIG_GSM_PARSER
        &ff_gsm_parser,
    #endif
    #if CONFIG_H261_PARSER
        &ff_h261_parser,
    #endif
    #if CONFIG_H263_PARSER
        &ff_h263_parser,
    #endif
    #if CONFIG_H264_PARSER
        &ff_h264_parser,
    #endif
    #if CONFIG_HDR_PARSER
        &ff_hdr_parser,
    #endif
    #if CONFIG_HEVC_PARSER
        &ff_hevc_parser,
    #endif
    #if CONFIG_IPU_PARSER
        &ff_ipu_parser,
    #endif
    #if CONFIG_JPEG2000_PARSER
        &ff_jpeg2000_parser,
    #endif
    #if CONFIG_JPEGXL_PARSER
        &ff_jpegxl_parser,
    #endif
    #if CONFIG_JPEGXS_PARSER
        &ff_jpegxs_parser,
    #endif
    #if CONFIG_LCEVC_PARSER
        &ff_lcevc_parser,
    #endif
    #if CONFIG_MISC4_PARSER
        &ff_misc4_parser,
    #endif
    #if CONFIG_MJPEG_PARSER
        &ff_mjpeg_parser,
    #endif
    #if CONFIG_MLP_PARSER
        &ff_mlp_parser,
    #endif
    #if CONFIG_MPEG4VIDEO_PARSER
        &ff_mpeg4video_parser,
    #endif
    #if CONFIG_MPEGAUDIO_PARSER
        &ff_mpegaudio_parser,
    #endif
    #if CONFIG_MPEGVIDEO_PARSER
        &ff_mpegvideo_parser,
    #endif
    #if CONFIG_OPUS_PARSER
        &ff_opus_parser,
    #endif
    #if CONFIG_PNG_PARSER
        &ff_png_parser,
    #endif
    #if CONFIG_PNM_PARSER
        &ff_pnm_parser,
    #endif
    #if CONFIG_PRORES_PARSER
        &ff_prores_parser,
    #endif
    #if CONFIG_PRORES_RAW_PARSER
        &ff_prores_raw_parser,
    #endif
    #if CONFIG_QOI_PARSER
        &ff_qoi_parser,
    #endif
    #if CONFIG_RV34_PARSER
        &ff_rv34_parser,
    #endif
    #if CONFIG_SBC_PARSER
        &ff_sbc_parser,
    #endif
    #if CONFIG_SIPR_PARSER
        &ff_sipr_parser,
    #endif
    #if CONFIG_TAK_PARSER
        &ff_tak_parser,
    #endif
    #if CONFIG_VC1_PARSER
        &ff_vc1_parser,
    #endif
    #if CONFIG_VORBIS_PARSER
        &ff_vorbis_parser,
    #endif
    #if CONFIG_VP3_PARSER
        &ff_vp3_parser,
    #endif
    #if CONFIG_VP8_PARSER
        &ff_vp8_parser,
    #endif
    #if CONFIG_VP9_PARSER
        &ff_vp9_parser,
    #endif
    #if CONFIG_VVC_PARSER
        &ff_vvc_parser,
    #endif
    #if CONFIG_WEBP_PARSER
        &ff_webp_parser,
    #endif
    #if CONFIG_XBM_PARSER
        &ff_xbm_parser,
    #endif
    #if CONFIG_XMA_PARSER
        &ff_xma_parser,
    #endif
    #if CONFIG_XWD_PARSER
        &ff_xwd_parser,
    #endif
    NULL
};
]=])

file(WRITE "${CMAKE_BINARY_DIR}/libavcodec/bsf_list.c" [=[
#include "config_components.h"
/* Auto-generated by CMakeLists.txt */
static const FFBitStreamFilter * const bitstream_filters[] = {
    #if CONFIG_AAC_ADTSTOASC_BSF
        &ff_aac_adtstoasc_bsf,
    #endif
    #if CONFIG_AHX_TO_MP2_BSF
        &ff_ahx_to_mp2_bsf,
    #endif
    #if CONFIG_APV_METADATA_BSF
        &ff_apv_metadata_bsf,
    #endif
    #if CONFIG_AV1_FRAME_MERGE_BSF
        &ff_av1_frame_merge_bsf,
    #endif
    #if CONFIG_AV1_FRAME_SPLIT_BSF
        &ff_av1_frame_split_bsf,
    #endif
    #if CONFIG_AV1_METADATA_BSF
        &ff_av1_metadata_bsf,
    #endif
    #if CONFIG_CHOMP_BSF
        &ff_chomp_bsf,
    #endif
    #if CONFIG_DUMP_EXTRADATA_BSF
        &ff_dump_extradata_bsf,
    #endif
    #if CONFIG_DCA_CORE_BSF
        &ff_dca_core_bsf,
    #endif
    #if CONFIG_DOVI_RPU_BSF
        &ff_dovi_rpu_bsf,
    #endif
    #if CONFIG_DOVI_SPLIT_BSF
        &ff_dovi_split_bsf,
    #endif
    #if CONFIG_DTS2PTS_BSF
        &ff_dts2pts_bsf,
    #endif
    #if CONFIG_DV_ERROR_MARKER_BSF
        &ff_dv_error_marker_bsf,
    #endif
    #if CONFIG_EAC3_CORE_BSF
        &ff_eac3_core_bsf,
    #endif
    #if CONFIG_EIA608_TO_SMPTE436M_BSF
        &ff_eia608_to_smpte436m_bsf,
    #endif
    #if CONFIG_EVC_FRAME_MERGE_BSF
        &ff_evc_frame_merge_bsf,
    #endif
    #if CONFIG_EXTRACT_EXTRADATA_BSF
        &ff_extract_extradata_bsf,
    #endif
    #if CONFIG_FILTER_UNITS_BSF
        &ff_filter_units_bsf,
    #endif
    #if CONFIG_H264_METADATA_BSF
        &ff_h264_metadata_bsf,
    #endif
    #if CONFIG_H264_MP4TOANNEXB_BSF
        &ff_h264_mp4toannexb_bsf,
    #endif
    #if CONFIG_H264_REDUNDANT_PPS_BSF
        &ff_h264_redundant_pps_bsf,
    #endif
    #if CONFIG_HAPQA_EXTRACT_BSF
        &ff_hapqa_extract_bsf,
    #endif
    #if CONFIG_HEVC_METADATA_BSF
        &ff_hevc_metadata_bsf,
    #endif
    #if CONFIG_HEVC_MP4TOANNEXB_BSF
        &ff_hevc_mp4toannexb_bsf,
    #endif
    #if CONFIG_IMX_DUMP_HEADER_BSF
        &ff_imx_dump_header_bsf,
    #endif
    #if CONFIG_LCEVC_METADATA_BSF
        &ff_lcevc_metadata_bsf,
    #endif
    #if CONFIG_MEDIA100_TO_MJPEGB_BSF
        &ff_media100_to_mjpegb_bsf,
    #endif
    #if CONFIG_MJPEG2JPEG_BSF
        &ff_mjpeg2jpeg_bsf,
    #endif
    #if CONFIG_MJPEGA_DUMP_HEADER_BSF
        &ff_mjpega_dump_header_bsf,
    #endif
    #if CONFIG_MOV2TEXTSUB_BSF
        &ff_mov2textsub_bsf,
    #endif
    #if CONFIG_TEXT2MOVSUB_BSF
        &ff_text2movsub_bsf,
    #endif
    #if CONFIG_MPEG2_METADATA_BSF
        &ff_mpeg2_metadata_bsf,
    #endif
    #if CONFIG_MPEG4_UNPACK_BFRAMES_BSF
        &ff_mpeg4_unpack_bframes_bsf,
    #endif
    #if CONFIG_NOISE_BSF
        &ff_noise_bsf,
    #endif
    #if CONFIG_NULL_BSF
        &ff_null_bsf,
    #endif
    #if CONFIG_OPUS_METADATA_BSF
        &ff_opus_metadata_bsf,
    #endif
    #if CONFIG_PCM_RECHUNK_BSF
        &ff_pcm_rechunk_bsf,
    #endif
    #if CONFIG_PGS_FRAME_MERGE_BSF
        &ff_pgs_frame_merge_bsf,
    #endif
    #if CONFIG_PRORES_METADATA_BSF
        &ff_prores_metadata_bsf,
    #endif
    #if CONFIG_REMOVE_EXTRADATA_BSF
        &ff_remove_extradata_bsf,
    #endif
    #if CONFIG_SETTS_BSF
        &ff_setts_bsf,
    #endif
    #if CONFIG_SHOWINFO_BSF
        &ff_showinfo_bsf,
    #endif
    #if CONFIG_SMPTE436M_TO_EIA608_BSF
        &ff_smpte436m_to_eia608_bsf,
    #endif
    #if CONFIG_TRACE_HEADERS_BSF
        &ff_trace_headers_bsf,
    #endif
    #if CONFIG_TRUEHD_CORE_BSF
        &ff_truehd_core_bsf,
    #endif
    #if CONFIG_VP9_METADATA_BSF
        &ff_vp9_metadata_bsf,
    #endif
    #if CONFIG_VP9_RAW_REORDER_BSF
        &ff_vp9_raw_reorder_bsf,
    #endif
    #if CONFIG_VP9_SUPERFRAME_BSF
        &ff_vp9_superframe_bsf,
    #endif
    #if CONFIG_VP9_SUPERFRAME_SPLIT_BSF
        &ff_vp9_superframe_split_bsf,
    #endif
    #if CONFIG_VVC_METADATA_BSF
        &ff_vvc_metadata_bsf,
    #endif
    #if CONFIG_VVC_MP4TOANNEXB_BSF
        &ff_vvc_mp4toannexb_bsf,
    #endif
    NULL
};
]=])

# ---------------------------------------------------------------------------
# Generate libavutil/avconfig.h and libavutil/ffversion.h
# ---------------------------------------------------------------------------
file(MAKE_DIRECTORY "${CMAKE_BINARY_DIR}/libavutil")

file(WRITE "${CMAKE_BINARY_DIR}/libavutil/avconfig.h" [=[
#ifndef AVUTIL_AVCONFIG_H
#define AVUTIL_AVCONFIG_H
#define AV_HAVE_BIGENDIAN      0
#define AV_HAVE_FAST_UNALIGNED 1
#endif /* AVUTIL_AVCONFIG_H */
]=])

file(WRITE "${CMAKE_BINARY_DIR}/libavutil/ffversion.h" [=[
#ifndef AVUTIL_FFVERSION_H
#define AVUTIL_FFVERSION_H
#define FFMPEG_VERSION "7.1"
#endif /* AVUTIL_FFVERSION_H */
]=])

# ---------------------------------------------------------------------------
# Include directories (build dir first so generated headers shadow source)
# ---------------------------------------------------------------------------
include_directories(
    ${CMAKE_BINARY_DIR}
    ${FFMPEG_SRC}
)

# ============================================================
# libavutil
# ============================================================
file(GLOB AVUTIL_SRCS
    ${FFMPEG_SRC}/libavutil/*.c
    ${FFMPEG_SRC}/libavutil/x86/*.c   # x86 init/detect files
)

# Exclude all hardware backend files (keep only hwcontext.c itself)
list(FILTER AVUTIL_SRCS EXCLUDE REGEX "/hwcontext_[a-z][a-z0-9_]*\\.c$")
list(FILTER AVUTIL_SRCS EXCLUDE REGEX "/(vulkan|macos_kperf|tx_template).*\\.c$")

if(HAVE_X86ASM)
    file(GLOB AVUTIL_ASM_SRCS ${FFMPEG_SRC}/libavutil/x86/*.asm)
    list(FILTER AVUTIL_ASM_SRCS EXCLUDE REGEX [==[/(x86inc|x86util)\.asm$]==])
    list(APPEND AVUTIL_SRCS ${AVUTIL_ASM_SRCS})
else()
    # Without NASM the x86 *_init.c files declare extern asm symbols that don't exist
    list(FILTER AVUTIL_SRCS EXCLUDE REGEX "/x86/[^/]*_init\\.c$")
endif()

# Set OutputFormat per NASM source so nasm.targets' Outputs= batching check
# fires correctly (CMake's VS generator writes <ObjectFileName> but nasm.targets
# uses %(NASM.OutputFormat) for the incremental Outputs= check).
# Mirror CMake's own conflict logic: when an .asm and a .c file share the same
# base name, CMake sets <ObjectFileName> to the full-path .asm.obj form; otherwise
# the default flat $(IntDir)/basename.obj is used and we match that here.
if(MSVC AND HAVE_X86ASM)
    set(_avutil_c_basenames "")
    foreach(_s IN LISTS AVUTIL_SRCS)
        if(_s MATCHES "\\.c$")
            get_filename_component(_bn "${_s}" NAME_WE)
            list(APPEND _avutil_c_basenames "${_bn}")
        endif()
    endforeach()
    foreach(_src IN LISTS AVUTIL_SRCS)
        if(_src MATCHES "\\.asm$")
            get_filename_component(_bn "${_src}" NAME_WE)
            if("${_bn}" IN_LIST _avutil_c_basenames)
                file(RELATIVE_PATH _rel "${CMAKE_SOURCE_DIR}" "${_src}")
                set_source_files_properties("${_src}" PROPERTIES
                    VS_SETTINGS "OutputFormat=$(IntDir)/${_rel}.obj")
            else()
                set_source_files_properties("${_src}" PROPERTIES
                    VS_SETTINGS "OutputFormat=$(IntDir)/${_bn}.obj")
            endif()
        endif()
    endforeach()
    unset(_avutil_c_basenames)
endif()

add_library(avutil SHARED ${AVUTIL_SRCS})
set_target_properties(avutil PROPERTIES WINDOWS_EXPORT_ALL_SYMBOLS ON)
if(MSVC AND HAVE_X86ASM)
    set_target_properties(avutil PROPERTIES VS_USER_PROPS "${CMAKE_BINARY_DIR}/nasm_vs_fix.props")
endif()
target_include_directories(avutil PRIVATE
    ${CMAKE_BINARY_DIR}
    ${FFMPEG_SRC}/libavutil/x86
    ${FFMPEG_SRC}/compat/atomics/win32
)
target_include_directories(avutil PUBLIC
    ${FFMPEG_SRC}
)
target_link_libraries(avutil PRIVATE ws2_32 ole32 user32 bcrypt)

# ============================================================
# libavcodec
# ============================================================
# ---------------------------------------------------------------------------
# avcodec source selection
#
# Default config (everything enabled): glob the whole tree. config_components.h
# gates the code and every cross-reference resolves because all definitions are
# present.
#
# Subset config (FFMPEG_USE_DEFAULT_CONFIG=OFF): globbing breaks — disabled
# components' files still compile and reference symbols that were #if'd out,
# producing undefined symbols at link time. Instead, compile exactly the files
# FFmpeg's own configure+make would for the enabled components: base OBJS plus
# the dependency closure (configure *_select/*_deps) mapped through the
# libavcodec Makefiles. cmake/ResolveAvcodecSrcs.cmake does that resolution.
# ---------------------------------------------------------------------------
if(NOT FFMPEG_USE_DEFAULT_CONFIG)
    # AVCODEC_RESOLVED_C / AVCODEC_RESOLVED_ASM were produced by the resolver run
    # earlier (just after the component options), so config_components.h and this
    # source list stay in lock-step.
    set(AVCODEC_SRCS ${AVCODEC_RESOLVED_C})
    if(HAVE_X86ASM)
        list(APPEND AVCODEC_SRCS ${AVCODEC_RESOLVED_ASM})
    endif()
    # Platform stub objects are in FFmpeg's base OBJS but compile to nothing when
    # their CONFIG is off; the full build omits them too. Drop them for parity.
    list(FILTER AVCODEC_SRCS EXCLUDE REGEX "/(d3d11va|mediacodec|jni|qsv_api)\\.c$")
else()
file(GLOB AVCODEC_SRCS
    ${FFMPEG_SRC}/libavcodec/*.c
    ${FFMPEG_SRC}/libavcodec/aac/*.c
    ${FFMPEG_SRC}/libavcodec/bsf/*.c
    ${FFMPEG_SRC}/libavcodec/h26x/*.c
    ${FFMPEG_SRC}/libavcodec/hevc/*.c
    ${FFMPEG_SRC}/libavcodec/opus/*.c
    ${FFMPEG_SRC}/libavcodec/vvc/*.c
    ${FFMPEG_SRC}/libavcodec/x86/*.c
)

# Exclude: hardware accelerators, external-lib wrappers,
#          Linux/macOS/Android platform code, Vulkan, test files
list(FILTER AVCODEC_SRCS EXCLUDE REGEX
    [==[/(vaapi_|vdpau|videotoolbox|audiotoolbox|mediacodec|nvenc|nvdec|amfenc|amfdec|qsvenc|qsvdec|qsv_api|qsv\.c|cuviddec|d3d12va|dxva2|d3d11va|vulkan|ohenc|ohdec|ohcodec|rkmpp|_mmal_|v4l2|mfenc|mf_utils|_mf\.|/tests/|ffjni|jni\.c|fflcms2|hapenc|mmaldec|omx\.c)]==]
)
# Also exclude files with _vulkan in their name (e.g. ffv1_vulkan.c)
list(FILTER AVCODEC_SRCS EXCLUDE REGEX "_vulkan[^/]*\\.c$")
# Exclude files requiring LCEVC external library
list(FILTER AVCODEC_SRCS EXCLUDE REGEX "/(lcevcdec|w64xmmtest)\\.c$")
# Template files: never compiled directly (they are #include'd by other files)
list(FILTER AVCODEC_SRCS EXCLUDE REGEX "[^/]*_template[^/]*\\.c$")
# Files that are #include'd by other .c files (not standalone compilation units)
list(FILTER AVCODEC_SRCS EXCLUDE REGEX "/(ac3dec|eac3dec|aacps|aacpsdata|scpr3)\\.c$")
# External library wrappers: filename starts with 'lib' (e.g. libx264.c, libvpx.c)
list(FILTER AVCODEC_SRCS EXCLUDE REGEX [==[/lib[a-z][^/]*\.c$]==])
# Standalone table-generation programs: they define main() and conflict with DLL sources.
list(FILTER AVCODEC_SRCS EXCLUDE REGEX [==[_tablegen\.c$]==])

if(HAVE_X86ASM)
    # x86 subdirectory C files (dsp_init, etc.) reference NASM symbols at runtime —
    # only include them when NASM is available
    file(GLOB _avcodec_x86_sub_c
        ${FFMPEG_SRC}/libavcodec/x86/hevc/*.c
        ${FFMPEG_SRC}/libavcodec/x86/vvc/*.c
        ${FFMPEG_SRC}/libavcodec/x86/h26x/*.c
    )
    list(APPEND AVCODEC_SRCS ${_avcodec_x86_sub_c})
    unset(_avcodec_x86_sub_c)
    file(GLOB AVCODEC_ASM_SRCS ${FFMPEG_SRC}/libavcodec/x86/*.asm)
    list(FILTER AVCODEC_ASM_SRCS EXCLUDE REGEX [==[/(x86inc|x86util)\.asm$]==])
    list(FILTER AVCODEC_ASM_SRCS EXCLUDE REGEX [==[_template\.asm$]==])
    # hevc/vvc/h26x subdirectory asm files
    file(GLOB _hevc_asm  ${FFMPEG_SRC}/libavcodec/x86/hevc/*.asm)
    file(GLOB _vvc_asm   ${FFMPEG_SRC}/libavcodec/x86/vvc/*.asm)
    # h2656_sao*.asm are %include templates (not standalone objects); only h2656_inter.asm compiles
    set(_h26x_asm ${FFMPEG_SRC}/libavcodec/x86/h26x/h2656_inter.asm)
    list(APPEND AVCODEC_ASM_SRCS ${_hevc_asm} ${_vvc_asm} ${_h26x_asm})
    unset(_hevc_asm)
    unset(_vvc_asm)
    unset(_h26x_asm)
    list(APPEND AVCODEC_SRCS ${AVCODEC_ASM_SRCS})
else()
    # Exclude all x86 *_init.c files: most have static NASM wrapper functions or
    # file-scope data referencing NASM symbols that the linker must resolve.
    list(FILTER AVCODEC_SRCS EXCLUDE REGEX "/x86/[^/]*_init\\.c$")
    # VP9 bit-depth variants (vp9dsp_init_10/12/16bpp.c) don't end in _init.c
    # but have the same static-wrapper problem — exclude them separately.
    list(FILTER AVCODEC_SRCS EXCLUDE REGEX "/x86/vp9dsp_init[^/]*\\.c$")
    # h264_qpel.c is not named *_init.c but has static NASM wrappers via H264_MC macros.
    list(FILTER AVCODEC_SRCS EXCLUDE REGEX "/x86/h264_qpel\\.c$")
    # v210-init.c uses a hyphen so it bypasses the _init.c regex, but it contains
    # raw "cpu_flags & AV_CPU_FLAG_SSSE3" checks (not EXTERNAL_*) that MSVC cannot
    # optimize away, leaving unresolved NASM symbols. Its caller is already guarded
    # by HAVE_X86ASM so the function is never called without NASM.
    list(FILTER AVCODEC_SRCS EXCLUDE REGEX "/x86/v210-init\\.c$")
    # opus/dec.c requires libswresample (re-added directly to add_library below).
    list(FILTER AVCODEC_SRCS EXCLUDE REGEX "/opus/dec\\.c$")
    # These two init files are safe to compile: all their NASM references are inside
    # #if HAVE_SSE2_INLINE / #if HAVE_INLINE_ASM / #if HAVE_SSSE3_EXTERNAL preprocessor
    # blocks (all = 0), so they are eliminated before the compiler even sees them.
    list(APPEND AVCODEC_SRCS
        ${FFMPEG_SRC}/libavcodec/x86/fdctdsp_init.c
        ${FFMPEG_SRC}/libavcodec/x86/snowdsp_init.c
    )
    # Remaining x86 init functions whose callers use #elif ARCH_X86 reference NASM
    # symbols only inside if(EXTERNAL_*())=if(0) branches. In Debug (/Od) MSVC does
    # not constant-fold those branches, so the real init files would expose unresolved
    # NASM symbols. No-op stubs satisfy the linker without any source modifications.
    list(APPEND AVCODEC_SRCS ${FFMPEG_SRC}/../x86_no_asm_stubs.c)
endif()
endif()  # FFMPEG_USE_DEFAULT_CONFIG (glob) vs subset resolver

# ============================================================
# libswresample  (needed by avcodec for the opus decoder)
# ============================================================
file(GLOB SWR_SRCS
    ${FFMPEG_SRC}/libswresample/*.c
)
list(FILTER SWR_SRCS EXCLUDE REGEX "_template\\.c$")
list(FILTER SWR_SRCS EXCLUDE REGEX "soxr_resample\\.c$")
list(FILTER SWR_SRCS EXCLUDE REGEX "noise_shaping_data\\.c$")
list(FILTER SWR_SRCS EXCLUDE REGEX "/w64xmmtest\\.c$")

if(HAVE_X86ASM)
    file(GLOB _swr_x86_c ${FFMPEG_SRC}/libswresample/x86/*.c)
    list(FILTER _swr_x86_c EXCLUDE REGEX "/w64xmmtest\\.c$")
    list(APPEND SWR_SRCS ${_swr_x86_c})
    unset(_swr_x86_c)
    file(GLOB SWR_ASM_SRCS ${FFMPEG_SRC}/libswresample/x86/*.asm)
    list(APPEND SWR_SRCS ${SWR_ASM_SRCS})
    set(_swr_c_basenames "")
    foreach(_s IN LISTS SWR_SRCS)
        if(_s MATCHES "\\.c$")
            get_filename_component(_bn "${_s}" NAME_WE)
            list(APPEND _swr_c_basenames "${_bn}")
        endif()
    endforeach()
    foreach(_src IN LISTS SWR_ASM_SRCS)
        get_filename_component(_bn "${_src}" NAME_WE)
        if("${_bn}" IN_LIST _swr_c_basenames)
            file(RELATIVE_PATH _rel "${CMAKE_SOURCE_DIR}" "${_src}")
            set_source_files_properties("${_src}" PROPERTIES
                VS_SETTINGS "OutputFormat=$(IntDir)/${_rel}.obj")
        else()
            set_source_files_properties("${_src}" PROPERTIES
                VS_SETTINGS "OutputFormat=$(IntDir)/${_bn}.obj")
        endif()
    endforeach()
    unset(_swr_c_basenames)
endif()

add_library(swresample SHARED ${SWR_SRCS})
set_target_properties(swresample PROPERTIES WINDOWS_EXPORT_ALL_SYMBOLS ON)
if(MSVC AND HAVE_X86ASM)
    set_target_properties(swresample PROPERTIES VS_USER_PROPS "${CMAKE_BINARY_DIR}/nasm_vs_fix.props")
endif()
target_include_directories(swresample PRIVATE
    ${CMAKE_BINARY_DIR}
    ${FFMPEG_SRC}/libswresample
    ${FFMPEG_SRC}/compat/atomics/win32
)
target_include_directories(swresample PUBLIC
    ${FFMPEG_SRC}
)
target_link_libraries(swresample PRIVATE avutil)

# ============================================================
# Build the opus decoder as a separate object library that
# links swresample, then attach it to avcodec.
# (Simpler: just re-add opus/dec.c and link swresample into avcodec.)
# ============================================================

# ---------------------------------------------------------------------------
# zlib: try to find globally first, fall back to vcpkg
# ---------------------------------------------------------------------------
# Ensure the platform-specific vcpkg library path is searched first for ZLIB
_ffmpeg_vcpkg_ensure()
list(PREPEND CMAKE_PREFIX_PATH "${_vcpkg_installed}")
find_package(ZLIB QUIET)
if(NOT ZLIB_FOUND)
    message(STATUS "ZLIB not found globally — fetching from vcpkg")
    _ffmpeg_vcpkg_install("zlib")
    find_package(ZLIB REQUIRED)
endif()
message(STATUS "ZLIB: ${ZLIB_INCLUDE_DIRS}")

if(MSVC AND HAVE_X86ASM)
    # Detect basename collisions across ALL source files (C vs ASM and ASM vs ASM).
    # Any basename that appears more than once gets a full relative path so obj files
    # don't overwrite each other (e.g. hevc/mc.asm and vvc/mc.asm both have bn "mc").
    set(_avcodec_seen_basenames "")
    set(_avcodec_conflict_basenames "")
    foreach(_s IN LISTS AVCODEC_SRCS)
        if(_s MATCHES "\\.(c|asm)$")
            get_filename_component(_bn "${_s}" NAME_WE)
            if("${_bn}" IN_LIST _avcodec_seen_basenames)
                list(APPEND _avcodec_conflict_basenames "${_bn}")
            else()
                list(APPEND _avcodec_seen_basenames "${_bn}")
            endif()
        endif()
    endforeach()
    list(REMOVE_DUPLICATES _avcodec_conflict_basenames)
    foreach(_src IN LISTS AVCODEC_SRCS)
        if(_src MATCHES "\\.asm$")
            get_filename_component(_bn "${_src}" NAME_WE)
            if("${_bn}" IN_LIST _avcodec_conflict_basenames)
                file(RELATIVE_PATH _rel "${CMAKE_SOURCE_DIR}" "${_src}")
                set_source_files_properties("${_src}" PROPERTIES
                    VS_SETTINGS "OutputFormat=$(IntDir)/${_rel}.obj")
            else()
                set_source_files_properties("${_src}" PROPERTIES
                    VS_SETTINGS "OutputFormat=$(IntDir)/${_bn}.obj")
            endif()
        endif()
    endforeach()
    unset(_avcodec_seen_basenames)
    unset(_avcodec_conflict_basenames)
endif()

# opus/dec.c is excluded from the glob (needs libswresample) and re-added here for
# the full build. The subset resolver already includes it iff the opus decoder is
# enabled, so only add it back in default-config mode.
set(_avcodec_extra_srcs "")
if(FFMPEG_USE_DEFAULT_CONFIG)
    set(_avcodec_extra_srcs ${FFMPEG_SRC}/libavcodec/opus/dec.c)
endif()
add_library(avcodec SHARED ${AVCODEC_SRCS} ${_avcodec_extra_srcs})
set_target_properties(avcodec PROPERTIES WINDOWS_EXPORT_ALL_SYMBOLS ON)
if(MSVC AND HAVE_X86ASM)
    set_target_properties(avcodec PROPERTIES VS_USER_PROPS "${CMAKE_BINARY_DIR}/nasm_vs_fix.props")
endif()

target_include_directories(avcodec PRIVATE
    ${CMAKE_BINARY_DIR}
    ${FFMPEG_SRC}
    ${FFMPEG_SRC}/libavcodec
    ${FFMPEG_SRC}/libavcodec/x86
    ${FFMPEG_SRC}/compat/atomics/win32
    ${ZLIB_INCLUDE_DIRS}
)
target_link_libraries(avcodec PRIVATE avutil swresample ws2_32 ZLIB::ZLIB)

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
message(STATUS "")
message(STATUS "FFmpeg build summary")
message(STATUS "  Generator : ${CMAKE_GENERATOR}")
message(STATUS "  Build dir : ${CMAKE_BINARY_DIR}")
message(STATUS "  NASM/x86  : ${HAVE_X86ASM}")
message(STATUS "")
message(STATUS "To build:")
message(STATUS "  cmake --build ${CMAKE_BINARY_DIR} --config Release")
