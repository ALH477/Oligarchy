// SPDX-License-Identifier: LGPL-3.0-only
package dcf

/**
 * The DeMoD 17-byte DeModFrame wire quantum (version 1), byte-identical to the
 * reference codec in python/MCP/wirelab_core.py and certified against
 * Documentation/golden_vectors.json (the cross-language contract).
 *
 * Wire layout (big-endian):
 * ```
 *   [0]     sync = 0xD3
 *   [1]     flags: version[7:4]=1 | frame_type[3:0]
 *   [2:4]   seq      u16
 *   [4:6]   src      u16
 *   [6:8]   dst      u16
 *   [8:12]  payload  4 bytes
 *   [12:15] ts_us    u24
 *   [15:17] CRC-16/CCITT-FALSE over bytes [0..14]
 * ```
 */
class Frame(
    val version: Int = 1,        // 4-bit
    val type: Int = 0,           // 4-bit (0=Data,1=Ack,2=Beacon,3=Ctrl)
    val seq: Int = 0,            // u16
    val src: Int = 0,            // u16
    val dst: Int = 0,            // u16
    val payload: ByteArray = ByteArray(4),
    val tsUs: Int = 0,           // u24
) {
    /** Serialise into exactly 17 bytes, computing and appending the CRC. */
    fun encode(): ByteArray {
        val b = ByteArray(FRAME_SIZE)
        b[0] = SYNC.toByte()
        b[1] = (((version and 0x0F) shl 4) or (type and 0x0F)).toByte()
        b[2] = (seq ushr 8).toByte(); b[3] = seq.toByte()
        b[4] = (src ushr 8).toByte(); b[5] = src.toByte()
        b[6] = (dst ushr 8).toByte(); b[7] = dst.toByte()
        payload.copyInto(b, 8, 0, 4)
        b[12] = ((tsUs ushr 16) and 0xFF).toByte()
        b[13] = ((tsUs ushr 8) and 0xFF).toByte()
        b[14] = (tsUs and 0xFF).toByte()
        val crc = crc16(b, CRC_COVER)
        b[15] = (crc ushr 8).toByte(); b[16] = crc.toByte()
        return b
    }

    companion object {
        const val SYNC = 0xD3
        const val VERSION = 1
        const val FRAME_SIZE = 17
        const val CRC_COVER = 15
        const val BROADCAST = 0xFFFF

        private const val EXAMPLE_FRAME_FULL = "d31312340001ffffdeadbeefab12cd24c0"

        /** CRC-16/CCITT-FALSE (poly 0x1021, init 0xFFFF, no reflection, no xorout). */
        fun crc16(data: ByteArray, len: Int = data.size): Int {
            var crc = 0xFFFF
            for (k in 0 until len) {
                crc = crc xor ((data[k].toInt() and 0xFF) shl 8)
                for (i in 0 until 8) {
                    crc = if (crc and 0x8000 != 0) ((crc shl 1) xor 0x1021) and 0xFFFF
                          else (crc shl 1) and 0xFFFF
                }
            }
            return crc and 0xFFFF
        }

        /** Affine validity syndrome of a 17-byte word: CRC-valid iff this returns 0. */
        fun syndrome(w: ByteArray): Int {
            require(w.size == FRAME_SIZE) { "need 17 bytes" }
            val stored = ((w[15].toInt() and 0xFF) shl 8) or (w[16].toInt() and 0xFF)
            return (crc16(w, CRC_COVER) xor stored) and 0xFFFF
        }

        /** Parse a 17-byte buffer, validating sync, version nibble, and CRC. */
        fun decode(w: ByteArray): Frame {
            require(w.size == FRAME_SIZE) { "length != 17" }
            require(w[0].toInt() and 0xFF == SYNC) { "bad sync byte" }
            require((w[1].toInt() and 0xFF) ushr 4 == VERSION) { "bad version nibble" }
            require(syndrome(w) == 0) { "CRC mismatch" }
            return Frame(
                version = (w[1].toInt() and 0xFF) ushr 4,
                type = w[1].toInt() and 0x0F,
                seq = ((w[2].toInt() and 0xFF) shl 8) or (w[3].toInt() and 0xFF),
                src = ((w[4].toInt() and 0xFF) shl 8) or (w[5].toInt() and 0xFF),
                dst = ((w[6].toInt() and 0xFF) shl 8) or (w[7].toInt() and 0xFF),
                payload = w.copyOfRange(8, 12),
                tsUs = ((w[12].toInt() and 0xFF) shl 16) or
                       ((w[13].toInt() and 0xFF) shl 8) or (w[14].toInt() and 0xFF),
            )
        }

        /** Lowercase hex of a byte array. */
        fun hex(b: ByteArray): String =
            b.joinToString("") { "%02x".format(it.toInt() and 0xFF) }

        // Self-certify on first use: refuse to load if the codec has diverged from the
        // reference (CRC + example-frame anchors).
        init {
            val c1 = crc16("123456789".toByteArray(Charsets.US_ASCII))
            check(c1 == 0x29B1) { "CRC anchor diverged: CRC(\"123456789\")=0x%04X".format(c1) }
            val c0 = crc16(ByteArray(15))
            check(c0 == 0x4EC3) { "CRC anchor diverged: CRC(0^15)=0x%04X".format(c0) }
            val ex = Frame(
                type = 3, seq = 0x1234, src = 1, dst = BROADCAST,
                payload = byteArrayOf(0xDE.toByte(), 0xAD.toByte(), 0xBE.toByte(), 0xEF.toByte()),
                tsUs = 0xAB12CD,
            )
            val got = hex(ex.encode())
            check(got == EXAMPLE_FRAME_FULL) { "exampleFrame anchor diverged: got $got" }
        }
    }
}
