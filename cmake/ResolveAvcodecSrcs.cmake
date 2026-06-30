# ---------------------------------------------------------------------------
# ffmpeg_resolve_avcodec_srcs — pure-CMake source resolver for subset builds.
#
# Replicates what FFmpeg's configure+make do for a chosen set of components:
# compile base OBJS + the dependency closure (configure *_select / *_deps) +
# OBJS-$(HAVE_*) (threading) + x86 SIMD, mapped through libavcodec/Makefile and
# libavcodec/x86/Makefile. Without this, the CMakeLists globs the whole tree and
# only links when everything is enabled; a reduced config leaves disabled files
# referencing #if'd-out symbols -> walls of undefined symbols.
#
#   ffmpeg_resolve_avcodec_srcs(<ffmpeg_dir> <config_h> <have_x86asm:0|1>
#                               <out_c> <out_asm> <out_closure> COMP [COMP...])
#
#   <config_h>   generated config.h, read for enabled HAVE_* flags.
#   COMP...      component symbols in UPPER case, as the FFMPEG_CONFIG_<COMP>
#                options (e.g. WMAPRO_DECODER, XMA2_DECODER).
#
# Sets in the caller's scope:
#   <out_c>        absolute .c paths to compile
#   <out_asm>      absolute .asm paths (empty unless have_x86asm)
#   <out_closure>  UPPER-case CONFIG names in the dependency closure
# ---------------------------------------------------------------------------

# Parse one Makefile, accumulating into caller-scope:
#   _base_objs            unconditional OBJS / SHLIBOBJS / STLIBOBJS (+ X86ASM base)
#   _cobj_<CONFIG_NAME>   OBJS-$(CONFIG_<NAME>)  (+ X86ASM-OBJS-$(CONFIG_<NAME>))
#   _hobj_<HAVE_NAME>     OBJS-$(HAVE_<NAME>)
macro(_ff_parse_makefile _path _want_x86asm)
    set(_x86 "${_want_x86asm}")   # macro params don't resolve as bare if() vars
    if(EXISTS "${_path}")
        file(READ "${_path}" _mk)
        string(REGEX REPLACE "\r" "" _mk "${_mk}")
        string(REPLACE "${_FF_BS}${_FF_NL}" " " _mk "${_mk}")   # join continuations
        string(REPLACE "${_FF_NL}" ";" _mk_lines "${_mk}")       # one element per line
        foreach(_line IN LISTS _mk_lines)
            # Note: an inner string(REGEX MATCHALL) clobbers CMAKE_MATCH_*, so capture
            # the name/value from the line match into temporaries first.
            if(_line MATCHES "^(SHLIBOBJS|STLIBOBJS|OBJS)[ \t]*[+]?=(.*)$")
                set(_rhs "${CMAKE_MATCH_2}")
                string(REGEX MATCHALL "[A-Za-z0-9_./-]+\\.o" _os "${_rhs}")
                list(APPEND _base_objs ${_os})
            elseif(_line MATCHES "^OBJS-[$][(]CONFIG_([A-Z0-9_]+)[)][ \t]*[+]?=(.*)$")
                set(_key "${CMAKE_MATCH_1}")
                set(_rhs "${CMAKE_MATCH_2}")
                string(REGEX MATCHALL "[A-Za-z0-9_./-]+\\.o" _os "${_rhs}")
                list(APPEND _cobj_${_key} ${_os})
            elseif(_line MATCHES "^OBJS-[$][(]HAVE_([A-Z0-9_]+)[)][ \t]*[+]?=(.*)$")
                set(_key "${CMAKE_MATCH_1}")
                set(_rhs "${CMAKE_MATCH_2}")
                string(REGEX MATCHALL "[A-Za-z0-9_./-]+\\.o" _os "${_rhs}")
                list(APPEND _hobj_${_key} ${_os})
            elseif(_x86 AND _line MATCHES "^X86ASM-OBJS-[$][(]CONFIG_([A-Z0-9_]+)[)][ \t]*[+]?=(.*)$")
                set(_key "${CMAKE_MATCH_1}")
                set(_rhs "${CMAKE_MATCH_2}")
                string(REGEX MATCHALL "[A-Za-z0-9_./-]+\\.o" _os "${_rhs}")
                list(APPEND _cobj_${_key} ${_os})
            elseif(_x86 AND _line MATCHES "^X86ASM-OBJS[ \t]*[+]?=(.*)$")
                set(_rhs "${CMAKE_MATCH_1}")
                string(REGEX MATCHALL "[A-Za-z0-9_./-]+\\.o" _os "${_rhs}")
                list(APPEND _base_objs ${_os})
            endif()
        endforeach()
    endif()
endmacro()

