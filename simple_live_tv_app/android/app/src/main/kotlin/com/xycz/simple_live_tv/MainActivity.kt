package com.xycz.simple_live_tv

import android.content.Context
import android.content.res.Configuration
import android.media.AudioManager
import android.os.Build
import android.util.Log
import android.view.KeyEvent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private var appWindowChannel: MethodChannel? = null
    private var lastWindowState: Map<String, Any>? = null
    private var backChannel: MethodChannel? = null
    private var volumeChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // 【quickjs 修复】小米盒子 ROM 上 /data/app/.../lib/arm 为空(不解压 so),
        // System.loadLibrary 从 APK 内部加载 → Dart 的 DynamicLibrary.process() 查不到符号。
        // 方案: 把 so 从 APK 提取到 filesDir, 供 Dart 用绝对路径 dlopen (最可靠)。
        try {
            val dest = File(filesDir, "libquickjs.so")
            if (!dest.exists()) {
                val zip = java.util.zip.ZipFile(applicationInfo.sourceDir)
                val abi = if (Build.SUPPORTED_ABIS.any { it.startsWith("arm64") }) "arm64-v8a" else "armeabi-v7a"
                val entry = zip.getEntry("lib/$abi/libquickjs.so")
                if (entry != null) {
                    zip.getInputStream(entry).use { input ->
                        dest.outputStream().use { output -> input.copyTo(output) }
                    }
                    Log.d(TAG, "extracted libquickjs.so to ${dest.absolutePath}")
                } else {
                    Log.w(TAG, "no lib/$abi/libquickjs.so in APK")
                }
                zip.close()
            }
        } catch (e: Throwable) {
            Log.w(TAG, "extract libquickjs.so failed: $e")
        }
        // 兜底: 直接加载 (部分 ROM 的 nativeLibraryDir 有解压的 so)
        try {
            System.loadLibrary("quickjs")
            Log.d(TAG, "libquickjs.so loaded via System.loadLibrary")
        } catch (e: Throwable) {
            Log.w(TAG, "System.loadLibrary(quickjs) failed: $e")
        }
        appWindowChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            APP_WINDOW_CHANNEL,
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "finishAndRemoveTask" -> {
                        val finishing = try {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                                finishAndRemoveTask()
                            } else {
                                finish()
                            }
                            isFinishing
                        } catch (_: Throwable) {
                            false
                        }
                        result.success(finishing)
                    }

                    "getWindowState" -> result.success(buildWindowState())
                    else -> result.notImplemented()
                }
            }
        }
        // 【返回键拦截】PopScope 在 GetMaterialApp 根路由失效, 必须原生拦截
        backChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_BACK)
        // 【音量记忆】供 Flutter 读写系统音量 (USB/HDMI 输出都走 STREAM_MUSIC)
        volumeChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_VOLUME)
        volumeChannel?.setMethodCallHandler { call, result ->
            val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            when (call.method) {
                "getVolume" -> result.success(am.getStreamVolume(AudioManager.STREAM_MUSIC))
                "getMaxVolume" -> result.success(am.getStreamMaxVolume(AudioManager.STREAM_MUSIC))
                "setVolume" -> {
                    val v = (call.arguments as? Number)?.toInt() ?: -1
                    if (v >= 0) {
                        am.setStreamVolume(AudioManager.STREAM_MUSIC, v, 0)
                        Log.d(TAG, "setVolume: $v")
                    }
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
        emitWindowState(force = true)
    }

    override fun onResume() {
        super.onResume()
        emitWindowState()
    }

    override fun onBackPressed() {
        Log.d(TAG, "onBackPressed, send to Flutter")
        backChannel?.invokeMethod("backPressed", null)
        // 不调用 super，阻止 Activity 被 finish。退出由 Flutter 弹确认框后决定。
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        // 备用拦截：部分 TV/遥控器系统可能走 onKeyDown 而不是 onBackPressed。
        if (keyCode == KeyEvent.KEYCODE_BACK || keyCode == KeyEvent.KEYCODE_ESCAPE) {
            Log.d(TAG, "onKeyDown BACK, send to Flutter")
            backChannel?.invokeMethod("backPressed", null)
            return true
        }
        return super.onKeyDown(keyCode, event)
    }

    override fun onDestroy() {
        backChannel?.setMethodCallHandler(null)
        backChannel = null
        volumeChannel?.setMethodCallHandler(null)
        volumeChannel = null
        appWindowChannel?.setMethodCallHandler(null)
        appWindowChannel = null
        super.onDestroy()
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        emitWindowState()
    }

    override fun onMultiWindowModeChanged(isInMultiWindowMode: Boolean) {
        super.onMultiWindowModeChanged(isInMultiWindowMode)
        emitWindowState()
    }

    override fun onMultiWindowModeChanged(
        isInMultiWindowMode: Boolean,
        newConfig: Configuration,
    ) {
        super.onMultiWindowModeChanged(isInMultiWindowMode, newConfig)
        emitWindowState()
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode)
        emitWindowState()
    }

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration,
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        emitWindowState()
    }

    private fun emitWindowState(force: Boolean = false) {
        val channel = appWindowChannel ?: return
        val state = buildWindowState()
        if (!force && state == lastWindowState) {
            return
        }
        lastWindowState = state
        runOnUiThread {
            channel.invokeMethod("windowStateChanged", state)
        }
    }

    private fun buildWindowState(): Map<String, Any> {
        val inPip = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            isInPictureInPictureMode
        val inMultiWindow = Build.VERSION.SDK_INT >= Build.VERSION_CODES.N &&
            isInMultiWindowMode
        return mapOf(
            "inPip" to inPip,
            "inMultiWindow" to inMultiWindow,
            "isFreeform" to isFreeformWindow(inPip, inMultiWindow),
        )
    }

    private fun isFreeformWindow(inPip: Boolean, inMultiWindow: Boolean): Boolean {
        if (inPip) {
            return false
        }

        val reflectedMode = try {
            val windowConfiguration = resources.configuration.javaClass
                .getMethod("getWindowConfiguration")
                .invoke(resources.configuration)
            windowConfiguration?.javaClass
                ?.getMethod("getWindowingMode")
                ?.invoke(windowConfiguration) as? Int
        } catch (_: Throwable) {
            null
        }
        if (reflectedMode != null) {
            return reflectedMode == WINDOWING_MODE_FREEFORM
        }

        if (!inMultiWindow) {
            return false
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val current = windowManager.currentWindowMetrics.bounds
            val maximum = windowManager.maximumWindowMetrics.bounds
            return current.width() < maximum.width() &&
                current.height() < maximum.height()
        }
        return false
    }

    companion object {
        private const val APP_WINDOW_CHANNEL = "simple_live_tv/app_window"
        private const val WINDOWING_MODE_FREEFORM = 5
        private const val CHANNEL_BACK = "com.simplelive.tv/back"
        private const val CHANNEL_VOLUME = "com.simplelive.tv/volume"
        private const val TAG = "SimpleLiveTV"
    }
}
