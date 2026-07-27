// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2025-2026, Asher LeRoy
package ltd.demod.hyprcontroller.control

import dcf.DcfNode
import dcf.Mode
import dcf.Text
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.net.InetSocketAddress
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

/** One relayed Hyprland event, e.g. name="workspace" data="3", or name="activewindow" data="class,Title". */
data class HyprEvent(val name: String, val data: String)

sealed class ConnState {
    data object Disconnected : ConnState()
    data object Discovering : ConnState()
    data class Connected(val host: String, val via: String) : ConnState()
}

/**
 * The controller-side half of DCF-Hypr (see Documentation/DCF_HYPR_SPEC.md in the
 * HydraMesh repo). Owns one [DcfNode] / UDP socket; three transports (Tailscale, LAN,
 * USB-gadget) are just different values of `host` — this class never knows or cares
 * which one currently reaches the bridge.
 *
 * Two channels: `hypr`/`ctl` ops go out on [controlChannelName] and are ACK'd by the
 * bridge; `.socket2.sock` events come back on [telemetryChannelName], fire-and-forget.
 */
class HyprController(
    private val myNodeId: Int = 0x0002,
    private val controlChannelName: String = "demod-hypr-ctrl",
    private val telemetryChannelName: String = "demod-hypr-tele",
    private val port: Int = 7100,
) {
    private val node = DcfNode(bindPort = 0, srcId = myNodeId, mode = Mode.P2P)
    private val controlChannel = Text.channelId(controlChannelName)
    private val telemetryChannel = Text.channelId(telemetryChannelName)
    private val ctrlReasm = Text.TextReassembler()
    private val teleReasm = Text.TextReassembler()
    private val requestCounter = AtomicInteger(0)
    private val packetIdCounter = AtomicInteger(0)

    @Volatile private var peerHost: String? = null
    @Volatile private var pendingAnyPong: CompletableDeferred<String>? = null
    private val pendingAcks = ConcurrentHashMap<String, CompletableDeferred<Result<String>>>()
    private val pendingPongs = ConcurrentHashMap<String, CompletableDeferred<Unit>>()

    private val _telemetry = MutableSharedFlow<HyprEvent>(replay = 0, extraBufferCapacity = 64)
    val telemetry: SharedFlow<HyprEvent> = _telemetry

    private val _connection = MutableStateFlow<ConnState>(ConnState.Disconnected)
    val connection: StateFlow<ConnState> = _connection

    private var receiveJob: Job? = null

    fun start(scope: CoroutineScope) {
        receiveJob = scope.launch(Dispatchers.IO) { receiveLoop() }
    }

    fun stop() {
        receiveJob?.cancel()
        node.close()
    }

    fun setPeer(host: String, via: String) {
        peerHost = host
        _connection.value = ConnState.Connected(host, via)
    }

    fun markDiscovering() {
        _connection.value = ConnState.Discovering
    }

    fun markDisconnected() {
        peerHost = null
        _connection.value = ConnState.Disconnected
    }

    // ── low-level send/receive ──────────────────────────────────────────────────────

    private fun nextPacketId(): Int = packetIdCounter.getAndUpdate { (it + 1) % 64 }
    private fun nextRequestId(): String = requestCounter.getAndIncrement().toString()

    private fun sendText(text: String, dst: Int, host: String) {
        val tsUs = (System.currentTimeMillis() and 0xFFFFFF).toInt()
        for (f in Text.packetizeText(text, nextPacketId(), myNodeId, dst, tsUs)) {
            node.send(f, host, port)
        }
    }

    private suspend fun receiveLoop() {
        while (currentCoroutineContext().isActive) {
            val result = withContext(Dispatchers.IO) { node.receive(timeoutMs = 500) }
            if (result == null) continue
            val (frame, addr) = result
            val host = (addr as? InetSocketAddress)?.address?.hostAddress ?: continue
            when (frame.dst) {
                controlChannel -> ctrlReasm.push(frame)?.let { handleControlReply(it.text, host) }
                telemetryChannel -> teleReasm.push(frame)?.let { msg ->
                    parseTelemetry(msg.text)?.let { _telemetry.tryEmit(it) }
                }
            }
        }
    }

    private fun handleControlReply(line: String, host: String) {
        if (line == "ping") return // ignore stray echoes
        val parts = line.split(" ", limit = 3)
        if (parts.isEmpty()) return
        if (parts[0] == "pong") {
            pendingPongs.remove(host)?.complete(Unit)
            pendingAnyPong?.let { if (!it.isCompleted) it.complete(host) }
            return
        }
        if (parts.size >= 2) {
            val id = parts[0]
            val status = parts[1]
            val body = if (parts.size > 2) parts[2] else ""
            pendingAcks.remove(id)?.complete(
                if (status == "ok") Result.success(body) else Result.failure(RuntimeException(body.ifEmpty { "error" }))
            )
        }
    }

    private fun parseTelemetry(line: String): HyprEvent? {
        val idx = line.indexOf(">>")
        if (idx < 0) return null
        return HyprEvent(line.substring(0, idx), line.substring(idx + 2))
    }

    // ── discovery/liveness primitives (used by TransportManager) ───────────────────

    /** Unicast ping to a *known* host; true iff it pongs back within [timeoutMs]. */
    suspend fun probeHost(host: String, timeoutMs: Long = 400): Boolean {
        val deferred = CompletableDeferred<Unit>()
        pendingPongs[host] = deferred
        sendText("ping", controlChannel, host)
        val ok = withTimeoutOrNull(timeoutMs) { deferred.await() } != null
        pendingPongs.remove(host)
        return ok
    }

    /** Ping every address in [broadcastHosts]; return whichever unknown host replies first. */
    suspend fun discoverByBroadcast(broadcastHosts: List<String>, timeoutMs: Long = 800): String? {
        if (broadcastHosts.isEmpty()) return null
        val deferred = CompletableDeferred<String>()
        pendingAnyPong = deferred
        for (h in broadcastHosts) sendText("ping", controlChannel, h)
        val winner = withTimeoutOrNull(timeoutMs) { deferred.await() }
        pendingAnyPong = null
        return winner
    }

    // ── reliability classes (DCF_HYPR_SPEC.md §L4) ──────────────────────────────────

    /** State-changing ops: ACK required, exponential backoff, capped retries. */
    private suspend fun sendReliable(op: String, args: String, maxTries: Int = 5, baseTimeoutMs: Long = 250): Result<String> {
        val host = peerHost ?: return Result.failure(IllegalStateException("not connected"))
        val id = nextRequestId()
        val line = if (args.isEmpty()) "$id $op" else "$id $op $args"
        var timeout = baseTimeoutMs
        repeat(maxTries) {
            val deferred = CompletableDeferred<Result<String>>()
            pendingAcks[id] = deferred
            sendText(line, controlChannel, host)
            val result = withTimeoutOrNull(timeout) { deferred.await() }
            if (result != null) return result
            pendingAcks.remove(id)
            timeout = (timeout * 2).coerceAtMost(4000)
        }
        return Result.failure(RuntimeException("no ack after $maxTries tries"))
    }

    /** Event/latest-wins ops (rapid D-pad taps): fire once, no ACK wait — a dropped tap
     * is corrected by the next one, which matters more for feel than one guaranteed hit. */
    private fun sendFireAndForget(op: String, args: String) {
        val host = peerHost ?: return
        val id = nextRequestId()
        sendText(if (args.isEmpty()) "$id $op" else "$id $op $args", controlChannel, host)
    }

    // ── convenience API for the UI layer ────────────────────────────────────────────

    suspend fun workspace(n: Int) = sendReliable("hypr", "workspace $n")
    suspend fun moveToWorkspace(n: Int) = sendReliable("hypr", "movetoworkspace $n")
    fun moveFocus(dir: Char) = sendFireAndForget("hypr", "movefocus $dir") // l/r/u/d
    suspend fun toggleFloating() = sendReliable("hypr", "togglefloating")
    suspend fun toggleFullscreen() = sendReliable("hypr", "fullscreen")
    suspend fun killActive() = sendReliable("hypr", "killactive")
    suspend fun exec(cmd: String) = sendReliable("hypr", "exec $cmd")
    suspend fun toggleSpecialWorkspace(name: String) = sendReliable("hypr", "togglespecialworkspace $name")

    // ── media / volume / one-tap system commands ────────────────────────────────────
    // All of these are just `exec()` with a specific command line — no new op family,
    // no bridge changes. Hyprland's own `exec` dispatcher doesn't care whether the
    // command opens a window or just runs in the background, so this is exactly how
    // XF86 media keys are already bound on this box (home/asher.nix) — the phone is
    // just sending the same commands a physical key would.
    suspend fun mediaPlayPause() = exec("playerctl play-pause")
    suspend fun mediaNext() = exec("playerctl next")
    suspend fun mediaPrevious() = exec("playerctl previous")
    suspend fun mediaStop() = exec("playerctl stop")

    // PipeWire/WirePlumber, 2% steps — the same increment your XF86 volume keys use.
    suspend fun volumeUp() = exec("wpctl set-volume @DEFAULT_AUDIO_SINK@ 2%+")
    suspend fun volumeDown() = exec("wpctl set-volume @DEFAULT_AUDIO_SINK@ 2%-")
    suspend fun volumeMuteToggle() = exec("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle")

    suspend fun lockScreen() = exec("hyprlock")
    suspend fun screenshot() = exec("~/.config/hypr/scripts/screenshot.sh screen")

    /** Arbitrary shell, verbatim — genuinely different risk profile from every other
     * method above: those are one fixed command each, this is whatever the caller
     * passes. Real remote code execution on the box; see DCF_HYPR_SPEC.md §Security
     * before exposing this over anything but Tailscale or a direct USB-gadget link. */
    suspend fun execRaw(cmd: String) = exec(cmd)

    /** The whole existing control-center registry, for free — no new bridge logic. */
    suspend fun ctlCats(): Result<String> = sendReliable("ctl", "cats")
    suspend fun ctlItems(category: String): Result<String> = sendReliable("ctl", "items $category")
    suspend fun ctlRun(actionId: String): Result<String> = sendReliable("ctl", "run $actionId")
}

/** Parses the "id|Label" lines oligarchy-ctl's `cats`/`items` emit. */
fun parseIdLabelLines(text: String): List<Pair<String, String>> =
    text.lineSequence()
        .map { it.trim() }
        .filter { it.isNotEmpty() && it.contains('|') }
        .map { val (id, label) = it.split("|", limit = 2); id to label }
        .toList()
