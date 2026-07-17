#include <stdint.h>

const uint32_t kadath_renderer2d_quad_vert_spv[] =
#include "renderer2d_quad.vert.inc"
;

const uint32_t kadath_renderer2d_quad_vert_spv_word_count =
    (uint32_t)(sizeof(kadath_renderer2d_quad_vert_spv) /
               sizeof(kadath_renderer2d_quad_vert_spv[0]));