function(ffmpeg_resolve_avcodec_srcs FFMPEG_DIR CONFIG_H HAVE_X86ASM OUT_C OUT_ASM OUT_CLOSURE)
    string(ASCII 10 _FF_NL)
    string(ASCII 92 _FF_BS)
    set(_lavc "${FFMPEG_DIR}/libavcodec")

    # -- 1. configure: select/deps adjacency for every symbol -------------------
    file(READ "${FFMPEG_DIR}/configure" _cfg)
    string(REGEX MATCHALL "[a-z0-9_]+_select=\"[^\"]*\"" _sel "${_cfg}")
    string(REGEX MATCHALL "[a-z0-9_]+_deps=\"[^\"]*\"" _dep "${_cfg}")
    foreach(_m IN LISTS _sel _dep)
        string(REGEX REPLACE "^([a-z0-9_]+)_(select|deps)=\"([^\"]*)\"$" "\\1" _nm "${_m}")
        string(REGEX REPLACE "^([a-z0-9_]+)_(select|deps)=\"([^\"]*)\"$" "\\3" _vv "${_m}")
        string(REGEX REPLACE "[ \t]+" ";" _toks "${_vv}")
        foreach(_t IN LISTS _toks)
            if(_t MATCHES "^[a-z0-9_]+$")           # plain tokens only (skip !foo etc.)
                list(APPEND _edge_${_nm} "${_t}")
            endif()
        endforeach()
    endforeach()

    # -- 2. transitive closure from the enabled components ----------------------
    set(_stack "")
    foreach(_c IN LISTS ARGN)
        string(TOLOWER "${_c}" _cl)
        list(APPEND _stack "${_cl}")
    endforeach()
    set(_closure "")
    list(LENGTH _stack _n)
    while(_n GREATER 0)
        list(POP_BACK _stack _node)
        if(NOT _node IN_LIST _closure)
            list(APPEND _closure "${_node}")
            foreach(_nxt IN LISTS _edge_${_node})
                list(APPEND _stack "${_nxt}")
            endforeach()
        endif()
        list(LENGTH _stack _n)
    endwhile()

    # -- 3. enabled HAVE_* flags (threading etc. are keyed on these) ------------
    file(READ "${CONFIG_H}" _ch)
    string(REGEX MATCHALL "#define[ \t]+HAVE_[A-Z0-9_]+[ \t]+1[^0-9]" _hm "${_ch}")
    set(_haves "")
    foreach(_h IN LISTS _hm)
        string(REGEX REPLACE ".*HAVE_([A-Z0-9_]+).*" "\\1" _hn "${_h}")
        list(APPEND _haves "${_hn}")
    endforeach()

    # -- 4. parse the Makefiles -------------------------------------------------
    set(_base_objs "")
    _ff_parse_makefile("${_lavc}/Makefile" "${HAVE_X86ASM}")
    _ff_parse_makefile("${_lavc}/x86/Makefile" "${HAVE_X86ASM}")

    # -- 5. collect the needed object files -------------------------------------
    set(_objs ${_base_objs})
    foreach(_node IN LISTS _closure)
        string(TOUPPER "${_node}" _NODE)
        list(APPEND _objs ${_cobj_${_NODE}})
    endforeach()
    foreach(_h IN LISTS _haves)
        list(APPEND _objs ${_hobj_${_h}})
    endforeach()
    if(_objs)
        list(REMOVE_DUPLICATES _objs)
    endif()

    # -- 6. map .o -> .c / .asm (keep only files that exist) --------------------
    set(_c_srcs "")
    set(_asm_srcs "")
    foreach(_o IN LISTS _objs)
        string(REGEX REPLACE "\\.o$" "" _stem "${_o}")
        if(EXISTS "${_lavc}/${_stem}.c")
            list(APPEND _c_srcs "${_lavc}/${_stem}.c")
        elseif(EXISTS "${_lavc}/${_stem}.asm")
            list(APPEND _asm_srcs "${_lavc}/${_stem}.asm")
        endif()
    endforeach()
    if(_c_srcs)
        list(REMOVE_DUPLICATES _c_srcs)
        list(SORT _c_srcs)
    endif()
    if(_asm_srcs)
        list(REMOVE_DUPLICATES _asm_srcs)
        list(SORT _asm_srcs)
    endif()

    # -- 7. closure as UPPER-case CONFIG names ----------------------------------
    set(_clup "")
    foreach(_node IN LISTS _closure)
        string(TOUPPER "${_node}" _NODE)
        list(APPEND _clup "${_NODE}")
    endforeach()
    list(SORT _clup)

    set(${OUT_C} "${_c_srcs}" PARENT_SCOPE)
    set(${OUT_ASM} "${_asm_srcs}" PARENT_SCOPE)
    set(${OUT_CLOSURE} "${_clup}" PARENT_SCOPE)
endfunction()
