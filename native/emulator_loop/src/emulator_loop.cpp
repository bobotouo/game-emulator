#include "emulator_loop.h"
#include "game_texture.h"

#include <atomic>
#include <cstdarg>
#include <cstdio>
#include <cstring>

static void AudioLog(const char* fmt, ...) {
  char buf[512];
  va_list args;
  va_start(args, fmt);
  vsnprintf(buf, sizeof(buf), fmt, args);
  va_end(args);
  std::fprintf(stderr, "[GBA-Audio] %s\n", buf);
  std::fflush(stderr);
}

// libretro environment command IDs we need to handle
#define _RETRO_ENV_SET_PIXEL_FORMAT    10
#define _RETRO_ENV_GET_RUMBLE_INTERFACE 23
#define _RETRO_ENV_GET_SAVE_DIRECTORY  31
#define _RETRO_ENV_SET_SYSTEM_AV_INFO  14
#define _RETRO_ENV_GET_TARGET_SAMPLE_RATE 67

struct retro_system_timing {
  double fps;
  double sample_rate;
};

struct retro_game_geometry {
  unsigned base_width;
  unsigned base_height;
  unsigned max_width;
  unsigned max_height;
  float aspect_ratio;
};

struct retro_system_av_info {
  struct retro_game_geometry geometry;
  struct retro_system_timing timing;
};

#define _RETRO_RUMBLE_STRONG 0
#define _RETRO_RUMBLE_WEAK   1

// ── Pixel format ─────────────────────────────────────────────────────────
static std::atomic<int32_t> gPixelFormat{EMU_PIXEL_FORMAT_XRGB8888};

// ── Save directory ────────────────────────────────────────────────────────
static char gSaveDirBuf[4096] = {0};

// ── Audio ring buffer (lock-free SPSC) ────────────────────────────────────
static const int32_t kAudioRing = 49152;  // int16 samples (~0.5s at 48 kHz stereo)
static int16_t gAudioBuf[kAudioRing];
static std::atomic<int32_t> gAudioR{0};
static std::atomic<int32_t> gAudioW{0};
static std::atomic<int32_t> gAudioTarget{0};
static std::atomic<unsigned> gTargetSampleRate{48000};
static std::atomic<double> gReportedSampleRate{48000.0};

static void AudioWrite(const int16_t* src, int32_t n) {
  if (n <= 0) return;
  int32_t w = gAudioW.load(std::memory_order_relaxed);
  int32_t r = gAudioR.load(std::memory_order_acquire);
  int32_t space = (r - w - 1 + kAudioRing) % kAudioRing;
  if (n > space) {
    const int32_t drop = n - space;
    r = (r + drop) % kAudioRing;
    gAudioR.store(r, std::memory_order_release);
    space = n;
  }
  for (int32_t i = 0; i < n; ++i) {
    gAudioBuf[(w + i) % kAudioRing] = src[i];
  }
  gAudioW.store((w + n) % kAudioRing, std::memory_order_release);
}

// ── Input bitmask ─────────────────────────────────────────────────────────
static std::atomic<uint64_t> gInputMask{0};

// ── Frame counter ─────────────────────────────────────────────────────────
static std::atomic<uint64_t> gFrameCount{0};

// ── Rumble state ──────────────────────────────────────────────────────────
static std::atomic<uint32_t> gRumbleStrong{0};
static std::atomic<uint32_t> gRumbleWeak{0};
static std::atomic<uint64_t> gRumbleSeq{0};

typedef bool (*retro_set_rumble_state_t)(unsigned port, unsigned effect,
                                         uint16_t strength);

struct retro_rumble_interface {
  retro_set_rumble_state_t set_rumble_state;
};

// Thumbnail / no-texture fallback only (not used during gameplay on iOS).
static uint8_t gConvBuf[512 * 512 * 4];
static std::atomic<int32_t> gLastW{0};
static std::atomic<int32_t> gLastH{0};

