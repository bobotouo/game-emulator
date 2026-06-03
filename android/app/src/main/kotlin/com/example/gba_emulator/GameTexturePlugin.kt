package com.example.gba_emulator

import android.view.Surface
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry

class GameTexturePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    companion object {
        @Volatile
        private var activeProducer: TextureRegistry.SurfaceProducer? = null
        @Volatile
        private var nativeLoaded = false

        @Synchronized
        private fun ensureNativeLoaded() {
            if (!nativeLoaded) {
                System.loadLibrary("game_texture")
                nativeLoaded = true
            }
        }

        @JvmStatic
        fun notifyFrame() {
            activeProducer?.scheduleFrame()
        }
    }
    private var channel: MethodChannel? = null
    private var textureRegistry: TextureRegistry? = null
    private val entries = mutableMapOf<Long, TextureRegistry.SurfaceProducer>()
    /** Texture id that currently owns the native ANativeWindow (global in C++). */
    private var surfaceOwnerId: Long? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        textureRegistry = binding.textureRegistry
        channel = MethodChannel(binding.binaryMessenger, "game_texture")
        channel?.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        for ((_, producer) in entries) {
            if (surfaceOwnerId != null) {
                nativeClearSurface()
                surfaceOwnerId = null
            }
            producer.release()
        }
        entries.clear()
        textureRegistry = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "createTexture" -> {
                val width = call.argument<Int>("width") ?: 0
                val height = call.argument<Int>("height") ?: 0
                if (width <= 0 || height <= 0) {
                    result.error("invalid_args", "width/height required", null)
                    return
                }
                val registry = textureRegistry
                if (registry == null) {
                    result.error("no_registry", "texture registry missing", null)
                    return
                }
                ensureNativeLoaded()
                val producer = registry.createSurfaceProducer()
                producer.setSize(width, height)
                val id = producer.id()
                producer.setCallback(
                    object : TextureRegistry.SurfaceProducer.Callback {
                        override fun onSurfaceAvailable() {
                            ensureNativeLoaded()
                            val surface: Surface? = producer.surface
                            nativeSetSurface(surface)
                            surfaceOwnerId = id
                        }

                        override fun onSurfaceDestroyed() {
                            if (surfaceOwnerId == id) {
                                nativeClearSurface()
                                surfaceOwnerId = null
                            }
                        }
                    },
                )
                entries[id] = producer
                activeProducer = producer
                val surface: Surface? = producer.surface
                if (surface != null) {
                    nativeSetSurface(surface)
                    surfaceOwnerId = id
                }
                result.success(id)
            }

            "disposeTexture" -> {
                val id = call.argument<Number>("textureId")?.toLong()
                if (id == null) {
                    result.error("invalid_args", "textureId required", null)
                    return
                }
                val producer = entries.remove(id)
                if (producer != null) {
                    if (surfaceOwnerId == id) {
                        nativeClearSurface()
                        surfaceOwnerId = null
                    }
                    producer.release()
                    if (activeProducer === producer) {
                        activeProducer = null
                    }
                }
                result.success(null)
            }

            else -> result.notImplemented()
        }
    }

    private external fun nativeSetSurface(surface: Surface?)

    private external fun nativeClearSurface()

}
