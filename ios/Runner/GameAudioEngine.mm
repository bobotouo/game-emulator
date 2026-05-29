// AudioUnit + linear float resample (core Hz -> device Hz). No partial-buffer silence.

#include "emulator_loop.h"

#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>

#include <atomic>
#include <cstdarg>
#include <cstdio>
#include <cmath>
#include <cstring>

namespace {

AudioUnit gOutputUnit = nullptr;
std::atomic<bool> gRunning{false};
std::atomic<bool> gPaused{false};

double gCoreRate = 32768.0;
double gOutputRate = 48000.0;
double gPhase = 0.0;

int16_t gLastL = 0;
int16_t gLastR = 0;

static const int32_t kPullCap = 16384;
int16_t gPull[kPullCap];

int32_t gPrebufferSamples = 0;
bool gNonInterleaved = false;

std::atomic<uint64_t> gRenderCallbacks{0};
std::atomic<uint64_t> gShortOutput{0};

// Headroom against GBA/mGBA hot samples (reduces 破音).
static constexpr float kOutputGain = 0.78f;
static constexpr float kOutputCeiling = 0.92f;

static void AudioLog(const char* fmt, ...) {
  char buf[512];
  va_list args;
  va_start(args, fmt);
  vsnprintf(buf, sizeof(buf), fmt, args);
  va_end(args);
  std::fprintf(stderr, "[GBA-Audio] %s\n", buf);
  std::fflush(stderr);
  NSLog(@"[GBA-Audio] %s", buf);
}

static inline float I16ToFloat(int16_t s) {
  return static_cast<float>(s) * (1.0f / 32768.0f);
}

static inline float SoftLimit(float x) {
  x *= kOutputGain;
  if (x > kOutputCeiling) {
    return kOutputCeiling;
  }
  if (x < -kOutputCeiling) {
    return -kOutputCeiling;
  }
  return x;
}

static void TrimRingIfVeryFull(void) {
  const int32_t target = emulator_loop_audio_target_samples();
  if (target <= 0) {
    return;
  }
  const int32_t avail = emulator_loop_audio_available();
  if (avail > target * 2) {
    emulator_loop_audio_discard(avail - target);
  }
}

static void WriteSilence(AudioBufferList* ioData, UInt32 frameCount) {
  if (ioData == nullptr || frameCount == 0) {
    return;
  }
  if (gNonInterleaved && ioData->mNumberBuffers >= 2) {
    for (UInt32 ch = 0; ch < 2; ++ch) {
      AudioBuffer& buf = ioData->mBuffers[ch];
      if (buf.mData != nullptr) {
        std::memset(buf.mData, 0, buf.mDataByteSize);
      }
    }
    return;
  }
  if (ioData->mNumberBuffers >= 1 && ioData->mBuffers[0].mData != nullptr) {
    std::memset(ioData->mBuffers[0].mData, 0, ioData->mBuffers[0].mDataByteSize);
  }
}

static void WriteOutputSample(AudioBufferList* ioData, UInt32 index, float l, float r) {
  l = SoftLimit(l);
  r = SoftLimit(r);
  if (gNonInterleaved && ioData->mNumberBuffers >= 2) {
    float* outL = reinterpret_cast<float*>(ioData->mBuffers[0].mData);
    float* outR = reinterpret_cast<float*>(ioData->mBuffers[1].mData);
    if (outL != nullptr) {
      outL[index] = l;
    }
    if (outR != nullptr) {
      outR[index] = r;
    }
    return;
  }
  if (ioData->mNumberBuffers < 1) {
    return;
  }
  float* interleaved = reinterpret_cast<float*>(ioData->mBuffers[0].mData);
  if (interleaved == nullptr) {
    return;
  }
  interleaved[index * 2] = l;
  interleaved[index * 2 + 1] = r;
}

static UInt32 ClampFrameCount(AudioBufferList* ioData, UInt32 frameCount) {
  if (ioData == nullptr || frameCount == 0) {
    return 0;
  }
  if (gNonInterleaved && ioData->mNumberBuffers >= 2) {
    const UInt32 capL = ioData->mBuffers[0].mDataByteSize / sizeof(float);
    const UInt32 capR = ioData->mBuffers[1].mDataByteSize / sizeof(float);
    const UInt32 cap = capL < capR ? capL : capR;
    return frameCount < cap ? frameCount : cap;
  }
  if (ioData->mNumberBuffers < 1 || ioData->mBuffers[0].mData == nullptr) {
    return 0;
  }
  const UInt32 cap = ioData->mBuffers[0].mDataByteSize / (sizeof(float) * 2);
  return frameCount < cap ? frameCount : cap;
}

static OSStatus RenderCallback(void* /*inRefCon*/,
                             AudioUnitRenderActionFlags* /*ioActionFlags*/,
                             const AudioTimeStamp* /*inTimeStamp*/,
                             UInt32 /*inBusNumber*/,
                             UInt32 inNumberFrames,
                             AudioBufferList* ioData) {
  if (ioData == nullptr || !gRunning.load(std::memory_order_acquire)) {
    return noErr;
  }

  const UInt32 frames = ClampFrameCount(ioData, inNumberFrames);
  if (frames == 0) {
    return noErr;
  }

  if (gPaused.load(std::memory_order_relaxed)) {
    WriteSilence(ioData, frames);
    return noErr;
  }

  const int32_t prebuffer = gPrebufferSamples;
  if (prebuffer > 0) {
    const int32_t avail = emulator_loop_audio_available();
    if (avail < prebuffer) {
      WriteSilence(ioData, frames);
      return noErr;
    }
    gPrebufferSamples = 0;
    AudioLog("prebuffer done: avail=%d", avail);
  }

  TrimRingIfVeryFull();

  const double coreRate = gCoreRate;
  const double outRate = gOutputRate;
  if (coreRate <= 0.0 || outRate <= 0.0) {
    WriteSilence(ioData, frames);
    return noErr;
  }

  // mGBA already resampled to [coreRate] via GET_TARGET_SAMPLE_RATE — 1:1 to device.
  if (std::fabs(coreRate - outRate) < 1.0) {
    const int32_t needSamples = static_cast<int32_t>(frames) * 2;
    const int32_t maxRead = needSamples < kPullCap ? needSamples : kPullCap;
    const int32_t read = emulator_loop_audio_read(gPull, maxRead);

    for (UInt32 i = 0; i < frames; ++i) {
      if (static_cast<int32_t>(i * 2 + 1) < read) {
        gLastL = gPull[i * 2];
        gLastR = gPull[i * 2 + 1];
      }
      WriteOutputSample(ioData, i, I16ToFloat(gLastL), I16ToFloat(gLastR));
    }

    const uint64_t cb = gRenderCallbacks.fetch_add(1, std::memory_order_relaxed) + 1;
    if (cb == 1 || (cb % 200) == 0) {
      AudioLog("render #%llu: passthrough out=%u read=%d ring=%d (mGBA resampled)",
               (unsigned long long)cb, frames, read, emulator_loop_audio_available());
    }
    return noErr;
  }

  const double step = coreRate / outRate;
  const int32_t endCoreFrame =
      static_cast<int32_t>(gPhase + static_cast<double>(frames) * step) + 3;
  const int32_t needSamples = endCoreFrame * 2;

  if (needSamples > kPullCap) {
    for (UInt32 i = 0; i < frames; ++i) {
      WriteOutputSample(ioData, i, I16ToFloat(gLastL), I16ToFloat(gLastR));
    }
    return noErr;
  }

  const int32_t read = emulator_loop_audio_read(gPull, needSamples);
  const int32_t pullFrames = read / 2;

  for (UInt32 i = 0; i < frames; ++i) {
    const double pos = gPhase + static_cast<double>(i) * step;
    const int32_t i0 = static_cast<int32_t>(pos);
    const float t = static_cast<float>(pos - static_cast<double>(i0));

    int16_t l0 = gLastL;
    int16_t r0 = gLastR;
    int16_t l1 = gLastL;
    int16_t r1 = gLastR;

    if (i0 >= 0 && i0 < pullFrames) {
      l0 = gPull[i0 * 2];
      r0 = gPull[i0 * 2 + 1];
      l1 = l0;
      r1 = r0;
      if (i0 + 1 < pullFrames) {
        l1 = gPull[(i0 + 1) * 2];
        r1 = gPull[(i0 + 1) * 2 + 1];
      }
    }

    const float l = (1.f - t) * I16ToFloat(l0) + t * I16ToFloat(l1);
    const float r = (1.f - t) * I16ToFloat(r0) + t * I16ToFloat(r1);
    gLastL = l1;
    gLastR = r1;
    WriteOutputSample(ioData, i, l, r);
  }

  gPhase += static_cast<double>(frames) * step;
  const int32_t consumed = static_cast<int32_t>(gPhase);
  if (consumed > 0) {
    gPhase -= static_cast<double>(consumed);
  }

  const uint64_t cb = gRenderCallbacks.fetch_add(1, std::memory_order_relaxed) + 1;
  if (cb == 1 || (cb % 200) == 0) {
    AudioLog("render #%llu: ios_resample out=%u pull=%d ring=%d (rates %.0f->%.0f)",
             (unsigned long long)cb, frames, pullFrames, emulator_loop_audio_available(),
             coreRate, outRate);
  }

  return noErr;
}

static bool SetupOutputUnit(double sampleRate) {
  AudioComponentDescription desc{};
  desc.componentType = kAudioUnitType_Output;
  desc.componentSubType = kAudioUnitSubType_RemoteIO;
  desc.componentManufacturer = kAudioUnitManufacturer_Apple;

  AudioComponent component = AudioComponentFindNext(nullptr, &desc);
  if (component == nullptr) {
    return false;
  }

  OSStatus status = AudioComponentInstanceNew(component, &gOutputUnit);
  if (status != noErr || gOutputUnit == nullptr) {
    return false;
  }

  UInt32 flag = 1;
  status = AudioUnitSetProperty(gOutputUnit, kAudioOutputUnitProperty_EnableIO,
                                kAudioUnitScope_Output, 0, &flag, sizeof(flag));
  if (status != noErr) {
    return false;
  }

  AudioStreamBasicDescription asbd{};
  asbd.mSampleRate = sampleRate;
  asbd.mFormatID = kAudioFormatLinearPCM;
  asbd.mFormatFlags =
      kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian;
  asbd.mBytesPerPacket = 8;
  asbd.mFramesPerPacket = 1;
  asbd.mBytesPerFrame = 8;
  asbd.mChannelsPerFrame = 2;
  asbd.mBitsPerChannel = 32;

  status = AudioUnitSetProperty(gOutputUnit, kAudioUnitProperty_StreamFormat,
                                kAudioUnitScope_Input, 0, &asbd, sizeof(asbd));
  if (status != noErr) {
    return false;
  }

  AURenderCallbackStruct cb{};
  cb.inputProc = RenderCallback;
  status = AudioUnitSetProperty(gOutputUnit, kAudioUnitProperty_SetRenderCallback,
                                kAudioUnitScope_Input, 0, &cb, sizeof(cb));
  if (status != noErr) {
    return false;
  }

  status = AudioUnitInitialize(gOutputUnit);
  if (status != noErr) {
    return false;
  }

  UInt32 formatSize = sizeof(AudioStreamBasicDescription);
  AudioStreamBasicDescription actual{};
  status = AudioUnitGetProperty(gOutputUnit, kAudioUnitProperty_StreamFormat,
                                kAudioUnitScope_Input, 0, &actual, &formatSize);
  gNonInterleaved = (status == noErr) &&
                      ((actual.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0);
  return true;
}

static void TeardownOutputUnit(void) {
  if (gOutputUnit == nullptr) {
    return;
  }
  AudioOutputUnitStop(gOutputUnit);
  AudioUnitUninitialize(gOutputUnit);
  AudioComponentInstanceDispose(gOutputUnit);
  gOutputUnit = nullptr;
}

static void RunOnMainSync(void (^block)(void)) {
  if ([NSThread isMainThread]) {
    block();
  } else {
    dispatch_sync(dispatch_get_main_queue(), block);
  }
}

}  // namespace

extern "C" {

double emulator_loop_prepare_audio_output_rate(double preferred_hz) {
  if (preferred_hz < 8000.0) {
    preferred_hz = 48000.0;
  }

  __block double actual = preferred_hz;
  RunOnMainSync(^{
    @autoreleasepool {
      NSError* error = nil;
      AVAudioSession* session = [AVAudioSession sharedInstance];
      [session setCategory:AVAudioSessionCategoryPlayback
                       mode:AVAudioSessionModeDefault
                    options:0
                      error:&error];
      [session setPreferredIOBufferDuration:0.010 error:&error];
      [session setPreferredSampleRate:preferred_hz error:&error];
      [session setActive:YES error:&error];
      actual = session.sampleRate > 0 ? session.sampleRate : preferred_hz;
      AudioLog("prepare session: preferred=%.0f actual=%.0f", preferred_hz, actual);
    }
  });

  return actual;
}

void emulator_loop_audio_start(double sample_rate) {
  if (gRunning.load(std::memory_order_acquire)) {
    return;
  }

  emulator_loop_audio_flush();

  const double reported = emulator_loop_get_reported_sample_rate();
  // Playback rate = what we asked mGBA to produce (GET_TARGET_SAMPLE_RATE at load).
  gCoreRate = sample_rate > 0.0 ? sample_rate : (reported > 0.0 ? reported : 48000.0);
  if (reported > 0.0 && std::fabs(reported - gCoreRate) > 1.0) {
    AudioLog("warning: reported=%.0f != playback=%.0f", reported, gCoreRate);
  }

  const int32_t target = static_cast<int32_t>(gCoreRate * 0.12) * 2;
  emulator_loop_audio_set_target_samples(target);
  gPrebufferSamples = static_cast<int32_t>(gCoreRate * 0.05) * 2;
  gPhase = 0.0;
  gLastL = 0;
  gLastR = 0;
  gRenderCallbacks.store(0, std::memory_order_relaxed);
  gShortOutput.store(0, std::memory_order_relaxed);
  AudioLog("audio_start: pcm_rate=%.0f target_pcm=%d gain=%.2f (expect mGBA==device)",
           gCoreRate, target, kOutputGain);

  dispatch_async(dispatch_get_main_queue(), ^{
    @autoreleasepool {
      NSError* error = nil;
      AVAudioSession* session = [AVAudioSession sharedInstance];
      [session setCategory:AVAudioSessionCategoryPlayback
                       mode:AVAudioSessionModeDefault
                    options:0
                      error:&error];
      [session setPreferredIOBufferDuration:0.010 error:&error];
      [session setActive:YES error:&error];

      const double deviceRate = session.sampleRate > 0 ? session.sampleRate : 48000.0;
      gOutputRate = deviceRate;

      if (!SetupOutputUnit(deviceRate)) {
        return;
      }

      const int passthrough = std::fabs(gCoreRate - deviceRate) < 1.0 ? 1 : 0;
      AudioLog("AudioUnit: device=%.0f pcm=%.0f passthrough=%d (1=mGBA-only resample)",
               deviceRate, gCoreRate, passthrough);

      const OSStatus startStatus = AudioOutputUnitStart(gOutputUnit);
      if (startStatus != noErr) {
        TeardownOutputUnit();
        return;
      }
      gRunning.store(true, std::memory_order_release);
    }
  });
}

void emulator_loop_audio_stop(void) {
  gRunning.store(false, std::memory_order_release);
  gPaused.store(false, std::memory_order_relaxed);
  gPrebufferSamples = 0;
  gPhase = 0.0;

  dispatch_async(dispatch_get_main_queue(), ^{
    @autoreleasepool {
      TeardownOutputUnit();
      emulator_loop_audio_flush();
    }
  });
}

void emulator_loop_audio_set_paused(bool paused) {
  gPaused.store(paused, std::memory_order_relaxed);
}

void emulator_loop_audio_set_playback_speed(int32_t speed) {
  (void)speed;
}

}  // extern "C"
