#include "emulator_loop.h"
#include "game_texture.h"

#include <atomic>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <climits>
#include <mutex>

#if defined(__ANDROID__)
#include <android/log.h>
#endif

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
#define _RETRO_ENV_GET_SYSTEM_DIRECTORY 9
#define _RETRO_ENV_GET_CONTENT_DIRECTORY 2
#define _RETRO_ENV_SET_SYSTEM_AV_INFO  14
#define _RETRO_ENV_GET_TARGET_SAMPLE_RATE 67
#define _RETRO_ENV_SET_CONTROLLER_INFO 35
#define _RETRO_ENV_GET_INPUT_BITMASKS 51
#define _RETRO_ENV_SET_MESSAGE 6
#define _RETRO_ENV_GET_LOG_INTERFACE 27

#define RETRO_DEVICE_ID_JOYPAD_MASK 256

struct retro_message {
  const char* msg;
  unsigned frames;
};

typedef void (*retro_log_printf_t)(unsigned level, const char* fmt, ...);

struct retro_log_callback {
  retro_log_printf_t log;
};

struct retro_controller_description {
  const char* desc;
  unsigned id;
};

struct retro_controller_info {
  const retro_controller_description* types;
  unsigned num_types;
};

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

// ── Libretro directories ────────────────────────────────────────────────────
static char gSaveDirBuf[4096] = {0};
static char gSystemDirBuf[4096] = {0};
static char gContentDirBuf[4096] = {0};

// ── Audio ring buffer (lock-free SPSC) ────────────────────────────────────
static const int32_t kAudioRing = 49152;  // int16 samples (~0.5s at 48 kHz stereo)
static int16_t gAudioBuf[kAudioRing];
static std::atomic<int32_t> gAudioR{0};
static std::atomic<int32_t> gAudioW{0};
static std::atomic<int32_t> gAudioTarget{0};
static std::atomic<unsigned> gTargetSampleRate{48000};
static std::atomic<double> gReportedSampleRate{48000.0};
static std::atomic<unsigned> gControllerPortCount{0};

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

// ── Input bitmask (per libretro port, up to 4 players) ───────────────────
static std::atomic<uint64_t> gInputMaskByPort[4] = {};

// ── Frame counter ─────────────────────────────────────────────────────────
static std::atomic<uint64_t> gFrameCount{0};

static std::mutex gCoreMutex;

// ── Rumble state ──────────────────────────────────────────────────────────
static std::atomic<uint32_t> gRumbleStrong{0};
static std::atomic<uint32_t> gRumbleWeak{0};
static std::atomic<uint64_t> gRumbleSeq{0};

typedef bool (*retro_set_rumble_state_t)(unsigned port, unsigned effect,
                                         uint16_t strength);

struct retro_rumble_interface {
  retro_set_rumble_state_t set_rumble_state;
};

// Thumbnail / no-texture fallback and Android texture upload buffer.
// Some arcade cores can report frames larger than handheld defaults.
static uint8_t gConvBuf[1024 * 1024 * 4];
static std::atomic<int32_t> gLastW{0};
static std::atomic<int32_t> gLastH{0};
static std::atomic<uint64_t> gFrameSerial{0};
static std::atomic<bool> gPresentToTexture{true};
static std::atomic<bool> gSilentFrameOutput{false};
static std::atomic<bool> gLoggedFirstVideoFrame{false};

static const char* LogLevelName(unsigned level) {
  switch (level) {
    case 0: return "DEBUG";
    case 1: return "INFO";
    case 2: return "WARN";
    case 3: return "ERROR";
    default: return "LOG";
  }
}

