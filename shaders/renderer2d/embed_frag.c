#include <stdint.h>

const uint32_t kadath_renderer2d_quad_frag_spv[] =
#include "renderer2d_quad.frag.inc"
;

const uint32_t kadath_renderer2d_quad_frag_spv_word_count =
    (uint32_t)(sizeof(kadath_renderer2d_quad_frag_spv) /
               sizeof(kadath_renderer2d_quad_frag_spv[0]));