#if defined(__APPLE__) && TARGET_OS_IOS
// Libretro XRGB8888 memory layout is B,G,R,x — write BGRA directly into IOSurface.
static void BlitXrgb8888ToBgra(const uint8_t* src, uint8_t* dst, int32_t w, int32_t h,
                               int32_t srcPitch, int32_t dstPitch) {
  for (int32_t y = 0; y < h; ++y) {
    const uint8_t* row = src + y * srcPitch;
    uint8_t* out = dst + y * dstPitch;
    for (int32_t x = 0; x < w; ++x) {
      const int32_t p = x * 4;
      out[p + 0] = row[p + 0];
      out[p + 1] = row[p + 1];
      out[p + 2] = row[p + 2];
      out[p + 3] = 255;
    }
  }
}

static void BlitRgb565ToBgra(const uint8_t* src, uint8_t* dst, int32_t w, int32_t h,
                              int32_t srcPitch, int32_t dstPitch) {
  for (int32_t y = 0; y < h; ++y) {
    const uint8_t* row = src + y * srcPitch;
    uint8_t* out = dst + y * dstPitch;
    for (int32_t x = 0; x < w; ++x) {
      const int32_t p = x * 2;
      const uint16_t px = (uint16_t)row[p] | ((uint16_t)row[p + 1] << 8);
      const uint8_t r5 = (px >> 11) & 0x1F;
      const uint8_t g6 = (px >> 5) & 0x3F;
      const uint8_t b5 = px & 0x1F;
      const int32_t o = x * 4;
      out[o + 0] = (b5 << 3) | (b5 >> 2);
      out[o + 1] = (g6 << 2) | (g6 >> 4);
      out[o + 2] = (r5 << 3) | (r5 >> 2);
      out[o + 3] = 255;
    }
  }
}

static void Blit0rgb1555ToBgra(const uint8_t* src, uint8_t* dst, int32_t w, int32_t h,
                                int32_t srcPitch, int32_t dstPitch) {
  for (int32_t y = 0; y < h; ++y) {
    const uint8_t* row = src + y * srcPitch;
    uint8_t* out = dst + y * dstPitch;
    for (int32_t x = 0; x < w; ++x) {
      const int32_t p = x * 2;
      const uint16_t px = (uint16_t)row[p] | ((uint16_t)row[p + 1] << 8);
      const uint8_t r5 = (px >> 10) & 0x1F;
      const uint8_t g5 = (px >> 5) & 0x1F;
      const uint8_t b5 = px & 0x1F;
      const int32_t o = x * 4;
      out[o + 0] = (b5 << 3) | (b5 >> 2);
      out[o + 1] = (g5 << 3) | (g5 >> 2);
      out[o + 2] = (r5 << 3) | (r5 >> 2);
      out[o + 3] = 255;
    }
  }
}

static bool PresentToIOSurface(const uint8_t* src, int32_t w, int32_t h, int32_t srcPitch,
                               int32_t fmt) {
  uint8_t* dst = nullptr;
  int32_t dstPitch = 0;
  int32_t texW = 0;
  int32_t texH = 0;
  if (!game_texture_ios_lock_back_buffer(&dst, &dstPitch, &texW, &texH)) {
    return false;
  }
  if (texW != w || texH != h) {
    game_texture_ios_cancel_back_buffer_lock();
    return false;
  }

  if (fmt == EMU_PIXEL_FORMAT_XRGB8888) {
    BlitXrgb8888ToBgra(src, dst, w, h, srcPitch, dstPitch);
  } else if (fmt == EMU_PIXEL_FORMAT_RGB565) {
    BlitRgb565ToBgra(src, dst, w, h, srcPitch, dstPitch);
  } else {
    Blit0rgb1555ToBgra(src, dst, w, h, srcPitch, dstPitch);
  }

  game_texture_ios_commit_back_buffer();
  return true;
}
#endif

