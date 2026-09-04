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
            SuikanMediaActions.ACTION_NEXT -> SuikanMediaActions.dispatch("next")
            SuikanMediaActions.ACTION_PREV -> SuikanMediaActions.dispatch("prev")
        }
        startForeground(NOTIFICATION_ID, buildNotification())
        return START_STICKY
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