static void LibretroLog(unsigned level, const char* fmt, ...) {
  if (fmt == nullptr) return;
  va_list args;
  va_start(args, fmt);
#if defined(__ANDROID__)
  const int priority = level >= 3 ? ANDROID_LOG_ERROR :
                       level == 2 ? ANDROID_LOG_WARN :
                       ANDROID_LOG_INFO;
  __android_log_vprint(priority, "FBNeo", fmt, args);
#else
  std::fprintf(stderr, "[FBNeo %s] ", LogLevelName(level));
  std::vfprintf(stderr, fmt, args);
  std::fflush(stderr);
#endif
  va_end(args);
}

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

#if defined(__APPLE__) && TARGET_OS_IOS
static bool PresentConvBufToIOSurface(int32_t w, int32_t h) {
  if (w <= 0 || h <= 0) return false;
  uint8_t* dst = nullptr;
  int32_t dstPitch = 0;
  int32_t texW = 0;
  int32_t texH = 0;
  if (!game_texture_ios_lock_back_buffer(&dst, &dstPitch, &texW, &texH)) {
    return false;
  }
  if (texW < w || texH < h) {
    game_texture_ios_cancel_back_buffer_lock();
    return false;
  }
  const int32_t rowBytes = w * 4;
  for (int32_t y = 0; y < h; ++y) {
    std::memcpy(dst + y * dstPitch, gConvBuf + y * rowBytes, rowBytes);
  }
  if (texW > w) {
    const uint8_t pad[4] = {0, 0, 0, 255};
    for (int32_t y = 0; y < h; ++y) {
      uint8_t* row = dst + y * dstPitch;
      for (int32_t x = w; x < texW; ++x) {
        std::memcpy(row + x * 4, pad, 4);
      }
    }
  }
  if (texH > h) {
    const uint8_t pad[4] = {0, 0, 0, 255};
    for (int32_t y = h; y < texH; ++y) {
      uint8_t* row = dst + y * dstPitch;
      for (int32_t x = 0; x < texW; ++x) {
        std::memcpy(row + x * 4, pad, 4);
      }
    }
  }
  game_texture_ios_commit_back_buffer();
  return true;
}
#endif

static void C_VideoRefresh(const void* data, unsigned width, unsigned height, size_t pitch) {
  if (!data || !width || !height) return;
  if (gSilentFrameOutput.load(std::memory_order_relaxed)) return;

  const uint8_t* src = static_cast<const uint8_t*>(data);
  const int32_t w = (int32_t)width;
  const int32_t h = (int32_t)height;
  const int32_t srcPitch = (int32_t)pitch;
  const int fmt = gPixelFormat.load(std::memory_order_relaxed);

  if (w <= 0 || h <= 0 || w > 4096 || h > 4096) return;
  const int64_t requiredBytes = (int64_t)w * (int64_t)h * 4;
  if (requiredBytes <= 0 || requiredBytes > (int64_t)sizeof(gConvBuf)) {
    gLastW.store(0, std::memory_order_relaxed);
    gLastH.store(0, std::memory_order_relaxed);
    return;
  }

  if (fmt == EMU_PIXEL_FORMAT_XRGB8888) {
    ConvertXrgb8888ToRgba(src, gConvBuf, w, h, srcPitch);
  } else if (fmt == EMU_PIXEL_FORMAT_RGB565) {
    ConvertRgb565(src, gConvBuf, w, h, srcPitch);
  } else {
    Convert0rgb1555(src, gConvBuf, w, h, srcPitch);
  }

  if (!gLoggedFirstVideoFrame.exchange(true, std::memory_order_relaxed)) {
    LibretroLog(
      1,
      "first video frame: %dx%d pitch=%d format=%d bytes=%lld\n",
      w,
      h,
      srcPitch,
      fmt,
      (long long)requiredBytes
    );
  }

  gLastW.store(w, std::memory_order_relaxed);
  gLastH.store(h, std::memory_order_relaxed);
  gFrameSerial.fetch_add(1, std::memory_order_relaxed);

#if defined(__APPLE__) && TARGET_OS_IOS
  if (gPresentToTexture.load(std::memory_order_relaxed)) {
    if (PresentToIOSurface(src, w, h, srcPitch, fmt) ||
        PresentConvBufToIOSurface(w, h)) {
      gFrameCount.fetch_add(1, std::memory_order_relaxed);
      return;
    }
  }
#else
  if (gPresentToTexture.load(std::memory_order_relaxed)) {
    game_texture_upload_rgba(gConvBuf, w, h, w * 4);
  }
#endif
  gFrameCount.fetch_add(1, std::memory_order_relaxed);
}