static void ConvertXrgb8888ToRgba(const uint8_t* src, uint8_t* dst, int32_t w, int32_t h,
                                    int32_t pitch) {
  for (int y = 0; y < h; ++y) {
    const uint8_t* row = src + y * pitch;
    uint8_t* out = dst + y * w * 4;
    for (int x = 0; x < w; ++x) {
      int p = x * 4;
      out[x * 4 + 0] = row[p + 2];
      out[x * 4 + 1] = row[p + 1];
      out[x * 4 + 2] = row[p + 0];
      out[x * 4 + 3] = 0xFF;
    }
  }
}

static void ConvertRgb565(const uint8_t* src, uint8_t* dst,
                           int32_t w, int32_t h, int32_t pitch) {
  for (int y = 0; y < h; ++y) {
    const uint8_t* row = src + y * pitch;
    uint8_t* out = dst + y * w * 4;
    for (int x = 0; x < w; ++x) {
      int p = x * 2;
      uint16_t px = (uint16_t)row[p] | ((uint16_t)row[p+1] << 8);
      uint8_t r5 = (px >> 11) & 0x1F;
      uint8_t g6 = (px >>  5) & 0x3F;
      uint8_t b5 =  px        & 0x1F;
      out[x*4+0] = (r5 << 3) | (r5 >> 2);
      out[x*4+1] = (g6 << 2) | (g6 >> 4);
      out[x*4+2] = (b5 << 3) | (b5 >> 2);
      out[x*4+3] = 0xFF;
    }
  }
}

static void Convert0rgb1555(const uint8_t* src, uint8_t* dst,
                              int32_t w, int32_t h, int32_t pitch) {
  for (int y = 0; y < h; ++y) {
    const uint8_t* row = src + y * pitch;
    uint8_t* out = dst + y * w * 4;
    for (int x = 0; x < w; ++x) {
      int p = x * 2;
      uint16_t px = (uint16_t)row[p] | ((uint16_t)row[p+1] << 8);
      uint8_t r5 = (px >> 10) & 0x1F;
      uint8_t g5 = (px >>  5) & 0x1F;
      uint8_t b5 =  px        & 0x1F;
      out[x*4+0] = (r5 << 3) | (r5 >> 2);
      out[x*4+1] = (g5 << 3) | (g5 >> 2);
      out[x*4+2] = (b5 << 3) | (b5 >> 2);
      out[x*4+3] = 0xFF;
    }
  }
}

// ── Pure-C callbacks ──────────────────────────────────────────────────────

static void C_VideoRefresh(const void* data, unsigned width, unsigned height, size_t pitch) {
  if (!data || !width || !height) return;

  const uint8_t* src = static_cast<const uint8_t*>(data);
  const int32_t w = (int32_t)width;
  const int32_t h = (int32_t)height;
  const int32_t srcPitch = (int32_t)pitch;
  const int fmt = gPixelFormat.load(std::memory_order_relaxed);

  gLastW.store(w, std::memory_order_relaxed);
  gLastH.store(h, std::memory_order_relaxed);

#if defined(__APPLE__) && TARGET_OS_IOS
  if (PresentToIOSurface(src, w, h, srcPitch, fmt)) {
    gFrameCount.fetch_add(1, std::memory_order_relaxed);
    return;
  }
#endif

  if (w * h * 4 > (int32_t)sizeof(gConvBuf)) return;

  if (fmt == EMU_PIXEL_FORMAT_XRGB8888) {
    ConvertXrgb8888ToRgba(src, gConvBuf, w, h, srcPitch);
  } else if (fmt == EMU_PIXEL_FORMAT_RGB565) {
    ConvertRgb565(src, gConvBuf, w, h, srcPitch);
  } else {
    Convert0rgb1555(src, gConvBuf, w, h, srcPitch);
  }

#if !defined(__APPLE__) || !TARGET_OS_IOS
  game_texture_upload_rgba(gConvBuf, w, h, w * 4);
#endif
  gFrameCount.fetch_add(1, std::memory_order_relaxed);
}

static size_t C_AudioBatch(const int16_t* data, size_t frames) {
  static std::atomic<bool> gLoggedFirstBatch{false};
  if (!gLoggedFirstBatch.exchange(true)) {
    AudioLog("first audio_batch: frames=%zu (stereo pairs)", frames);
  }
  AudioWrite(data, (int32_t)(frames * 2));
  return frames;
}

