package com.suikan.app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Notification
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.IBinder

/**
 * 后台播放前台服务（Android 唯一"媒体通知"来源）。
 *
 * ⚠️ 生命周期裁决权在 Dart（LiveRoomController/PlayerController）：
 *   "播放中 且（后台播放开关 或 纯音频开关）" → start；否则一律 stop。
 * 本服务【绝不】自行决定何时出现——原生任何地方不得在服务未启动时
 * 反向拉起它（历史缺陷：setPlaying 曾无条件 startService，导致两开关
 * 都关时前台播放/停播仍弹通知）。通知内容由绑定的 MediaSession 承载，
 * 系统随 playbackState/metadata 自动刷新，无需重建服务。
 *
 * 通知出现矩阵（业界媒体服务通用模型，与 media3/audio_service 对齐）：
 *   设置              playing   前台服务/通知
 *   后台播放开        播         在（退后台续播保活）
 *   后台播放开        停         停
 *   纯音频开          播         在（收进通知栏/锁屏听）
 *   两开关都关        播(前台)    无（App 内看，不打扰）
 *   两开关都关        —          无（退后台即暂停）
 */
class BackgroundPlaybackService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // START_STICKY 的系统空重启（内存回收后 intent 为 null）：此刻若
        // Dart 早已停播，绝不能弹通知——立即自停。媒体命令（用户点通知
        // 按钮）必然带 action，走下面的正常路径。
        if (intent?.action == null && !SuikanMediaActions.isPlaying()) {
            SuikanMediaActions.setServiceActive(false)
            stopSelf()
            return START_NOT_STICKY
        }
        when (intent?.action) {
            SuikanMediaActions.ACTION_PLAY -> SuikanMediaActions.dispatch("play")
            SuikanMediaActions.ACTION_PAUSE -> SuikanMediaActions.dispatch("pause")
            SuikanMediaActions.ACTION_TOGGLE -> SuikanMediaActions.dispatch("toggle")
            SuikanMediaActions.ACTION_NEXT -> SuikanMediaActions.dispatch("next")
            SuikanMediaActions.ACTION_PREV -> SuikanMediaActions.dispatch("prev")
        }
        SuikanMediaActions.setServiceActive(true)
        startForeground(NOTIFICATION_ID, buildNotification())
        return START_STICKY
    }

    override fun onDestroy() {
        super.onDestroy()
        SuikanMediaActions.setServiceActive(false)
    }

    private fun buildNotification(): Notification {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        // 绑定系统 MediaSession：标题/封面/进度/播放暂停切台按钮由系统据此渲染。
        val token = SuikanMediaSession.sessionToken()
        if (token != null) {
            builder.setStyle(Notification.MediaStyle().setMediaSession(token))
        } else {
            builder.setContentTitle("随看").setContentText("正在后台播放")
        }
        return builder
            .setSmallIcon(applicationInfo.icon)
            .setOngoing(true)
            .setShowWhen(false)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setContentIntent(
                PendingIntent.getActivity(
                    this,
                    0,
                    Intent(this, MainActivity::class.java).apply {
                        flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
                    },
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                ),
            )
            .build()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }
        val manager = getSystemService(NotificationManager::class.java)
        val channel = NotificationChannel(
            CHANNEL_ID,
            "后台播放",
            NotificationManager.IMPORTANCE_LOW,
        )
        channel.description = "直播后台播放保活"
        manager.createNotificationChannel(channel)
    }

    companion object {
        private const val CHANNEL_ID = "simple_live_background_playback"
        private const val NOTIFICATION_ID = 1001
    }
}
