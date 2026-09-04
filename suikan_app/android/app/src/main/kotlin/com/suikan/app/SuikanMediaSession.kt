package com.suikan.app

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaMetadata
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Handler
import android.os.Looper
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * 随看 Android 系统媒体会话（2026-09-05）。
 *
 * 用系统自带的 android.media.session.MediaSession（API 21+，零新增依赖）实现：
 * - 耳机线控 / 蓝牙 / 车载控制（onPlay/onPause/onSkipToNext/onSkipToPrevious/onSeekTo）
 * - 锁屏 / 系统媒体界面 / 通知栏的标题、主播、封面、直播标记、影视进度
 *
 * 前台服务通知通过 MediaStyle().setMediaSession(token) 绑定本会话，系统据此
 * 自动渲染媒体通知（封面 + 进度 + 播放/暂停/切台按钮），无需手动 addAction。
 */
object SuikanMediaSession {

    private var session: MediaSession? = null
    private var executor: ExecutorService? = null

    private val coverCache = HashMap<String, Bitmap>()

    @Volatile
    private var curTitle: String = ""

    @Volatile
    private var curArtist: String = ""

    @Volatile
    private var isLive: Boolean = true

    @Volatile
    private var durationMs: Long = 0

    @Volatile
    private var canNext: Boolean = false

    @Volatile
    private var canPrev: Boolean = false

    /** 确保会话已创建（MainActivity 首次接入时调用）。 */
    @Synchronized
    @Suppress("DEPRECATION")
    fun ensure(context: Context) {
        if (session != null) return
        session = MediaSession(context, "SuikanMediaSession").apply {
            setCallback(object : MediaSession.Callback() {
                override fun onPlay() = SuikanMediaActions.dispatch("play")
                override fun onPause() = SuikanMediaActions.dispatch("pause")
                override fun onSkipToNext() = SuikanMediaActions.dispatch("next")
                override fun onSkipToPrevious() = SuikanMediaActions.dispatch("prev")
                override fun onSeekTo(pos: Long) =
                    SuikanMediaActions.dispatchSeek(pos / 1000.0)
            })
            isActive = true
        }
        executor = Executors.newSingleThreadExecutor()
    }

    fun sessionToken(): MediaSession.Token? = session?.sessionToken

    fun update(
        title: String,
        artist: String,
        isLive: Boolean,
        coverUrl: String?,
        durationSec: Double?,
        positionSec: Double?,
        canNext: Boolean,
        canPrev: Boolean,
    ) {
        val s = session ?: return
        curTitle = title
        curArtist = artist
        this.isLive = isLive
        this.durationMs =
            if (!isLive && durationSec != null) (durationSec * 1000).toLong() else 0
        this.canNext = canNext
        this.canPrev = canPrev

        val b = MediaMetadata.Builder()
            .putString(MediaMetadata.METADATA_KEY_TITLE, title)
            .putString(MediaMetadata.METADATA_KEY_ARTIST, artist)
        if (this.durationMs > 0) {
            b.putLong(MediaMetadata.METADATA_KEY_DURATION, this.durationMs)
        }
        if (!coverUrl.isNullOrEmpty()) {
            val cached = coverCache[coverUrl]
            if (cached != null) {
                b.putBitmap(MediaMetadata.METADATA_KEY_ART, cached)
            } else {
                loadArtwork(coverUrl, title)
            }
        }
        s.setMetadata(b.build())
        applyPlaybackState(positionSec)
    }

    fun setPlaying(playing: Boolean, positionSec: Double?) {
        if (session == null) return
        applyPlaybackState(positionSec)
    }

    fun setPosition(positionSec: Double) {
        if (session == null) return
        applyPlaybackState(positionSec)
    }

    fun clear() {
        val s = session ?: return
        s.setMetadata(MediaMetadata.Builder().build())
        s.setPlaybackState(PlaybackState.Builder().setActions(0).build())
        curTitle = ""
    }

    fun release() {
        executor?.shutdown()
        executor = null
        session?.isActive = false
        session?.release()
        session = null
        synchronized(coverCache) { coverCache.clear() }
    }

    // MARK: - 内部

    private fun applyPlaybackState(positionSec: Double?) {
        val s = session ?: return
        val playing = SuikanMediaActions.isPlaying()
        var actions = PlaybackState.ACTION_PLAY or
            PlaybackState.ACTION_PAUSE or
            PlaybackState.ACTION_PLAY_PAUSE or
            PlaybackState.ACTION_STOP
        if (canNext) actions = actions or PlaybackState.ACTION_SKIP_TO_NEXT
        if (canPrev) actions = actions or PlaybackState.ACTION_SKIP_TO_PREVIOUS
        if (!isLive && durationMs > 0) {
            actions = actions or PlaybackState.ACTION_SEEK_TO
        }
        val posMs = ((positionSec ?: 0.0) * 1000).toLong()
        val state = PlaybackState.Builder()
            .setActions(actions)
            .setState(
                if (playing) PlaybackState.STATE_PLAYING else PlaybackState.STATE_PAUSED,
                posMs,
                if (playing) 1.0f else 0.0f,
            )
            .build()
        s.setPlaybackState(state)
    }

    private fun loadArtwork(url: String, title: String) {
        executor?.execute {
            try {
                val conn = URL(url).openConnection() as HttpURLConnection
                conn.connectTimeout = 8000
                conn.readTimeout = 8000
                conn.instanceFollowRedirects = true
                conn.connect()
                if (conn.responseCode != 200) {
                    conn.disconnect()
                    return@execute
                }
                val bmp = BitmapFactory.decodeStream(conn.inputStream)
                conn.disconnect()
                if (bmp == null) return@execute
                synchronized(coverCache) { coverCache[url] = bmp }
                Handler(Looper.getMainLooper()).post {
                    if (curTitle == title) {
                        rebuildMetadataWithArtwork(bmp)
                    }
                }
            } catch (_: Exception) {
                // 封面下载失败不致命，静默忽略
            }
        }
    }

    private fun rebuildMetadataWithArtwork(bmp: Bitmap) {
        val s = session ?: return
        val b = MediaMetadata.Builder()
            .putString(MediaMetadata.METADATA_KEY_TITLE, curTitle)
            .putString(MediaMetadata.METADATA_KEY_ARTIST, curArtist)
            .putBitmap(MediaMetadata.METADATA_KEY_ART, bmp)
        if (durationMs > 0) {
            b.putLong(MediaMetadata.METADATA_KEY_DURATION, durationMs)
        }
        s.setMetadata(b.build())
    }
}
