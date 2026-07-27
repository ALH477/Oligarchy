// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2025-2026, Asher LeRoy
package ltd.demod.hyprcontroller.net

import android.content.Context
import android.content.SharedPreferences
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull
import ltd.demod.hyprcontroller.control.HyprController
import java.net.NetworkInterface
import kotlin.coroutines.resume

private const val PREFS_NAME = "hypr_controller"
private const val KEY_LAST_HOST = "last_host"

/** Matches an avahi/mDNS service advertisement of type `_dcfhypr._udp` on the bridge
 * host, if you wire one up (see the README) — optional; broadcast is the real fallback. */
private const val NSD_SERVICE_TYPE = "_dcfhypr._udp."

/**
 * Finds *some* IP that currently reaches the bridge. Deliberately does not know or care
 * which of Tailscale / LAN / USB-gadget got it there — see Documentation/DCF_HYPR_SPEC.md
 * "Transport". A saved Tailscale IP is just another "last host" that keeps answering;
 * broadcast-ping covers plain LAN (no avahi needed) *and* a USB-gadget link, since both
 * are just some private-range interface with a broadcast address.
 */
class TransportManager(
    context: Context,
    private val controller: HyprController,
) {
    private val prefs: SharedPreferences =
        context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    private val nsdManager =
        context.applicationContext.getSystemService(Context.NSD_SERVICE) as NsdManager

    suspend fun discover(): Boolean {
        controller.markDiscovering()

        prefs.getString(KEY_LAST_HOST, null)?.let { saved ->
            if (controller.probeHost(saved)) {
                controller.setPeer(saved, "saved")
                return true
            }
        }

        resolveViaNsd()?.let { host ->
            if (controller.probeHost(host)) {
                controller.setPeer(host, "lan-mdns")
                save(host)
                return true
            }
        }

        controller.discoverByBroadcast(broadcastAddresses())?.let { host ->
            controller.setPeer(host, "broadcast")
            save(host)
            return true
        }

        controller.markDisconnected()
        return false
    }

    /** Manual entry point for the UI's "connect to…" field — e.g. a Tailscale IP the
     * very first time, before it becomes the saved fast path. */
    suspend fun connectTo(host: String): Boolean {
        controller.markDiscovering()
        return if (controller.probeHost(host, timeoutMs = 1500)) {
            controller.setPeer(host, "manual")
            save(host)
            true
        } else {
            controller.markDisconnected()
            false
        }
    }

    fun forgetSavedHost() {
        prefs.edit().remove(KEY_LAST_HOST).apply()
    }

    private fun save(host: String) {
        prefs.edit().putString(KEY_LAST_HOST, host).apply()
    }

    private fun broadcastAddresses(): List<String> {
        val out = mutableListOf<String>()
        try {
            val ifaces = NetworkInterface.getNetworkInterfaces() ?: return out
            for (iface in ifaces) {
                if (!iface.isUp || iface.isLoopback) continue
                if (iface.name.startsWith("rmnet")) continue // skip the cellular uplink
                for (ifaceAddr in iface.interfaceAddresses) {
                    ifaceAddr.broadcast?.hostAddress?.let(out::add)
                }
            }
        } catch (_: Exception) {
            // interface enumeration is best-effort; fall through with whatever we got
        }
        return out
    }

    private suspend fun resolveViaNsd(timeoutMs: Long = 2000): String? = withTimeoutOrNull(timeoutMs) {
        suspendCancellableCoroutine { cont ->
            lateinit var listener: NsdManager.DiscoveryListener
            fun finish(host: String?) {
                runCatching { nsdManager.stopServiceDiscovery(listener) }
                if (cont.isActive) cont.resume(host)
            }
            listener = object : NsdManager.DiscoveryListener {
                override fun onDiscoveryStarted(serviceType: String) {}
                override fun onServiceFound(service: NsdServiceInfo) {
                    nsdManager.resolveService(service, object : NsdManager.ResolveListener {
                        override fun onResolveFailed(info: NsdServiceInfo, errorCode: Int) {}
                        override fun onServiceResolved(info: NsdServiceInfo) = finish(info.host?.hostAddress)
                    })
                }
                override fun onServiceLost(service: NsdServiceInfo) {}
                override fun onDiscoveryStopped(serviceType: String) {}
                override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) = finish(null)
                override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}
            }
            cont.invokeOnCancellation { runCatching { nsdManager.stopServiceDiscovery(listener) } }
            nsdManager.discoverServices(NSD_SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, listener)
        }
    }
}