static size_t C_AudioBatch(const int16_t* data, size_t frames) {
  if (gSilentFrameOutput.load(std::memory_order_relaxed)) return frames;
  static std::atomic<bool> gLoggedFirstBatch{false};
  if (!gLoggedFirstBatch.exchange(true)) {
    AudioLog("first audio_batch: frames=%zu (stereo pairs)", frames);
  }
  AudioWrite(data, (int32_t)(frames * 2));
  return frames;
}

static void C_AudioSingle(int16_t left, int16_t right) {
  if (gSilentFrameOutput.load(std::memory_order_relaxed)) return;
  int16_t samples[2] = {left, right};
  AudioWrite(samples, 2);
}

static void C_InputPoll(void) {}

static int16_t C_InputState(unsigned port, unsigned /*device*/,
                              unsigned /*index*/, unsigned id) {
  if (port >= 4) return 0;

  const uint64_t mask = gInputMaskByPort[port].load(std::memory_order_relaxed);

  if (id == RETRO_DEVICE_ID_JOYPAD_MASK) {
    return static_cast<int16_t>(mask & 0xFFFF);
  }

  if (id >= 64) return 0;
  return ((mask >> id) & 1) ? 1 : 0;
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
  if (cmd == _RETRO_ENV_SET_MESSAGE) {
    if (data) {
      const auto* message = static_cast<const retro_message*>(data);
      if (message->msg != nullptr) {
        LibretroLog(1, "message: %s\n", message->msg);
      }
      return 1;
    }
    return 0;
  }
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
  if (cmd == _RETRO_ENV_GET_SYSTEM_DIRECTORY) {
    if (data && gSystemDirBuf[0] != '\0') {
      *(const char**)data = gSystemDirBuf;
      return 1;
    }
    return 0;
  }
  if (cmd == _RETRO_ENV_GET_CONTENT_DIRECTORY) {
    if (data && gContentDirBuf[0] != '\0') {
      *(const char**)data = gContentDirBuf;
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
  if (cmd == _RETRO_ENV_SET_CONTROLLER_INFO) {
    if (data) {
      const auto* ports = static_cast<const retro_controller_info*>(data);
      unsigned count = 0;
      while (ports[count].types != nullptr) {
        count++;
      }
      if (count > 0) {
        gControllerPortCount.store(count, std::memory_order_release);
      }
      return 1;
    }
    return 0;
  }
  if (cmd == _RETRO_ENV_GET_INPUT_BITMASKS) {
    return 1;
  }
  if (cmd == _RETRO_ENV_GET_LOG_INTERFACE) {
    if (data) {
      auto* callback = static_cast<retro_log_callback*>(data);
      callback->log = LibretroLog;
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
  emulator_loop_set_input_bit_for_port(0, btn_id, pressed);
}

void emulator_loop_set_input_bit_for_port(unsigned port, int32_t btn_id,
                                          bool pressed) {
  if (port >= 4 || btn_id < 0 || btn_id >= 64) return;
  const uint64_t mask = uint64_t(1) << btn_id;
  if (pressed) {
    gInputMaskByPort[port].fetch_or(mask, std::memory_order_relaxed);
  } else {
    gInputMaskByPort[port].fetch_and(~mask, std::memory_order_relaxed);
  }
}

void emulator_loop_set_port_input_mask(unsigned port, uint64_t mask) {
  if (port >= 4) return;
  gInputMaskByPort[port].store(mask, std::memory_order_relaxed);
}

void emulator_loop_clear_inputs(void) {
  for (unsigned port = 0; port < 4; ++port) {
    gInputMaskByPort[port].store(0, std::memory_order_relaxed);
  }
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

void emulator_loop_set_present_to_texture(bool enable) {
  gPresentToTexture.store(enable, std::memory_order_release);
}

void emulator_loop_set_silent_frame_output(bool enable) {
  gSilentFrameOutput.store(enable, std::memory_order_release);
}

const uint8_t* emulator_loop_last_frame(int32_t* width_out, int32_t* height_out) {
  int32_t w = gLastW.load(std::memory_order_relaxed);
  int32_t h = gLastH.load(std::memory_order_relaxed);
  if (w <= 0 || h <= 0) return nullptr;
  if (width_out)  *width_out  = w;
  if (height_out) *height_out = h;
  return gConvBuf;
}

uint64_t emulator_loop_last_frame_serial(void) {
  return gFrameSerial.load(std::memory_order_acquire);
}

void emulator_loop_reset_video_state(void) {
  gLastW.store(0, std::memory_order_relaxed);
  gLastH.store(0, std::memory_order_relaxed);
  gFrameSerial.store(0, std::memory_order_relaxed);
  gLoggedFirstVideoFrame.store(false, std::memory_order_relaxed);
}

void emulator_loop_set_save_directory(const char* path) {
  if (path) {
    strncpy(gSaveDirBuf, path, sizeof(gSaveDirBuf) - 1);
    gSaveDirBuf[sizeof(gSaveDirBuf) - 1] = '\0';
  } else {
    gSaveDirBuf[0] = '\0';
  }
}

void emulator_loop_set_system_directory(const char* path) {
  if (path) {
    strncpy(gSystemDirBuf, path, sizeof(gSystemDirBuf) - 1);
    gSystemDirBuf[sizeof(gSystemDirBuf) - 1] = '\0';
  } else {
    gSystemDirBuf[0] = '\0';
  }
}

void emulator_loop_set_content_directory(const char* path) {
  if (path) {
    strncpy(gContentDirBuf, path, sizeof(gContentDirBuf) - 1);
    gContentDirBuf[sizeof(gContentDirBuf) - 1] = '\0';
  } else {
    gContentDirBuf[0] = '\0';
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

void emulator_loop_reset_controller_ports(void) {
  gControllerPortCount.store(0, std::memory_order_release);
}

unsigned emulator_loop_get_controller_ports(void) {
  return gControllerPortCount.load(std::memory_order_acquire);
}

// ── Netplay snapshot ring (retro_run thread only) ─────────────────────────

static std::atomic<bool> gNetplayActive{false};
static emu_snapshot_fn gNetplaySerialize = nullptr;
static emu_restore_fn gNetplayRestore = nullptr;
static size_t gNetplaySnapSize = 0;
static int32_t gNetplaySnapDepth = 8;
static uint8_t** gNetplaySnapBufs = nullptr;
static uint64_t* gNetplaySnapTags = nullptr;
static std::atomic<uint64_t> gNetplaySimFrame{0};

static void NetplayFreeRing(void) {
  if (gNetplaySnapBufs != nullptr) {
    for (int32_t i = 0; i < gNetplaySnapDepth; ++i) {
      std::free(gNetplaySnapBufs[i]);
    }
    std::free(gNetplaySnapBufs);
    gNetplaySnapBufs = nullptr;
  }
  if (gNetplaySnapTags != nullptr) {
    std::free(gNetplaySnapTags);
    gNetplaySnapTags = nullptr;
  }
}

static void NetplaySaveStartOfFrame(uint64_t frameTag) {
  if (!gNetplayActive.load(std::memory_order_relaxed) || !gNetplaySerialize ||
      gNetplaySnapBufs == nullptr || gNetplaySnapSize == 0 || gNetplaySnapDepth <= 0) {
    return;
  }
  const int32_t slot =
      (int32_t)(frameTag % static_cast<uint64_t>(gNetplaySnapDepth));
  if (gNetplaySerialize(gNetplaySnapBufs[slot], gNetplaySnapSize)) {
    gNetplaySnapTags[slot] = frameTag;
  }
}

void emulator_loop_on_retro_frame_completed(void) {
  if (!gNetplayActive.load(std::memory_order_relaxed)) {
    return;
  }
  const uint64_t completed =
      gNetplaySimFrame.load(std::memory_order_relaxed);
  NetplaySaveStartOfFrame(completed + 1);
  gNetplaySimFrame.store(completed + 1, std::memory_order_relaxed);
}

void emulator_loop_advance_frame(emu_retro_run_t retro_run) {
  if (!retro_run) {
    return;
  }
  std::lock_guard<std::mutex> lock(gCoreMutex);
  retro_run();
  emulator_loop_on_retro_frame_completed();
}

void emulator_loop_core_lock(void) {
  gCoreMutex.lock();
}

void emulator_loop_core_unlock(void) {
  gCoreMutex.unlock();
}

void emulator_loop_netplay_begin(emu_snapshot_fn serialize, emu_restore_fn restore,
                                 size_t state_size, int32_t max_frames) {
  emulator_loop_netplay_end();
  if (!serialize || !restore || state_size == 0 || max_frames <= 0) {
    return;
  }
  gNetplaySerialize = serialize;
  gNetplayRestore = restore;
  gNetplaySnapSize = state_size;
  gNetplaySnapDepth = max_frames;
  gNetplaySnapBufs =
      static_cast<uint8_t**>(std::calloc(static_cast<size_t>(max_frames), sizeof(uint8_t*)));
  gNetplaySnapTags =
      static_cast<uint64_t*>(std::calloc(static_cast<size_t>(max_frames), sizeof(uint64_t)));
  if (!gNetplaySnapBufs || !gNetplaySnapTags) {
    NetplayFreeRing();
    return;
  }
  for (int32_t i = 0; i < max_frames; ++i) {
    gNetplaySnapBufs[i] = static_cast<uint8_t*>(std::malloc(state_size));
    gNetplaySnapTags[i] = UINT64_MAX;
    if (!gNetplaySnapBufs[i]) {
      NetplayFreeRing();
      return;
    }
  }
  gNetplayActive.store(true, std::memory_order_release);
  gNetplaySimFrame.store(0, std::memory_order_relaxed);
  NetplaySaveStartOfFrame(0);
}

void emulator_loop_netplay_end(void) {
  gNetplayActive.store(false, std::memory_order_release);
  gNetplaySerialize = nullptr;
  gNetplayRestore = nullptr;
  gNetplaySnapSize = 0;
  gNetplaySnapDepth = 8;
  NetplayFreeRing();
}

bool emulator_loop_netplay_load_frame(uint64_t frame) {
  std::lock_guard<std::mutex> lock(gCoreMutex);
  if (!gNetplayActive.load(std::memory_order_relaxed) || !gNetplayRestore ||
      gNetplaySnapBufs == nullptr || gNetplaySnapDepth <= 0) {
    return false;
  }
  const int32_t slot =
      (int32_t)(frame % static_cast<uint64_t>(gNetplaySnapDepth));
  if (gNetplaySnapTags[slot] != frame) {
    return false;
  }
  return gNetplayRestore(gNetplaySnapBufs[slot], gNetplaySnapSize);
}

uint64_t emulator_loop_netplay_sim_frame(void) {
  return gNetplaySimFrame.load(std::memory_order_acquire);
}

void emulator_loop_netplay_set_sim_frame(uint64_t frame) {
  gNetplaySimFrame.store(frame, std::memory_order_relaxed);
}

} // extern "C"
