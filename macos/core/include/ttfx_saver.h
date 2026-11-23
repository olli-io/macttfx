// C interface of the ttfx screensaver core (macos/core/src/lib.rs).

#ifndef TTFX_SAVER_H
#define TTFX_SAVER_H

#include <stddef.h>
#include <stdint.h>

#define TTFX_ATTR_BOLD (1u << 0)
#define TTFX_ATTR_DIM (1u << 1)
#define TTFX_ATTR_ITALIC (1u << 2)
#define TTFX_ATTR_UNDERLINE (1u << 3)
#define TTFX_ATTR_BLINK (1u << 4)
#define TTFX_ATTR_REVERSE (1u << 5)
#define TTFX_ATTR_HIDDEN (1u << 6)
#define TTFX_ATTR_STRIKE (1u << 7)

#define TTFX_FLAG_FG (1u << 0)
#define TTFX_FLAG_BG (1u << 1)
#define TTFX_FLAG_WIDE (1u << 2)

// One character cell.
typedef struct {
  uint32_t codepoint; // Unicode scalar value
  uint32_t fg;        // 0xRRGGBB, valid only with TTFX_FLAG_FG
  uint32_t bg;        // 0xRRGGBB, valid only with TTFX_FLAG_BG
  uint16_t attrs;     // TTFX_ATTR_* bits
  uint8_t flags;      // TTFX_FLAG_* bits
  uint8_t reserved;
} TtfxCell;

typedef struct TtfxSession TtfxSession;

// The number of effects.
int ttfx_saver_effect_count(void);

// The name of effect `index`, or NULL. Valid for the life of the process.
const char *ttfx_saver_effect_name(int index);

// Starts an effect with its default options on a grid of cols x rows cells.
// `text` is UTF-8 and does not need a terminator. Returns NULL on failure.
TtfxSession *ttfx_saver_new(const uint8_t *text, size_t text_len,
                            const char *effect_name, int cols, int rows,
                            uint64_t seed);

// Makes the next frame. 1 = frame ready, 0 = effect complete, -1 = error.
int ttfx_saver_step(TtfxSession *session);

// The cells of the last frame: cols * rows cells, top row first. Valid until
// the session is freed.
const TtfxCell *ttfx_saver_cells(const TtfxSession *session);

// Frees a session. NULL is permitted.
void ttfx_saver_free(TtfxSession *session);

#endif
