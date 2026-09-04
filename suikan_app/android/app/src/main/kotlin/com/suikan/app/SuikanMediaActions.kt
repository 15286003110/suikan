package com.suikan.app

/**
 * 随看 Android 系统媒体控制的动作桥（2026-09-05）。
 *
 * 背景：media_kit 不内置系统媒体控制，通知栏只有静态文本、不能暂停。
 * 这里用**零新增依赖**的做法：前台服务通知加「播放 / 暂停」按钮，
 * 点击后经 Service.onStartCommand → 本单例回调 → MainActivity 的 MethodChannel
 * 把命令转给 Dart 执行（不引入 androidx.media，避免构建/混淆风险）。
 *
 * 注：完整 MediaSession（耳机线控 / 蓝牙 / 车载）需要 androidx.media:media，
 * 属于后续可选增强；当前方案覆盖"通知栏可见 + 可暂停"。
 */
object SuikanMediaActions {
    const val ACTION_PLAY = "com.suikan.app.ACTION_PLAY"
    const val ACTION_PAUSE = "com.suikan.app.ACTION_PAUSE"
    const val ACTION_TOGGLE = "com.suikan.app.ACTION_TOGGLE"

    @Volatile
    private var isPlaying: Boolean = false

    /** 由 MainActivity 注入：把命令转发给 Dart */
    @Volatile
    var commandSink: ((String) -> Unit)? = null

    @Synchronized
    fun setPlaying(playing: Boolean) {
        isPlaying = playing
    }

    @Synchronized
    fun isPlaying(): Boolean = isPlaying

    fun dispatch(command: String) {
        commandSink?.invoke(command)
    }
}
