package com.suikan.tvbox

import android.content.Context
import android.net.wifi.WifiManager
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.net.DatagramPacket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.MulticastSocket

/**
 * DLNA/UPnP 接收端的原生 SSDP 通道。
 *
 * 背景：盒子系统自带投屏服务已占用 UDP 1900（IPv4+IPv6 多个 socket），
 * Dart 层 RawDatagramSocket 无法再 bind 1900（端口独占）。
 * Linux 组播语义下，多个 socket 可 join 同一组播组同一端口（内核向所有
 * 组成员复制组播包），因此用原生 MulticastSocket + reuseAddress 与系统服务共存。
 *
 * Dart → 原生：start / stop / send(ip, port, data)
 * 原生 → Dart：onSearch(st, ip, port)（收到投屏端 M-SEARCH）
 */
class DlnaReceiverChannel(
    private val flutterEngine: FlutterEngine,
    private val context: Context,
) {
    private var channel: MethodChannel? = null
    private var socket: MulticastSocket? = null
    private var thread: Thread? = null
    private var running = false
    private var lock: WifiManager.MulticastLock? = null

    fun register() {
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        channel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    startSocket()
                    result.success(true)
                }

                "stop" -> {
                    stopSocket()
                    result.success(true)
                }

                "send" -> {
                    val ip = call.argument<String>("ip") ?: ""
                    val port = call.argument<Int>("port") ?: 1900
                    val data = call.argument<String>("data") ?: ""
                    // MethodChannel handler 跑在主线程，UDP 发送必须移到工作线程
                    // （Android 8+ 主线程网络操作直接抛 NetworkOnMainThreadException）
                    Thread {
                        send(ip, port, data)
                    }.start()
                    result.success(true)
                }

                else -> result.notImplemented()
            }
        }
    }

    fun unregister() {
        stopSocket()
        channel?.setMethodCallHandler(null)
        channel = null
    }

    private fun startSocket() {
        stopSocket()
        running = true
        thread = Thread {
            var sock: MulticastSocket? = null
            try {
                // 注意：MulticastSocket() 无参构造会隐式 bind 随机端口（Java 行为），
                // 再 bind 1900 会报 EINVAL。必须用 MulticastSocket(null)（不 bind），
                // 先设 reuseAddress（在 bind 前生效）再 bind 1900，与系统 DLNA 共享端口。
                sock = MulticastSocket(null)
                sock!!.reuseAddress = true
                sock!!.timeToLive = 4
                sock!!.bind(InetSocketAddress(1900))
                sock!!.joinGroup(InetAddress.getByName(MULTICAST_ADDR))
                socket = sock
                acquireLock()
                Log.d(TAG, "DLNA receiver up on udp/1900 (shared)")
                val buf = ByteArray(65536)
                while (running) {
                    try {
                        val p = DatagramPacket(buf, buf.size)
                        sock!!.receive(p)
                        val data = String(p.data, 0, p.length, Charsets.UTF_8)
                        if (data.contains("M-SEARCH")) {
                            val st = header(data, "ST")
                            if (st != null) {
                                val ip = p.address.hostAddress ?: ""
                                val port = p.port
                                Handler(Looper.getMainLooper()).post {
                                    channel?.invokeMethod(
                                        "onSearch",
                                        mapOf(
                                            "st" to st,
                                            "ip" to ip,
                                            "port" to port,
                                        ),
                                    )
                                }
                            }
                        }
                    } catch (e: Exception) {
                        if (running) {
                            Log.w(TAG, "DLNA recv: $e")
                        }
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "DLNA socket start failed: $e")
                running = false
                // 上报失败（如 1900 被系统服务独占且无法共享），Dart 侧回退开关并提示
                Handler(Looper.getMainLooper()).post {
                    channel?.invokeMethod(
                        "onError",
                        mapOf("message" to (e.message ?: e.toString())),
                    )
                }
            } finally {
                try {
                    sock?.leaveGroup(InetAddress.getByName(MULTICAST_ADDR))
                } catch (_: Throwable) {
                }
                try {
                    sock?.close()
                } catch (_: Throwable) {
                }
                socket = null
                releaseLock()
                Log.d(TAG, "DLNA receiver closed")
            }
        }
        thread!!.name = "dlna-receiver"
        thread!!.start()
    }

    private fun stopSocket() {
        running = false
        try {
            socket?.close()
        } catch (_: Throwable) {
        }
        socket = null
        releaseLock()
    }

    private fun send(ip: String, port: Int, data: String) {
        val sock = socket ?: return
        try {
            val bytes = data.toByteArray(Charsets.UTF_8)
            val p = DatagramPacket(bytes, bytes.size, InetAddress.getByName(ip), port)
            sock.send(p)
        } catch (e: Exception) {
            Log.w(TAG, "DLNA send: $e")
        }
    }

    private fun header(data: String, key: String): String? {
        val m = Regex("(?i)^$key:\\s*([^\\r\\n]+)", RegexOption.MULTILINE).find(data)
            ?: return null
        return m.groupValues[1].trim()
    }

    private fun acquireLock() {
        try {
            val wm = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            lock = wm.createMulticastLock("suikan-dlna").apply {
                setReferenceCounted(false)
                acquire()
            }
        } catch (_: Throwable) {
        }
    }

    private fun releaseLock() {
        try {
            lock?.release()
        } catch (_: Throwable) {
        }
        lock = null
    }

    companion object {
        private const val CHANNEL = "simple_live_tv/dlna_receiver"
        private const val MULTICAST_ADDR = "239.255.255.250"
        private const val TAG = "SuikanTV"
    }
}
