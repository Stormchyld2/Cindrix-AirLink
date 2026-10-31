package com.cindrix.airlink

import android.annotation.SuppressLint
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.wifi.WifiManager
import android.net.wifi.p2p.WifiP2pConfig
import android.net.wifi.p2p.WifiP2pManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import java.security.SecureRandom

/**
 * Router-free device-to-device link over Wi-Fi Direct.
 *
 * One device creates a group with a known name + passphrase ([startGroup]), the other joins it by those
 * credentials ([join]), which the pairing QR code carries. Needs Android 10 (API 29) or newer on both
 * phones, which covers every phone released in the last several years (including Android 12 and 13+).
 *
 * All results are plain maps: `{ok: Boolean, error: String?, ssid, passphrase, ip}`.
 */
@SuppressLint("MissingPermission", "NewApi")
class DirectLink(private val context: Context) {
    private val handler = Handler(Looper.getMainLooper())
    private val manager: WifiP2pManager? = context.getSystemService(Context.WIFI_P2P_SERVICE) as? WifiP2pManager
    private var channel: WifiP2pManager.Channel? = null
    private var receiver: BroadcastReceiver? = null
    private var timeout: Runnable? = null

    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    /**
     * Keeps the CPU and the Wi-Fi radio running (even with the screen off) while a transfer is in progress.
     * A safety timeout of 2 hours releases it if the app forgets to.
     */
    @Suppress("DEPRECATION")
    fun setAwake(on: Boolean) {
        if (on) {
            if (wakeLock == null) {
                val pm = context.getSystemService(Context.POWER_SERVICE) as? PowerManager
                wakeLock = pm?.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "airlink:transfer")?.apply {
                    setReferenceCounted(false)
                    acquire(2 * 60 * 60 * 1000L)
                }
            }
            if (wifiLock == null) {
                val wifi = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
                wifiLock = wifi?.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "airlink:transfer")?.apply {
                    setReferenceCounted(false)
                    acquire()
                }
            }
        } else {
            try { wakeLock?.takeIf { it.isHeld }?.release() } catch (_: Exception) {}
            try { wifiLock?.takeIf { it.isHeld }?.release() } catch (_: Exception) {}
            wakeLock = null
            wifiLock = null
        }
    }

    fun isSupported(): Boolean {
        return Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
                manager != null &&
                context.packageManager.hasSystemFeature(PackageManager.FEATURE_WIFI_DIRECT)
    }

    private fun hasPermission(): Boolean {
        val permission = if (Build.VERSION.SDK_INT >= 33) {
            "android.permission.NEARBY_WIFI_DEVICES"
        } else {
            android.Manifest.permission.ACCESS_FINE_LOCATION
        }
        return context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED
    }

    /** Returns an error code if Wi-Fi Direct cannot be used right now, otherwise null. */
    private fun precheck(): String? {
        if (!isSupported()) return "unsupported"
        if (!hasPermission()) return "permission"
        val wifi = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
        if (wifi != null && !wifi.isWifiEnabled) return "wifi_off"
        return null
    }

    private fun fail(error: String): Map<String, Any?> = mapOf("ok" to false, "error" to error)

    private fun once(done: (Map<String, Any?>) -> Unit): (Map<String, Any?>) -> Unit {
        var called = false
        return { value ->
            handler.post {
                if (!called) {
                    called = true
                    done(value)
                }
            }
        }
    }

    private fun randomString(length: Int): String {
        val alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
        val random = SecureRandom()
        return (1..length).map { alphabet[random.nextInt(alphabet.length)] }.joinToString("")
    }

    /** Creates a Wi-Fi Direct group and reports its credentials and the host IP. */
    fun startGroup(done: (Map<String, Any?>) -> Unit) {
        val callback = once(done)
        precheck()?.let { callback(fail(it)); return }
        val mgr = manager!!

        stop {
            val ch = mgr.initialize(context, Looper.getMainLooper(), null)
            channel = ch
            // The group name + passphrase are created once and kept, so devices that paired before can
            // rejoin later without scanning a code again.
            val prefs = context.getSharedPreferences("airlink_direct", Context.MODE_PRIVATE)
            val ssid = prefs.getString("ssid", null) ?: ("DIRECT-AL-" + randomString(4))
            val passphrase = prefs.getString("passphrase", null) ?: randomString(12)
            prefs.edit().putString("ssid", ssid).putString("passphrase", passphrase).apply()

            val config = WifiP2pConfig.Builder()
                .setNetworkName(ssid)
                .setPassphrase(passphrase)
                .enablePersistentMode(false)
                .setGroupOperatingBand(WifiP2pConfig.GROUP_OWNER_BAND_2GHZ)
                .build()

            try {
                mgr.createGroup(ch, config, object : WifiP2pManager.ActionListener {
                    override fun onSuccess() {
                        // give the group a moment to come up, then read back what Android actually created
                        handler.postDelayed({ readGroup(mgr, ch, ssid, passphrase, callback) }, 400)
                    }

                    override fun onFailure(reason: Int) {
                        callback(fail("create_failed_$reason"))
                    }
                })
            } catch (e: SecurityException) {
                callback(fail("permission"))
            }
        }
    }

    private fun readGroup(
        mgr: WifiP2pManager,
        ch: WifiP2pManager.Channel,
        ssid: String,
        passphrase: String,
        callback: (Map<String, Any?>) -> Unit,
    ) {
        mgr.requestGroupInfo(ch) { group ->
            val realSsid = group?.networkName ?: ssid
            val realPass = group?.passphrase ?: passphrase
            mgr.requestConnectionInfo(ch) { info ->
                // 192.168.49.1 is the fixed address Android gives the Wi-Fi Direct group owner.
                val ip = info?.groupOwnerAddress?.hostAddress ?: "192.168.49.1"
                callback(mapOf("ok" to true, "ssid" to realSsid, "passphrase" to realPass, "ip" to ip))
            }
        }
    }

    /** Number of devices currently connected to the group this phone hosts. */
    fun clientCount(done: (Int) -> Unit) {
        val mgr = manager
        val ch = channel
        if (mgr == null || ch == null) {
            done(0)
            return
        }
        try {
            mgr.requestGroupInfo(ch) { group -> done(group?.clientList?.size ?: 0) }
        } catch (e: Exception) {
            done(0)
        }
    }

    /** Joins a group created by [startGroup] on another device. Completes when the link is up. */
    fun join(ssid: String, passphrase: String, done: (Map<String, Any?>) -> Unit) {
        val callback = once(done)
        precheck()?.let { callback(fail(it)); return }
        val mgr = manager!!

        stop {
            val ch = mgr.initialize(context, Looper.getMainLooper(), null)
            channel = ch

            val rx = object : BroadcastReceiver() {
                override fun onReceive(c: Context?, intent: Intent?) {
                    mgr.requestConnectionInfo(ch) { info ->
                        val address = info?.groupOwnerAddress?.hostAddress
                        if (info != null && info.groupFormed && !info.isGroupOwner && address != null) {
                            timeout?.let { handler.removeCallbacks(it) }
                            callback(mapOf("ok" to true, "ip" to address))
                        }
                    }
                }
            }
            receiver = rx
            val filter = IntentFilter(WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION)
            if (Build.VERSION.SDK_INT >= 33) {
                context.registerReceiver(rx, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                context.registerReceiver(rx, filter)
            }

            val timeoutTask = Runnable {
                callback(fail("timeout"))
                stop(null)
            }
            timeout = timeoutTask
            handler.postDelayed(timeoutTask, 35_000)

            val config = WifiP2pConfig.Builder()
                .setNetworkName(ssid)
                .setPassphrase(passphrase)
                .build()

            fun connect() {
                try {
                    mgr.connect(ch, config, object : WifiP2pManager.ActionListener {
                        override fun onSuccess() {}

                        override fun onFailure(reason: Int) {
                            callback(fail("connect_failed_$reason"))
                            stop(null)
                        }
                    })
                } catch (e: SecurityException) {
                    callback(fail("permission"))
                }
            }

            // Discovery first makes joining by name far more reliable on many phones.
            try {
                mgr.discoverPeers(ch, object : WifiP2pManager.ActionListener {
                    override fun onSuccess() {
                        handler.postDelayed({ connect() }, 800)
                    }

                    override fun onFailure(reason: Int) {
                        connect()
                    }
                })
            } catch (e: SecurityException) {
                callback(fail("permission"))
            }
        }
    }

    /** Tears down the group or connection and frees the radio. Safe to call at any time. */
    fun stop(done: (() -> Unit)?) {
        setAwake(false)
        timeout?.let { handler.removeCallbacks(it) }
        timeout = null
        receiver?.let {
            try {
                context.unregisterReceiver(it)
            } catch (_: Exception) {
            }
        }
        receiver = null

        val mgr = manager
        val ch = channel
        channel = null
        if (mgr == null || ch == null) {
            done?.invoke()
            return
        }

        fun close() {
            if (Build.VERSION.SDK_INT >= 27) {
                try {
                    ch.close()
                } catch (_: Exception) {
                }
            }
            done?.invoke()
        }

        try {
            mgr.cancelConnect(ch, null)
            mgr.stopPeerDiscovery(ch, null)
            mgr.removeGroup(ch, object : WifiP2pManager.ActionListener {
                override fun onSuccess() = close()
                override fun onFailure(reason: Int) = close()
            })
        } catch (e: Exception) {
            close()
        }
    }
}
