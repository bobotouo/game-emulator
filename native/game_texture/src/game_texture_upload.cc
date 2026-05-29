#include "game_texture.h"

#if defined(__ANDROID__)
extern "C" void game_texture_android_upload(const uint8_t* src, int32_t width,
                                            int32_t height, int32_t pitch_bytes);
#endif

void game_texture_upload_rgba(const uint8_t* src, int32_t width, int32_t height,
                              int32_t pitch_bytes) {
  if (src == nullptr || width <= 0 || height <= 0) {
    return;
  }

#if defined(__ANDROID__)
  game_texture_android_upload(src, width, height, pitch_bytes);
#endif
}
