// SPDX-License-Identifier: LGPL-3.0-only
package dcf

/**
 * DCF-Text — the L2 adapter that carries a UTF-8 message (≤ 4092 bytes) as a burst of
 * ordinary [Frame] `DATA` (type 0) frames. Byte-identical to the reference codec in
 * `python/MCP/textlab_core.py` and certified against `Documentation/text_vectors.json`
 * (9 framing + 4 reassembly cases). See `Documentation/DCF_TEXT_SPEC.md` — normative.
 *
 * `seq` splits as `packet_id[15:10] (6 bits) | frag_idx[9:0] (10 bits)`. `frag_idx == 0`
 * is the descriptor (`payload = [len_hi, len_lo, flags, 0]`); `frag_idx 1..N` are data
 * (4 bytes each, last frame zero-padded). This file introduces no new wire format — it
 * is the missing Kotlin port of an adapter that already exists in C/Rust/Python/Go.
 */
object Text {
    const val FLAG_AGENT = 0x01
    const val FLAG_MORE = 0x02
    const val FLAG_RELIABLE = 0x04

    const val MAX_PACKET_ID = 63          // 6-bit
    const val MAX_FRAGS = 1023            // 10-bit
    const val MAX_MESSAGE_BYTES = MAX_FRAGS * 4 // 4092

    /** `channel_id(name) = crc16(name)` — the same rendezvous hash used across the repo. */
    fun channelId(name: String): Int = Frame.crc16(name.toByteArray(Charsets.UTF_8))

    /** Fragment raw bytes into `1 + ceil(len/4)` valid [Frame]s. `flags` is opaque to L2. */
    fun packetize(
        message: ByteArray,
        packetId: Int,
        src: Int,
        dst: Int,
        tsUs: Int,
        flags: Int = 0,
    ): List<Frame> {
        require(message.size <= MAX_MESSAGE_BYTES) {
            "message exceeds $MAX_MESSAGE_BYTES bytes; app must chunk with the MORE flag"
        }
        require(packetId in 0..MAX_PACKET_ID) { "packetId must be 0..$MAX_PACKET_ID" }
        val fragTotal = (message.size + 3) / 4
        val frames = ArrayList<Frame>(1 + fragTotal)

        val descPayload = byteArrayOf(
            ((message.size ushr 8) and 0xFF).toByte(),
            (message.size and 0xFF).toByte(),
            (flags and 0xFF).toByte(),
            0,
        )
        frames.add(Frame(type = 0, seq = (packetId shl 10), src = src, dst = dst, payload = descPayload, tsUs = tsUs))

        for (k in 1..fragTotal) {
            val start = (k - 1) * 4
            val end = minOf(start + 4, message.size)
            val chunk = ByteArray(4) // zero-padded by default
            message.copyInto(chunk, 0, start, end)
            frames.add(Frame(type = 0, seq = (packetId shl 10) or k, src = src, dst = dst, payload = chunk, tsUs = tsUs))
        }
        return frames
    }

    /** Convenience overload for a UTF-8 [String] message. */
    fun packetizeText(message: String, packetId: Int, src: Int, dst: Int, tsUs: Int, flags: Int = 0): List<Frame> =
        packetize(message.toByteArray(Charsets.UTF_8), packetId, src, dst, tsUs, flags)

    /** A fully reassembled DCF-Text message. */
    data class Message(
        val packetId: Int,
        val tsUs: Int,
        val src: Int,
        val dst: Int,
        val text: String,
        val flags: Int,
    )

    /**
     * Reassembles [Frame]s arriving out of order and possibly duplicated. One instance
     * per channel — DCF-Text and DCF-Game share the `DATA` type and are told apart only
     * by deployment (which reassembler a node feeds a channel's frames to), never by the
     * bytes, so never share one [TextReassembler] across a control and a telemetry
     * channel (see `DCF_TEXT_SPEC.md` "Relationship to DCF-Game").
     *
     * Tolerates: duplicate fragments (idempotent — ignored), out-of-order fragments
     * (including a descriptor arriving *after* its data), and duplicate descriptors.
     * [finalize] reports every still-incomplete `packetId` as lost, ascending, and clears
     * all state — call it when a session ends or a link drops to avoid unbounded growth
     * across the 6-bit `packetId` wraparound.
     */
    class TextReassembler {
        private class Pending(val tsUs: Int, val src: Int, val dst: Int) {
            var len: Int? = null
            var flags: Int = 0
            var fragTotal: Int? = null
            val data = HashMap<Int, ByteArray>() // frag_idx -> 4 bytes, may arrive before the descriptor
        }

        private val pending = HashMap<Int, Pending>() // packetId -> Pending

        /** Feed one already-decoded [Frame]. Returns a completed [Message], or null if still incomplete. */
        fun push(frame: Frame): Message? {
            val packetId = (frame.seq ushr 10) and 0x3F
            val fragIdx = frame.seq and MAX_FRAGS

            val p = pending.getOrPut(packetId) { Pending(frame.tsUs, frame.src, frame.dst) }

            if (fragIdx == 0) {
                if (p.len != null) return null // duplicate descriptor — ignore
                val len = ((frame.payload[0].toInt() and 0xFF) shl 8) or (frame.payload[1].toInt() and 0xFF)
                p.len = len
                p.flags = frame.payload[2].toInt() and 0xFF
                p.fragTotal = (len + 3) / 4
            } else {
                val knownTotal = p.fragTotal
                if (knownTotal != null && fragIdx > knownTotal) return null // bogus index — ignore
                if (p.data.containsKey(fragIdx)) return null // duplicate data — idempotent, ignore
                p.data[fragIdx] = frame.payload
            }

            val fragTotal = p.fragTotal ?: return null // still waiting on the descriptor

            if (fragTotal == 0) {
                pending.remove(packetId)
                return Message(packetId, p.tsUs, p.src, p.dst, "", p.flags)
            }
            for (k in 1..fragTotal) if (!p.data.containsKey(k)) return null // still missing a fragment

            val full = ByteArray(fragTotal * 4)
            for (k in 1..fragTotal) p.data.getValue(k).copyInto(full, (k - 1) * 4)
            val text = String(full, 0, p.len!!, Charsets.UTF_8)
            pending.remove(packetId)
            return Message(packetId, p.tsUs, p.src, p.dst, text, p.flags)
        }

        /** Report every still-incomplete buffered `packetId` as lost (ascending), then clear. */
        fun finalize(): List<Int> {
            val lost = pending.keys.sorted()
            pending.clear()
            return lost
        }
    }

    // Self-certify on first use, mirroring Frame's own anchor check: refuse to load if
    // this port has diverged from the reference (Documentation/DCF_TEXT_SPEC.md anchor).
    init {
        val anchor = "agent \u21c4 agent \uD83D\uDE80" // "agent ⇄ agent 🚀", 20 UTF-8 bytes
        val frames = packetizeText(anchor, packetId = 10, src = 0x00A1, dst = 0xEED7, tsUs = 66051, flags = 0x05)
        check(frames.size == 6) { "DCF-Text anchor diverged: expected 6 frames (1 descriptor + 5 data), got ${frames.size}" }
        val got = Frame.hex(frames[0].encode())
        check(got == "d310280000a1eed7001405000102035490") { "DCF-Text anchor diverged: first frame $got" }
    }
}
