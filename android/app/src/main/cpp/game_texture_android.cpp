#include "game_texture.h"

#include <android/log.h>
#include <android/native_window.h>
#include <android/native_window_jni.h>

#include <cstring>
#include <mutex>

#include <jni.h>

#define LOG_TAG "game_texture"
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

namespace {

JavaVM* g_vm = nullptr;
jclass g_plugin_class = nullptr;
jmethodID g_notify_frame = nullptr;

std::mutex g_mutex;
ANativeWindow* g_window = nullptr;
int g_width = 0;
int g_height = 0;

void NotifyFrameLocked() {
  if (g_vm == nullptr || g_plugin_class == nullptr || g_notify_frame == nullptr) {
    return;
  }
  JNIEnv* env = nullptr;
  if (g_vm->AttachCurrentThread(&env, nullptr) != JNI_OK || env == nullptr) {
    return;
  }
  env->CallStaticVoidMethod(g_plugin_class, g_notify_frame);
  if (env->ExceptionCheck()) {
    env->ExceptionClear();
  }
}

void ReleaseWindowLocked() {
  if (g_window != nullptr) {
    ANativeWindow_release(g_window);
    g_window = nullptr;
  }
  g_width = 0;
  g_height = 0;
}

}  // namespace

extern "C" {

void game_texture_android_set_window(ANativeWindow* window) {
  std::lock_guard<std::mutex> lock(g_mutex);
  ReleaseWindowLocked();
  g_window = window;
}

void game_texture_android_upload(const uint8_t* src, int32_t width, int32_t height,
                                 int32_t pitch_bytes) {
  if (src == nullptr || width <= 0 || height <= 0) {
    return;
  }

  std::lock_guard<std::mutex> lock(g_mutex);
  ANativeWindow* window = g_window;
  if (window == nullptr) {
    return;
  }

  if (g_width != width || g_height != height) {
    if (ANativeWindow_setBuffersGeometry(window, width, height,
                                         WINDOW_FORMAT_RGBA_8888) != 0) {
      LOGE("setBuffersGeometry failed");
      return;
    }
    g_width = width;
    g_height = height;
  }

  ANativeWindow_Buffer buffer{};
  if (ANativeWindow_lock(window, &buffer, nullptr) != 0) {
    LOGE("ANativeWindow_lock failed");
    return;
  }

  const int rowBytes = width * 4;
  auto* dst = static_cast<uint8_t*>(buffer.bits);
  const int dstStrideBytes = buffer.stride * 4;

  if (pitch_bytes == rowBytes && dstStrideBytes == rowBytes) {
    std::memcpy(dst, src, static_cast<size_t>(rowBytes) * height);
  } else {
    for (int y = 0; y < height; ++y) {
      std::memcpy(dst + y * dstStrideBytes, src + y * pitch_bytes, rowBytes);
    }
  }

  ANativeWindow_unlockAndPost(window);
  NotifyFrameLocked();
}

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM* vm, void* /*reserved*/) {
  g_vm = vm;
  JNIEnv* env = nullptr;
  if (vm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6) != JNI_OK) {
    return JNI_ERR;
  }
  jclass localClass = env->FindClass("com/example/gba_emulator/GameTexturePlugin");
  if (localClass == nullptr) {
    return JNI_ERR;
  }
  g_plugin_class = reinterpret_cast<jclass>(env->NewGlobalRef(localClass));
  env->DeleteLocalRef(localClass);
  g_notify_frame = env->GetStaticMethodID(g_plugin_class, "notifyFrame", "()V");
  return JNI_VERSION_1_6;
}

JNIEXPORT void JNICALL
Java_com_example_gba_1emulator_GameTexturePlugin_nativeSetSurface(JNIEnv* env,
                                                                  jobject /*thiz*/,
                                                                  jobject surface) {
  ANativeWindow* window = nullptr;
  if (surface != nullptr) {
    window = ANativeWindow_fromSurface(env, surface);
    if (window == nullptr) {
      LOGE("ANativeWindow_fromSurface returned null");
    }
  }
  game_texture_android_set_window(window);
}

JNIEXPORT void JNICALL
Java_com_example_gba_1emulator_GameTexturePlugin_nativeClearSurface(JNIEnv* /*env*/,
                                                                  jobject /*thiz*/) {
  game_texture_android_set_window(nullptr);
}

}  // extern "C"
