// Android emulation loop: dedicated pthread with clock_nanosleep(TIMER_ABSTIME).

#include "emulator_loop.h"

#include <pthread.h>
#include <time.h>
#include <atomic>

static std::atomic<bool> gRunning{false};
static std::atomic<bool> gPaused{false};
static std::atomic<int32_t> gSpeed{1};
static pthread_t gThread;
static emu_retro_run_t gRetroRun = nullptr;
static double gFps = 60.0;

static void* EmuThreadFn(void*) {
  const long periodNs = (long)(1e9 / gFps);

  struct timespec next;
  clock_gettime(CLOCK_MONOTONIC, &next);

  while (gRunning.load(std::memory_order_relaxed)) {
    if (!gPaused.load(std::memory_order_relaxed) && gRetroRun) {
      const int32_t speed = gSpeed.load(std::memory_order_relaxed);
      const int32_t runs = speed < 1 ? 1 : (speed > 5 ? 5 : speed);
      for (int32_t i = 0; i < runs; ++i) {
        gRetroRun();
      }
    }

    next.tv_nsec += periodNs;
    while (next.tv_nsec >= 1000000000L) {
      next.tv_nsec -= 1000000000L;
      next.tv_sec++;
    }

    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    bool behind = (now.tv_sec > next.tv_sec) ||
                  (now.tv_sec == next.tv_sec && now.tv_nsec > next.tv_nsec);
    if (behind) {
      clock_gettime(CLOCK_MONOTONIC, &next);  // resync when falling behind
    } else {
      clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &next, nullptr);
    }
  }
  return nullptr;
}

extern "C" {

void emulator_loop_start(emu_retro_run_t retro_run, double fps) {
  if (!retro_run || fps <= 0.0) return;
  if (gRunning.exchange(true)) return;

  gRetroRun = retro_run;
  gFps = fps;
  gPaused.store(false, std::memory_order_relaxed);

  pthread_attr_t attr;
  pthread_attr_init(&attr);
  pthread_create(&gThread, &attr, EmuThreadFn, nullptr);
  pthread_attr_destroy(&attr);
}

void emulator_loop_stop(void) {
  if (!gRunning.exchange(false)) return;
  pthread_join(gThread, nullptr);
  gRetroRun = nullptr;
}

void emulator_loop_set_paused(bool paused) {
  gPaused.store(paused, std::memory_order_relaxed);
}

void emulator_loop_set_speed(int32_t speed) {
  if (speed < 1) speed = 1;
  if (speed > 5) speed = 5;
  gSpeed.store(speed, std::memory_order_relaxed);
}

bool emulator_loop_is_running(void) {
  return gRunning.load(std::memory_order_relaxed);
}

void emulator_loop_run_frames(emu_retro_run_t retro_run, uint32_t count) {
  if (!retro_run || count == 0) return;
  if (gRunning.load(std::memory_order_relaxed)) return;

  for (uint32_t i = 0; i < count; ++i) {
    retro_run();
  }
}

double emulator_loop_prepare_audio_output_rate(double preferred_hz) {
  const unsigned rate =
      preferred_hz >= 8000.0 ? static_cast<unsigned>(preferred_hz + 0.5) : 48000u;
  emulator_loop_set_target_sample_rate(rate);
  return static_cast<double>(rate);
}

void emulator_loop_audio_start(double /*sample_rate*/) {}
void emulator_loop_audio_stop(void) {}
void emulator_loop_audio_set_paused(bool /*paused*/) {}
void emulator_loop_audio_set_playback_speed(int32_t /*speed*/) {}

} // extern "C"
