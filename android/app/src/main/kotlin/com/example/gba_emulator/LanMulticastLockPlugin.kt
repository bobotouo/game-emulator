package com.example.gba_emulator

import android.content.Context
import android.net.wifi.WifiManager
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class LanMulticastLockHandler(private val context: Context) {
    private var multicastLock: WifiManager.MulticastLock? = null

    fun acquire() {
        if (multicastLock?.isHeld == true) {
            return
        }
        val wifi = context.applicationContext.getSystemService(Context.WIFI_SERVICE)
            as? WifiManager ?: return
        multicastLock = wifi.createMulticastLock("gba_netplay").apply {
            setReferenceCounted(false)
            acquire()
        }
    }

    fun release() {
        multicastLock?.let {
            if (it.isHeld) {
                it.release()
            }
        }
        multicastLock = null
    }
}

fun registerLanMulticastLockChannel(flutterEngine: FlutterEngine, context: Context) {
    val handler = LanMulticastLockHandler(context)
    MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "lan_multicast_lock")
        .setMethodCallHandler { call, result ->
            when (call.method) {
                "acquire" -> {
                    handler.acquire()
                    result.success(null)
                }
                "release" -> {
                    handler.release()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
}
