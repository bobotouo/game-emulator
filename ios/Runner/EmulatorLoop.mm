// iOS emulation loop: GCD serial queue with QOS_CLASS_USER_INTERACTIVE and
// mach_wait_until for sub-millisecond frame timing. Completely independent
// of Flutter's rendering thread.

#include "emulator_loop.h"
#include "game_texture.h"

#import <Foundation/Foundation.h>
#include <mach/mach_time.h>
#include <atomic>

static dispatch_queue_t gEmuQueue = nil;
static std::atomic<bool> gRunning{false};
static std::atomic<bool> gPaused{false};
static std::atomic<int32_t> gSpeed{1};
static dispatch_semaphore_t gStopDone = nil;

namespace {
__attribute__((used)) const void* const kKeepDartFfiSymbols[] = {
    reinterpret_cast<const void*>(&emulator_loop_video_cb),
    reinterpret_cast<const void*>(&emulator_loop_audio_batch_cb),
    reinterpret_cast<const void*>(&emulator_loop_audio_single_cb),
    reinterpret_cast<const void*>(&emulator_loop_input_poll_cb),
    reinterpret_cast<const void*>(&emulator_loop_input_state_cb),
    reinterpret_cast<const void*>(&emulator_loop_environment_cb),
    reinterpret_cast<const void*>(&emulator_loop_set_pixel_format),
    reinterpret_cast<const void*>(&emulator_loop_start),
    reinterpret_cast<const void*>(&emulator_loop_stop),
    reinterpret_cast<const void*>(&emulator_loop_set_paused),
    reinterpret_cast<const void*>(&emulator_loop_set_speed),
    reinterpret_cast<const void*>(&emulator_loop_is_running),
    reinterpret_cast<const void*>(&emulator_loop_run_frames),
    reinterpret_cast<const void*>(&emulator_loop_advance_frame),
    reinterpret_cast<const void*>(&emulator_loop_core_lock),
    reinterpret_cast<const void*>(&emulator_loop_core_unlock),
    reinterpret_cast<const void*>(&emulator_loop_wait_until_stopped),
    reinterpret_cast<const void*>(&emulator_loop_set_input_bit),
    reinterpret_cast<const void*>(&emulator_loop_set_input_bit_for_port),
    reinterpret_cast<const void*>(&emulator_loop_set_port_input_mask),
    reinterpret_cast<const void*>(&emulator_loop_clear_inputs),
    reinterpret_cast<const void*>(&emulator_loop_audio_available),
    reinterpret_cast<const void*>(&emulator_loop_audio_read),
    reinterpret_cast<const void*>(&emulator_loop_audio_discard),
    reinterpret_cast<const void*>(&emulator_loop_audio_flush),
    reinterpret_cast<const void*>(&emulator_loop_audio_target_samples),
    reinterpret_cast<const void*>(&emulator_loop_audio_set_target_samples),
    reinterpret_cast<const void*>(&emulator_loop_set_target_sample_rate),
    reinterpret_cast<const void*>(&emulator_loop_get_reported_sample_rate),
    reinterpret_cast<const void*>(&emulator_loop_prepare_audio_output_rate),
    reinterpret_cast<const void*>(&emulator_loop_audio_start),
    reinterpret_cast<const void*>(&emulator_loop_audio_stop),
    reinterpret_cast<const void*>(&emulator_loop_audio_set_paused),
    reinterpret_cast<const void*>(&emulator_loop_audio_set_playback_speed),
    reinterpret_cast<const void*>(&emulator_loop_frame_count),
    reinterpret_cast<const void*>(&emulator_loop_rumble_sequence),
    reinterpret_cast<const void*>(&emulator_loop_rumble_strong),
    reinterpret_cast<const void*>(&emulator_loop_rumble_weak),
    reinterpret_cast<const void*>(&emulator_loop_set_save_directory),
    reinterpret_cast<const void*>(&emulator_loop_set_system_directory),
    reinterpret_cast<const void*>(&emulator_loop_set_content_directory),
    reinterpret_cast<const void*>(&emulator_loop_reset_controller_ports),
    reinterpret_cast<const void*>(&emulator_loop_get_controller_ports),
    reinterpret_cast<const void*>(&emulator_loop_set_present_to_texture),
    reinterpret_cast<const void*>(&emulator_loop_set_silent_frame_output),
    reinterpret_cast<const void*>(&emulator_loop_last_frame),
    reinterpret_cast<const void*>(&emulator_loop_last_frame_serial),
    reinterpret_cast<const void*>(&emulator_loop_reset_video_state),
    reinterpret_cast<const void*>(&emulator_loop_on_retro_frame_completed),
    reinterpret_cast<const void*>(&emulator_loop_netplay_begin),
    reinterpret_cast<const void*>(&emulator_loop_netplay_end),
    reinterpret_cast<const void*>(&emulator_loop_netplay_load_frame),
    reinterpret_cast<const void*>(&emulator_loop_netplay_sim_frame),
    reinterpret_cast<const void*>(&emulator_loop_netplay_set_sim_frame),
    reinterpret_cast<const void*>(&emulator_loop_set_gpsp_serial_mode),
    reinterpret_cast<const void*>(&emulator_loop_netpacket_available),
    reinterpret_cast<const void*>(&emulator_loop_netpacket_start),
    reinterpret_cast<const void*>(&emulator_loop_netpacket_stop),
    reinterpret_cast<const void*>(&emulator_loop_netpacket_connect),
    reinterpret_cast<const void*>(&emulator_loop_netpacket_disconnect),
    reinterpret_cast<const void*>(&emulator_loop_netpacket_read),
    reinterpret_cast<const void*>(&emulator_loop_netpacket_push),
    reinterpret_cast<const void*>(&game_texture_upload_rgba),
    reinterpret_cast<const void*>(&game_texture_ios_presented_frame_count),
};
}

extern "C" {

void emulator_loop_start(emu_retro_run_t retro_run, double fps) {
  if (!retro_run || fps <= 0.0) return;
  if (gRunning.exchange(true)) return;  // already running

  gPaused.store(false, std::memory_order_relaxed);

  dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(
      DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0);
  gEmuQueue = dispatch_queue_create("com.emulator.loop", attr);
  gStopDone = dispatch_semaphore_create(0);

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
          emulator_loop_advance_frame(retro_run);
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

    if (gStopDone != nil) {
      dispatch_semaphore_signal(gStopDone);
    }
    gEmuQueue = nil;
  });
}

void emulator_loop_stop(void) {
  if (!gRunning.exchange(false)) {
    return;
  }
  dispatch_semaphore_t sem = gStopDone;
  if (sem != nil) {
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
  }
}

bool emulator_loop_wait_until_stopped(void) {
  return !gRunning.load(std::memory_order_acquire);
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

  if (gEmuQueue != nil) {
    dispatch_sync(gEmuQueue, ^{
      for (uint32_t i = 0; i < count; ++i) {
        emulator_loop_advance_frame(retro_run);
      }
    });
    return;
  }
  for (uint32_t i = 0; i < count; ++i) {
    emulator_loop_advance_frame(retro_run);
  }
}

} // extern "C"
