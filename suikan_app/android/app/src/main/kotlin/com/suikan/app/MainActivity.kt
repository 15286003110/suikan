package com.suikan.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.Context
import android.content.res.Configuration
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.net.wifi.WifiManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var appWindowChannel: MethodChannel? = null
    private var lastWindowState: Map<String, Any>? = null
    private var multicastLock: WifiManager.MulticastLock? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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
        emitWindowState(force = true)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "simple_live/background_playback",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    startService()
                    result.success(null)
                }

                "stop" -> {
                    stopService(Intent(this, BackgroundPlaybackService::class.java))
                    result.success(null)
                }

                else -> result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "simple_live/live_notifications",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "showLiveStart" -> {
                    showLiveStartNotification(
                        notificationId = call.argument<Int>("notificationId") ?: 1002,
                        title = call.argument<String>("title") ?: "特别关注开播了",
                        body = call.argument<String>("body") ?: "点击回到 随看",
                    )
                    result.success(null)
                }

                else -> result.notImplemented()
            }
        }

        // 局域网发现(同步/投屏)共用的组播锁通道。
        // Android 必须持有 WifiManager.MulticastLock 才能收到 UDP 广播,
        // 否则内核会过滤多播包,导致"其它端互看正常、手机看不到别人"。
        val multicastHandler = MethodChannel.MethodCallHandler { call, result ->
            when (call.method) {
                "acquireMulticastLock" -> {
                    acquireMulticastLock()
                    result.success(null)
                }

                "releaseMulticastLock" -> {
                    releaseMulticastLock()
                    result.success(null)
                }

                else -> result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "simple_live/dlna",
        ).setMethodCallHandler(multicastHandler)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "simple_live/discovery",
        ).setMethodCallHandler(multicastHandler)
        // 音频焦点：来电/导航/其它媒体时通知 Dart 避让，结束后恢复
        setupAudioFocus(flutterEngine)
        setupMediaControl(flutterEngine)
    }

    override fun onResume() {
        super.onResume()
        emitWindowState()
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
            "isFreeform" to isFreeformWindow(inPip),
        )
    }

    private fun isFreeformWindow(inPip: Boolean): Boolean {
        if (inPip) {
            return false
        }

        // Configuration.windowConfiguration is hidden from the public SDK, but
        // OEMs that implement freeform windows expose its standard getter.
        // Use it when available and retain a public-API bounds fallback below.
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
        if (reflectedMode == WINDOWING_MODE_FREEFORM) {
            // WindowConfiguration.WINDOWING_MODE_FREEFORM is 5.
            return true
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val current = windowManager.currentWindowMetrics.bounds
            val maximum = windowManager.maximumWindowMetrics.bounds
            // Some OEM "small window" implementations do not expose the
            // standard freeform mode (and occasionally do not set
            // isInMultiWindowMode), but their task is constrained on both
            // axes. Keep the threshold below normal system-bar/cutout insets
            // while recognising a genuinely floating task.
            val constrainedOnBothAxes =
                current.width() * 100 < maximum.width() * 95 &&
                    current.height() * 100 < maximum.height() * 95
            return constrainedOnBothAxes
        }
        return false
    }

    private fun acquireMulticastLock() {
        try {
            val wifi =
                applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
            if (wifi != null) {
                multicastLock = wifi.createMulticastLock("suikan_dlna").also {
                    it.setReferenceCounted(false)
                    it.acquire()
                }
            }
        } catch (_: Throwable) {
            // 忽略：缺少权限或系统不支持时不影响主流程
        }
    }

    private fun releaseMulticastLock() {
        try {
            multicastLock?.release()
        } catch (_: Throwable) {
            // 忽略
        }
        multicastLock = null
    }

    private fun startService() {
        val intent = Intent(this, BackgroundPlaybackService::class.java)
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    private fun showLiveStartNotification(notificationId: Int, title: String, body: String) {
        val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        createLiveStartNotificationChannel(manager)
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, LIVE_START_CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        val notification = builder
            .setSmallIcon(applicationInfo.icon)
            .setContentTitle(title)
            .setContentText(body)
            .setAutoCancel(true)
            .setShowWhen(true)
            .setContentIntent(
                PendingIntent.getActivity(
                    this,
                    notificationId,
                    Intent(this, MainActivity::class.java).apply {
                        flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
                    },
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                ),
            )
            .build()
        manager.notify(notificationId, notification)
    }

    private fun createLiveStartNotificationChannel(manager: NotificationManager) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }
        val channel = NotificationChannel(
            LIVE_START_CHANNEL_ID,
            "开播提醒",
            NotificationManager.IMPORTANCE_DEFAULT,
        )
        channel.description = "特别关注主播开播提醒"
        manager.createNotificationChannel(channel)
    }

    companion object {
        private const val APP_WINDOW_CHANNEL = "simple_live/app_window"
        private const val AUDIO_FOCUS_CHANNEL = "suikan/audio"
        private const val MEDIA_CHANNEL = "suikan/media"
        private const val LIVE_START_CHANNEL_ID = "simple_live_live_start"
        private const val WINDOWING_MODE_FREEFORM = 5
    }

    // MARK: - 音频焦点（来电/导航/其它 App 播放时避让，结束后恢复）

    private var audioManager: AudioManager? = null
    private var audioFocusChannel: MethodChannel? = null
    private var audioFocusRequest: Any? = null
    private var hasAudioFocus = false

    private val focusChangeListener = AudioManager.OnAudioFocusChangeListener { change ->
        when (change) {
            AudioManager.AUDIOFOCUS_LOSS,
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> {
                hasAudioFocus = false
                audioFocusChannel?.invokeMethod("onAudioFocusLost", null)
            }
            AudioManager.AUDIOFOCUS_GAIN -> {
                hasAudioFocus = true
                audioFocusChannel?.invokeMethod("onAudioFocusGained", null)
            }
        }
    }

    private fun setupAudioFocus(flutterEngine: FlutterEngine) {
        audioManager = getSystemService(Context.AUDIO_SERVICE) as? AudioManager
        audioFocusChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            AUDIO_FOCUS_CHANNEL,
        )
        audioFocusChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "requestFocus" -> result.success(requestAudioFocus())
                "abandonFocus" -> {
                    abandonAudioFocus()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    // MARK: - 系统媒体控制（通知栏播放/暂停，零新增依赖）

    private fun setupMediaControl(flutterEngine: FlutterEngine) {
        SuikanMediaSession.ensure(this)
        val channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            MEDIA_CHANNEL,
        )
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "update" -> {
                    SuikanMediaSession.update(
                        title = call.argument<String>("title") ?: "随看",
                        artist = call.argument<String>("artist") ?: "",
                        isLive = call.argument<Boolean>("isLive") ?: true,
                        coverUrl = call.argument<String>("coverUrl"),
                        durationSec = call.argument<Double>("duration"),
                        positionSec = call.argument<Double>("position"),
                        canNext = call.argument<Boolean>("canNext") ?: false,
                        canPrev = call.argument<Boolean>("canPrev") ?: false,
                    )
                    result.success(null)
                }
                "setPlaying" -> {
                    val playing = call.argument<Boolean>("playing") ?: false
                    val changed = playing != SuikanMediaActions.isPlaying()
                    SuikanMediaActions.setPlaying(playing)
                    SuikanMediaSession.setPlaying(
                        playing,
                        call.argument<Double>("position"),
                    )
                    // 状态变化时重建通知（MediaSession 会自动更新，这里兜底刷新）
                    if (changed) {
                        val intent = Intent(this, BackgroundPlaybackService::class.java)
                        startService(intent)
                    }
                    result.success(null)
                }
                "setPosition" -> {
                    SuikanMediaSession.setPosition(
                        call.argument<Double>("position") ?: 0.0,
                    )
                    result.success(null)
                }
                "clear" -> {
                    SuikanMediaSession.clear()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        // 通知/按钮/线控命令 → Dart
        SuikanMediaActions.commandSink = { command ->
            runOnUiThread {
                channel.invokeMethod("onCommand", command)
            }
        }
        SuikanMediaActions.seekSink = { positionSec ->
            runOnUiThread {
                channel.invokeMethod(
                    "onCommand",
                    mapOf("command" to "seek", "position" to positionSec),
                )
            }
        }
    }

    private fun requestAudioFocus(): Boolean {
        val manager = audioManager ?: return false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setOnAudioFocusChangeListener(focusChangeListener)
                .build()
            audioFocusRequest = request
            val res = manager.requestAudioFocus(request)
            hasAudioFocus = res == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
            return hasAudioFocus
        }
        @Suppress("DEPRECATION")
        val res = manager.requestAudioFocus(
            focusChangeListener,
            AudioManager.STREAM_MUSIC,
            AudioManager.AUDIOFOCUS_GAIN,
        )
        hasAudioFocus = res == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        return hasAudioFocus
    }

    private fun abandonAudioFocus() {
        val manager = audioManager ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            (audioFocusRequest as? AudioFocusRequest)?.let {
                @Suppress("DEPRECATION")
                manager.abandonAudioFocusRequest(it)
            }
        } else {
            @Suppress("DEPRECATION")
            manager.abandonAudioFocus(focusChangeListener)
        }
        audioFocusRequest = null
        hasAudioFocus = false
    }
}
