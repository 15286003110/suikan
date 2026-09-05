package com.suikan.app

/**
 * 随看 Android 系统媒体控制的动作桥（2026-09-05）。
 *
 * 前台服务通知 + 系统 MediaSession（耳机线控/蓝牙/车载）发出的动作统一经
 * 这里转发给 Dart 执行（不引入 androidx.media，避免构建/混淆风险）。
 */
object SuikanMediaActions {
    const val ACTION_PLAY = "com.suikan.app.ACTION_PLAY"
    const val ACTION_PAUSE = "com.suikan.app.ACTION_PAUSE"
    const val ACTION_TOGGLE = "com.suikan.app.ACTION_TOGGLE"
    const val ACTION_NEXT = "com.suikan.app.ACTION_NEXT"
    const val ACTION_PREV = "com.suikan.app.ACTION_PREV"

    @Volatile
    private var isPlaying: Boolean = false

    /** 前台服务（通知）是否在跑。由 BackgroundPlaybackService 自身维护：
     *  onStartCommand 置 true、onDestroy 置 false。用于 MainActivity 判断
     *  "服务在跑才需要重建通知兜底"，杜绝在服务未启动时反向拉起服务。 */
    @Volatile
    private var serviceActive: Boolean = false

    /** 由 MainActivity 注入：把命令转发给 Dart（play/pause/toggle/next/prev） */
    @Volatile
    var commandSink: ((String) -> Unit)? = null

    /** 由 MainActivity 注入：把进度拖动（秒）转发给 Dart */
    @Volatile
    var seekSink: ((Double) -> Unit)? = null

    @Synchronized
    fun setPlaying(playing: Boolean) {
        isPlaying = playing
    }

    @Synchronized
    fun isPlaying(): Boolean = isPlaying

    @Synchronized
    fun setServiceActive(active: Boolean) {
        serviceActive = active
    }

    @Synchronized
    fun isServiceActive(): Boolean = serviceActive

    fun dispatch(command: String) {
        commandSink?.invoke(command)
    }

    fun dispatchSeek(positionSec: Double) {
        seekSink?.invoke(positionSec)
    }
}
