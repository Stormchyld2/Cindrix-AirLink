package com.cindrix.airlink

import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.LinkProperties
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiManager
import android.net.wifi.WifiNetworkSpecifier
import android.os.Build
import android.os.Handler
import android.os.Looper

/**
 * Fallback link when Wi-Fi Direct does not work: the phone opens a private, internet-less
 * "local-only hotspot" and the other device joins it using the name + password from the pairing QR.
 * Android picks the name and password; they change every time.
 *
 * Results are plain maps: `{ok: Boolean, error: String?, ssid, passphrase, ip}`.
 */
@SuppressLint("MissingPermission", "NewApi")
class LocalHotspot(private val context: Context) {
    private val handler = Handler(Looper.getMainLooper())
    private val wifi = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
    private val connectivity = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
    private var reservation: WifiManager.LocalOnlyHotspotReservation? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null

    fun isSupported(): Boolean = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && wifi != null && connectivity != null

    private fun hasPermission(): Boolean {
        val permission = if (Build.VERSION.SDK_INT >= 33) {
            "android.permission.NEARBY_WIFI_DEVICES"
        } else {
            android.Manifest.permission.ACCESS_FINE_LOCATION
        }
        return context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED
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

    /** Starts the hotspot and reports its name and password. The joining device finds the address itself. */
    fun start(done: (Map<String, Any?>) -> Unit) {
        val callback = once(done)
        if (!isSupported()) { callback(fail("unsupported")); return }
        if (!hasPermission()) { callback(fail("permission")); return }
        val mgr = wifi!!
        if (!mgr.isWifiEnabled) { callback(fail("wifi_off")); return }

        stop()
        try {
            mgr.startLocalOnlyHotspot(object : WifiManager.LocalOnlyHotspotCallback() {
                @Suppress("DEPRECATION")
                override fun onStarted(res: WifiManager.LocalOnlyHotspotReservation) {
                    reservation = res
                    val ssid: String?
                    val pass: String?
                    if (Build.VERSION.SDK_INT >= 30) {
                        val config = res.softApConfiguration
                        ssid = config.ssid
                        pass = config.passphrase
                    } else {
                        val config = res.wifiConfiguration
                        ssid = config?.SSID?.trim('"')
                        pass = config?.preSharedKey?.trim('"')
                    }
                    if (ssid == null || pass == null) {
                        stop()
                        callback(fail("no_credentials"))
                    } else {
                        callback(mapOf("ok" to true, "ssid" to ssid, "passphrase" to pass))
                    }
                }

                override fun onFailed(reason: Int) {
                    callback(fail("hotspot_failed_$reason"))
                }

                override fun onStopped() {
                    reservation = null
                }
            }, handler)
        } catch (e: SecurityException) {
            callback(fail("permission"))
        } catch (e: Exception) {
            callback(fail("hotspot_failed"))
        }
    }

    /** Joins a hotspot created by [start] on another device and reports the host's address. */
    fun join(ssid: String, passphrase: String, done: (Map<String, Any?>) -> Unit) {
        val callback = once(done)
        val cm = connectivity
        if (!isSupported() || cm == null) { callback(fail("unsupported")); return }

        stop()
        val specifier = WifiNetworkSpecifier.Builder()
            .setSsid(ssid)
            .setWpa2Passphrase(passphrase)
            .build()
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .setNetworkSpecifier(specifier)
            .build()

        val cb = object : ConnectivityManager.NetworkCallback() {
            private var bound = false

            override fun onAvailable(network: Network) {
                // send this app's traffic over the new network; it has no internet, so Android would not do it itself
                cm.bindProcessToNetwork(network)
                bound = true
                report(network, cm.getLinkProperties(network))
            }

            override fun onLinkPropertiesChanged(network: Network, linkProperties: LinkProperties) {
                if (bound) report(network, linkProperties)
            }

            override fun onUnavailable() {
                callback(fail("unavailable"))
            }

            private fun report(network: Network, props: LinkProperties?) {
                if (props == null) return
                var gateway = props.routes.firstOrNull { it.isDefaultRoute && it.gateway != null }?.gateway?.hostAddress
                if (gateway == null && Build.VERSION.SDK_INT >= 30) {
                    gateway = props.dhcpServerAddress?.hostAddress
                }
                if (gateway == null) {
                    gateway = props.routes.firstOrNull { it.gateway != null && it.gateway?.isAnyLocalAddress == false }?.gateway?.hostAddress
                }
                if (gateway != null) {
                    callback(mapOf("ok" to true, "ip" to gateway))
                }
            }
        }
        networkCallback = cb
        try {
            cm.requestNetwork(request, cb, handler, 35_000)
        } catch (e: Exception) {
            callback(fail("join_failed"))
        }
    }

    fun stop() {
        try {
            reservation?.close()
        } catch (_: Exception) {
        }
        reservation = null

        val cm = connectivity
        networkCallback?.let {
            try {
                cm?.unregisterNetworkCallback(it)
            } catch (_: Exception) {
            }
        }
        if (networkCallback != null) {
            try {
                cm?.bindProcessToNetwork(null)
            } catch (_: Exception) {
            }
        }
        networkCallback = null
    }
}
