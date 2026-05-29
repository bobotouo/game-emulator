#pragma once
#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// ── Pixel format constants (mirrors libretro) ──────────────────────────────
#define EMU_PIXEL_FORMAT_0RGB1555 0
#define EMU_PIXEL_FORMAT_XRGB8888 1
#define EMU_PIXEL_FORMAT_RGB565   2

// ── Pure-C libretro callback getters ──────────────────────────────────────
// Call retro_set_XXX with these after retro_load_game() succeeds, then start
// emulator_loop_start(). The callbacks are thread-safe and do NOT invoke Dart.

typedef void   (*emu_video_refresh_t)(const void*, unsigned, unsigned, size_t);
typedef size_t (*emu_audio_batch_t)(const int16_t*, size_t);
typedef void   (*emu_audio_single_t)(int16_t, int16_t);
typedef void   (*emu_input_poll_t)(void);
typedef int16_t(*emu_input_state_t)(unsigned, unsigned, unsigned, unsigned);
typedef unsigned (*emu_environment_t)(unsigned, void*);

emu_video_refresh_t  emulator_loop_video_cb(void);
emu_audio_batch_t    emulator_loop_audio_batch_cb(void);
emu_audio_single_t   emulator_loop_audio_single_cb(void);
emu_input_poll_t     emulator_loop_input_poll_cb(void);
emu_input_state_t    emulator_loop_input_state_cb(void);
emu_environment_t    emulator_loop_environment_cb(void);

// ── Pixel format (set once after RETRO_ENVIRONMENT_SET_PIXEL_FORMAT) ───────
void emulator_loop_set_pixel_format(int32_t format);

// ── Native game loop ───────────────────────────────────────────────────────
typedef void (*emu_retro_run_t)(void);
void emulator_loop_start(emu_retro_run_t retro_run, double fps);
void emulator_loop_stop(void);
void emulator_loop_set_paused(bool paused);
void emulator_loop_set_speed(int32_t speed);
bool emulator_loop_is_running(void);

// Run [count] frames on a dedicated native thread (NOT the Dart isolate).
// Safe only while emulator_loop_start() has not been called yet.
void emulator_loop_run_frames(emu_retro_run_t retro_run, uint32_t count);

// ── Input (called from Dart on button events) ─────────────────────────────
void emulator_loop_set_input_bit(int32_t btn_id, bool pressed);
void emulator_loop_clear_inputs(void);

// ── Audio ring buffer ───────────────────────────────────────────────────────
int32_t emulator_loop_audio_available(void);
int32_t emulator_loop_audio_read(int16_t* out, int32_t max_samples);
void emulator_loop_audio_discard(int32_t sample_count);
void emulator_loop_audio_flush(void);
int32_t emulator_loop_audio_target_samples(void);
void emulator_loop_audio_set_target_samples(int32_t samples);

// Tell libretro cores (e.g. mGBA) which rate to resample to before audio_batch.
void emulator_loop_set_target_sample_rate(unsigned sample_rate);
double emulator_loop_get_reported_sample_rate(void);

// iOS: activate AVAudioSession and return actual hardware rate (call before retro_load_game).
double emulator_loop_prepare_audio_output_rate(double preferred_hz);

// iOS: AudioUnit pulls from the ring buffer (no Dart timer).
void emulator_loop_audio_start(double sample_rate);
void emulator_loop_audio_stop(void);
void emulator_loop_audio_set_paused(bool paused);
void emulator_loop_audio_set_playback_speed(int32_t speed);

// ── Frame counter ──────────────────────────────────────────────────────────
uint64_t emulator_loop_frame_count(void);

// ── Rumble events (set by libretro rumble callback, polled by Dart) ───────
uint64_t emulator_loop_rumble_sequence(void);
uint32_t emulator_loop_rumble_strong(void);
uint32_t emulator_loop_rumble_weak(void);

// ── Save directory (set from Dart before retro_load_game) ─────────────────
void emulator_loop_set_save_directory(const char* path);

// ── Last rendered frame (valid after retro_run, read from Dart thread) ────
// Returns RGBA8888 pointer; sets width/height via out-params.
// Returns NULL if no frame has been rendered yet.
const uint8_t* emulator_loop_last_frame(int32_t* width_out, int32_t* height_out);

#ifdef __cplusplus
}
#endif
