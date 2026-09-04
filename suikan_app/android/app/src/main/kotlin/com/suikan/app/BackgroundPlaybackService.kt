package com.suikan.app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Notification
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.IBinder

class BackgroundPlaybackService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            SuikanMediaActions.ACTION_PLAY -> SuikanMediaActions.dispatch("play")
            SuikanMediaActions.ACTION_PAUSE -> SuikanMediaActions.dispatch("pause")
            SuikanMediaActions.ACTION_TOGGLE -> SuikanMediaActions.dispatch("toggle")
        }
        // 媒体样式：可见内容 + 播放/暂停按钮（点击后回到 onStartCommand）
        val style = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            Notification.MediaStyle()
        } else {
            null
        }
        val builder = buildNotificationBuilder()
        if (style != null) {
            builder.setStyle(style)
        }
        startForeground(NOTIFICATION_ID, builder.build())
        return START_STICKY
    }

    private fun buildNotificationBuilder(): Notification.Builder {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        builder
            .setSmallIcon(applicationInfo.icon)
            .setContentTitle("随看")
            .setContentText("正在后台播放")
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

        // 播放/暂停按钮：由 Dart 侧状态决定显示哪一个
        val playing = SuikanMediaActions.isPlaying()
        val actionCode = if (playing) 2 else 1
        val actionIntent = Intent(this, BackgroundPlaybackService::class.java).apply {
            action = if (playing) SuikanMediaActions.ACTION_PAUSE else SuikanMediaActions.ACTION_PLAY
        }
        builder.addAction(
            Notification.Action.Builder(
                android.R.drawable.ic_media_pause.takeIf { playing }
                    ?: android.R.drawable.ic_media_play,
                if (playing) "暂停" else "播放",
                PendingIntent.getService(
                    this,
                    actionCode,
                    actionIntent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                ),
            ).build(),
        )
        return builder
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
