/*
 * No-op stubs for x86 init functions when building without NASM.
 *
 * Several libavcodec callers invoke these functions under #elif ARCH_X86
 * (without a HAVE_X86ASM guard). When NASM is unavailable the real
 * implementations (which live in libavcodec/x86/*_init.c and reference NASM
 * symbols) are excluded from the build. These stubs satisfy the linker while
 * leaving all function pointers at their C fallback values.
 */

#include "FFmpeg/libavutil/attributes.h"

typedef struct LLVidEncDSPContext     LLVidEncDSPContext;
typedef struct LPCContext             LPCContext;
typedef struct MLPDSPContext          MLPDSPContext;
typedef struct MpegvideoEncDSPContext MpegvideoEncDSPContext;
typedef struct AVCodecContext         AVCodecContext;

/* lossless_videoencdsp.c: #elif ARCH_X86 */
av_cold void ff_llvidencdsp_init_x86(LLVidEncDSPContext *c)
    { (void)c; }

/* lpc.c: #elif ARCH_X86 */
av_cold void ff_lpc_init_x86(LPCContext *c)
    { (void)c; }

/* mlpdsp.c: #elif ARCH_X86 */
av_cold void ff_mlpdsp_init_x86(MLPDSPContext *c)
    { (void)c; }

/* mpegvideoencdsp.c: #elif ARCH_X86 */
av_cold void ff_mpegvideoencdsp_init_x86(MpegvideoEncDSPContext *c,
                                          AVCodecContext *avctx)
    { (void)c; (void)avctx; }
