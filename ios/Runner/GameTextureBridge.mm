#include "game_texture.h"

#import <Flutter/Flutter.h>
#import <Foundation/Foundation.h>

#include <atomic>

@interface PixelBufferGameTexture : NSObject
- (BOOL)lockBackBuffer:(void**)outBase
                  pitch:(int32_t*)outPitch
                  width:(int32_t*)outWidth
                 height:(int32_t*)outHeight;
- (void)commitBackBufferAndSwap;
- (void)cancelBackBufferLock;
@end

namespace {

__weak static PixelBufferGameTexture* gActiveTextureWeak = nil;
__weak static id<FlutterTextureRegistry> gRegistryWeak = nil;
static int64_t gTextureId = 0;

static std::atomic<bool> gFrameReady{false};
static std::atomic<uint64_t> gPresentedFrames{0};

}  // namespace

extern "C" {

void game_texture_ios_set_active(void* context) {
  if (context == nullptr) {
    gActiveTextureWeak = nil;
    gFrameReady.store(false, std::memory_order_relaxed);
    return;
  }
  gActiveTextureWeak = (__bridge PixelBufferGameTexture*)context;
}

void game_texture_ios_set_flutter_texture(void* registry, int64_t texture_id) {
  gRegistryWeak = (__bridge id<FlutterTextureRegistry>)registry;
  gTextureId = texture_id;
}

bool game_texture_ios_lock_back_buffer(uint8_t** out_base, int32_t* out_pitch,
                                       int32_t* out_width, int32_t* out_height) {
  if (out_base == nullptr || out_pitch == nullptr) {
    return false;
  }
  PixelBufferGameTexture* texture = gActiveTextureWeak;
  if (texture == nil) {
    return false;
  }

  void* base = nullptr;
  int32_t pitch = 0;
  int32_t width = 0;
  int32_t height = 0;
  if (![texture lockBackBuffer:&base pitch:&pitch width:&width height:&height]) {
    return false;
  }

  *out_base = static_cast<uint8_t*>(base);
  *out_pitch = pitch;
  if (out_width) {
    *out_width = width;
  }
  if (out_height) {
    *out_height = height;
  }
  return true;
}

void game_texture_ios_commit_back_buffer(void) {
  PixelBufferGameTexture* texture = gActiveTextureWeak;
  if (texture == nil) {
    return;
  }
  [texture commitBackBufferAndSwap];
}

void game_texture_ios_cancel_back_buffer_lock(void) {
  PixelBufferGameTexture* texture = gActiveTextureWeak;
  if (texture == nil) {
    return;
  }
  [texture cancelBackBufferLock];
}

void game_texture_ios_mark_frame_ready(void) {
  gFrameReady.store(true, std::memory_order_release);
}

void game_texture_ios_on_display_link(void) {
  if (!gFrameReady.exchange(false, std::memory_order_acq_rel)) {
    return;
  }

  id<FlutterTextureRegistry> registry = gRegistryWeak;
  if (registry != nil) {
    [registry textureFrameAvailable:gTextureId];
    gPresentedFrames.fetch_add(1, std::memory_order_relaxed);
  }
}

uint64_t game_texture_ios_presented_frame_count(void) {
  return gPresentedFrames.load(std::memory_order_relaxed);
}

// Legacy no-op stubs (Android uses upload_rgba).
void game_texture_ios_upload(const uint8_t* src, int32_t width, int32_t height,
                             int32_t pitch_bytes) {
  (void)src;
  (void)width;
  (void)height;
  (void)pitch_bytes;
}

void game_texture_ios_upload_bgra(const uint8_t* src, int32_t width, int32_t height,
                                  int32_t pitch_bytes) {
  (void)src;
  (void)width;
  (void)height;
  (void)pitch_bytes;
}

}  // extern "C"