static void C_AudioSingle(int16_t left, int16_t right) {
  int16_t samples[2] = {left, right};
  AudioWrite(samples, 2);
}

static void C_InputPoll(void) {}

static int16_t C_InputState(unsigned port, unsigned /*device*/,
                              unsigned /*index*/, unsigned id) {
  if (port != 0 || id >= 64) return 0;
  return (gInputMask.load(std::memory_order_relaxed) >> id) & 1 ? 1 : 0;
}

static bool C_SetRumbleState(unsigned port, unsigned effect, uint16_t strength) {
  if (port != 0) return false;

  if (effect == _RETRO_RUMBLE_STRONG) {
    gRumbleStrong.store(strength, std::memory_order_release);
  } else if (effect == _RETRO_RUMBLE_WEAK) {
    gRumbleWeak.store(strength, std::memory_order_release);
  } else {
    return false;
  }

  if (strength > 0) {
    gRumbleSeq.fetch_add(1, std::memory_order_acq_rel);
  }
  return true;
}

static unsigned C_Environment(unsigned cmd, void* data) {
  if (cmd == _RETRO_ENV_SET_PIXEL_FORMAT) {
    if (data) {
      gPixelFormat.store(*(const int32_t*)data, std::memory_order_relaxed);
      return 1;
    }
    return 0;
  }
  if (cmd == _RETRO_ENV_GET_RUMBLE_INTERFACE) {
    if (data) {
      auto* rumble = static_cast<retro_rumble_interface*>(data);
      rumble->set_rumble_state = C_SetRumbleState;
      return 1;
    }
    return 0;
  }
  if (cmd == _RETRO_ENV_GET_SAVE_DIRECTORY) {
    if (data && gSaveDirBuf[0] != '\0') {
      *(const char**)data = gSaveDirBuf;
      return 1;
    }
    return 0;
  }
  if (cmd == _RETRO_ENV_GET_TARGET_SAMPLE_RATE) {
    if (data) {
      const unsigned rate = gTargetSampleRate.load(std::memory_order_relaxed);
      *static_cast<unsigned*>(data) = rate;
      AudioLog("GET_TARGET_SAMPLE_RATE -> %u Hz", rate);
      return 1;
    }
    return 0;
  }
  if (cmd == _RETRO_ENV_SET_SYSTEM_AV_INFO) {
    if (data) {
      const auto* info = static_cast<const retro_system_av_info*>(data);
      const double rate = info->timing.sample_rate;
      const double fps = info->timing.fps;
      if (rate > 0.0) {
        gReportedSampleRate.store(rate, std::memory_order_release);
      }
      AudioLog("SET_SYSTEM_AV_INFO: sample_rate=%.2f fps=%.4f", rate, fps);
      return 1;
    }
    return 0;
  }
  return 0;
}

