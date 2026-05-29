#pragma once

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Upload RGBA8888 rows (Android / fallback).
void game_texture_upload_rgba(const uint8_t* src, int32_t width, int32_t height,
                              int32_t pitch_bytes);

/// iOS: register the active CVPixelBuffer texture (called from Swift plugin).
void game_texture_ios_set_active(void* texture_context);

/// iOS: Flutter texture registry + id (set from Swift plugin).
void game_texture_ios_set_flutter_texture(void* registry, int64_t texture_id);

/// iOS Delta-style path: lock IOSurface back buffer, write BGRA, swap, signal display link.
/// Returns false if no texture or dimensions do not match the texture.
bool game_texture_ios_lock_back_buffer(uint8_t** out_base, int32_t* out_pitch,
                                       int32_t* out_width, int32_t* out_height);
void game_texture_ios_commit_back_buffer(void);
void game_texture_ios_cancel_back_buffer_lock(void);

/// Called from Swift after back-buffer swap (signals CADisplayLink).
void game_texture_ios_mark_frame_ready(void);

/// Called from CADisplayLink on the main thread (at most once per vsync).
void game_texture_ios_on_display_link(void);

/// Frames actually presented to Flutter (vs retro_run count).
uint64_t game_texture_ios_presented_frame_count(void);

/// Android: register SurfaceProducer entry (called from Kotlin plugin).
void game_texture_android_set_active(void* producer_context);

#ifdef __cplusplus
}
#endif
