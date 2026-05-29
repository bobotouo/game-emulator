// iOS emulation loop: GCD serial queue with QOS_CLASS_USER_INTERACTIVE and
// mach_wait_until for sub-millisecond frame timing. Completely independent
// of Flutter's rendering thread.

#include "emulator_loop.h"

#import <Foundation/Foundation.h>
#include <mach/mach_time.h>
#include <atomic>

static dispatch_queue_t gEmuQueue = nil;
static std::atomic<bool> gRunning{false};
static std::atomic<bool> gPaused{false};
static std::atomic<int32_t> gSpeed{1};

extern "C" {

void emulator_loop_start(emu_retro_run_t retro_run, double fps) {
  if (!retro_run || fps <= 0.0) return;
  if (gRunning.exchange(true)) return;  // already running

  gPaused.store(false, std::memory_order_relaxed);

  dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(
      DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0);
  gEmuQueue = dispatch_queue_create("com.emulator.loop", attr);

  dispatch_async(gEmuQueue, ^{
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);

    // Convert nanoseconds → mach ticks.
    // mach_ticks = ns * denom / numer
    const uint64_t frameNs = (uint64_t)(1e9 / fps);
    const uint64_t frameTicks = frameNs * tb.denom / tb.numer;

    uint64_t nextTick = mach_absolute_time();

    while (gRunning.load(std::memory_order_relaxed)) {
      if (!gPaused.load(std::memory_order_relaxed)) {
        const int32_t speed = gSpeed.load(std::memory_order_relaxed);
        const int32_t runs = speed < 1 ? 1 : (speed > 5 ? 5 : speed);
        for (int32_t i = 0; i < runs; ++i) {
          retro_run();
        }
      }

      nextTick += frameTicks;
      const uint64_t now = mach_absolute_time();
      if (nextTick > now) {
        mach_wait_until(nextTick);
      } else {
        // Behind schedule: do NOT burst retro_run (floods audio ring). Slip one frame.
        nextTick = now + frameTicks;
      }
    }

    gEmuQueue = nil;
  });
}

void emulator_loop_stop(void) {
  gRunning.store(false, std::memory_order_relaxed);
  // The loop will exit at the next iteration; no need to join.
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

  dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
  dispatch_sync(q, ^{
    for (uint32_t i = 0; i < count; ++i) {
      retro_run();
    }
  });
}

} // extern "C"