// ── Public API ────────────────────────────────────────────────────────────
extern "C" {

emu_video_refresh_t  emulator_loop_video_cb(void)         { return C_VideoRefresh;  }
emu_audio_batch_t    emulator_loop_audio_batch_cb(void)   { return C_AudioBatch;    }
emu_audio_single_t   emulator_loop_audio_single_cb(void)  { return C_AudioSingle;   }
emu_input_poll_t     emulator_loop_input_poll_cb(void)    { return C_InputPoll;     }
emu_input_state_t    emulator_loop_input_state_cb(void)   { return C_InputState;    }
emu_environment_t    emulator_loop_environment_cb(void)   { return C_Environment;   }

void emulator_loop_set_pixel_format(int32_t format) {
  gPixelFormat.store(format, std::memory_order_relaxed);
}

void emulator_loop_set_input_bit(int32_t btn_id, bool pressed) {
  if (btn_id < 0 || btn_id >= 64) return;
  uint64_t mask = uint64_t(1) << btn_id;
  if (pressed) {
    gInputMask.fetch_or(mask,  std::memory_order_relaxed);
  } else {
    gInputMask.fetch_and(~mask, std::memory_order_relaxed);
  }
}

void emulator_loop_clear_inputs(void) {
  gInputMask.store(0, std::memory_order_relaxed);
}

int32_t emulator_loop_audio_available(void) {
  int32_t r = gAudioR.load(std::memory_order_acquire);
  int32_t w = gAudioW.load(std::memory_order_acquire);
  return (w - r + kAudioRing) % kAudioRing;
}

uint64_t emulator_loop_frame_count(void) {
  return gFrameCount.load(std::memory_order_relaxed);
}

uint64_t emulator_loop_rumble_sequence(void) {
  return gRumbleSeq.load(std::memory_order_acquire);
}

uint32_t emulator_loop_rumble_strong(void) {
  return gRumbleStrong.load(std::memory_order_acquire);
}

uint32_t emulator_loop_rumble_weak(void) {
  return gRumbleWeak.load(std::memory_order_acquire);
}

const uint8_t* emulator_loop_last_frame(int32_t* width_out, int32_t* height_out) {
  int32_t w = gLastW.load(std::memory_order_relaxed);
  int32_t h = gLastH.load(std::memory_order_relaxed);
  if (w <= 0 || h <= 0) return nullptr;
  if (width_out)  *width_out  = w;
  if (height_out) *height_out = h;
  return gConvBuf;
}

void emulator_loop_set_save_directory(const char* path) {
  if (path) {
    strncpy(gSaveDirBuf, path, sizeof(gSaveDirBuf) - 1);
    gSaveDirBuf[sizeof(gSaveDirBuf) - 1] = '\0';
  } else {
    gSaveDirBuf[0] = '\0';
  }
}

int32_t emulator_loop_audio_read(int16_t* out, int32_t max_samples) {
  int32_t avail = emulator_loop_audio_available();
  int32_t n = avail < max_samples ? avail : max_samples;
  int32_t r = gAudioR.load(std::memory_order_relaxed);
  for (int32_t i = 0; i < n; ++i) {
    out[i] = gAudioBuf[(r + i) % kAudioRing];
  }
  gAudioR.store((r + n) % kAudioRing, std::memory_order_release);
  return n;
}

void emulator_loop_audio_discard(int32_t sample_count) {
  if (sample_count <= 0) return;
  int32_t avail = emulator_loop_audio_available();
  int32_t n = avail < sample_count ? avail : sample_count;
  int32_t r = gAudioR.load(std::memory_order_relaxed);
  gAudioR.store((r + n) % kAudioRing, std::memory_order_release);
}

void emulator_loop_audio_flush(void) {
  gAudioR.store(0, std::memory_order_release);
  gAudioW.store(0, std::memory_order_release);
}

int32_t emulator_loop_audio_target_samples(void) {
  return gAudioTarget.load(std::memory_order_relaxed);
}

void emulator_loop_audio_set_target_samples(int32_t samples) {
  if (samples < 0) samples = 0;
  gAudioTarget.store(samples, std::memory_order_relaxed);
}

void emulator_loop_set_target_sample_rate(unsigned sample_rate) {
  if (sample_rate < 8000) {
    sample_rate = 48000;
  }
  gTargetSampleRate.store(sample_rate, std::memory_order_relaxed);
  gReportedSampleRate.store(static_cast<double>(sample_rate), std::memory_order_relaxed);
  AudioLog("set_target_sample_rate(%u)", sample_rate);
}

#if !defined(__APPLE__) || !TARGET_OS_IOS
double emulator_loop_prepare_audio_output_rate(double preferred_hz) {
  const unsigned rate =
      preferred_hz >= 8000.0 ? static_cast<unsigned>(preferred_hz + 0.5) : 48000u;
  emulator_loop_set_target_sample_rate(rate);
  AudioLog("prepare_audio_output_rate (non-iOS): %.0f", static_cast<double>(rate));
  return static_cast<double>(rate);
}
#endif

double emulator_loop_get_reported_sample_rate(void) {
  return gReportedSampleRate.load(std::memory_order_acquire);
}

} // extern "C"
