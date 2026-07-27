// SPDX-License-Identifier: LGPL-3.0-only
package dcf

import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetSocketAddress
import java.net.SocketAddress

/** Operating modes, mirrored across the DCF SDKs. */
enum class Mode { CLIENT, SERVER, P2P }

/**
 * A minimal UDP transport for DeModFrames — the working replacement for the former
 * gRPC sketch. One datagram carries exactly one 17-byte [Frame]; there is no
 * handshake and no encryption (confidentiality is the VPN underlay's job).
 */
class DcfNode(
    bindPort: Int = 0,
    val srcId: Int = 0,
    val mode: Mode = Mode.P2P,
) : AutoCloseable {

    private val socket = DatagramSocket(bindPort)

    /** The actual local UDP port (useful when [bindPort] was 0 = ephemeral). */
    val localPort: Int get() = socket.localPort

    /** Send one already-built frame to host:port. */
    fun send(frame: Frame, host: String, port: Int) {
        val bytes = frame.encode()
        socket.send(DatagramPacket(bytes, bytes.size, InetSocketAddress(host, port)))
    }

    /** Convenience: build and send a DATA frame carrying a 4-byte payload. */
    fun sendData(payload: ByteArray, dst: Int, seq: Int, host: String, port: Int, tsUs: Int = 0) {
        require(payload.size == 4) { "payload must be exactly 4 bytes" }
        send(Frame(type = 0, seq = seq, src = srcId, dst = dst, payload = payload, tsUs = tsUs), host, port)
    }

    /**
     * Block for one datagram (up to [timeoutMs]; 0 = forever) and decode it as a
     * [Frame] with its sender address, or null on timeout / an undecodable datagram.
     */
    fun receive(timeoutMs: Int = 0): Pair<Frame, SocketAddress>? {
        socket.soTimeout = timeoutMs
        val buf = ByteArray(Frame.FRAME_SIZE)
        val pkt = DatagramPacket(buf, buf.size)
        return try {
            socket.receive(pkt)
            if (pkt.length != Frame.FRAME_SIZE) null
            else Frame.decode(buf.copyOf(pkt.length)) to pkt.socketAddress
        } catch (e: Exception) {
            null
        }
    }

    override fun close() = socket.close()
}
