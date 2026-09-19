package com.example.rtkmanager

import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.Calendar
import java.util.TimeZone
import kotlin.math.*

// Protocol units match sys_gnss2/Core/Inc/imu_proto.h (g, deg/s, not SI).
object CaptureFormats {
    const val WEEK_NS = 604800000000000L
    const val DAY_NS = 86400000000000L
    const val C = 299792458.0
    const val GPS_EPOCH_MS = 315964800000L

    fun sensorFrame(tid: Int, gpsNs: Long, leap: Int, id: Int, values: FloatArray): ByteArray {
        require(id in listOf(0x10, 0x20, 0x30) && values.size >= 3)
        val scale = when (id) { 0x10 -> 1e6 / 9.80665; 0x20 -> 1e6 * 180 / PI; else -> 1e3 }
        val utcNs = gpsNs - leap * 1000000000L
        val cal = Calendar.getInstance(TimeZone.getTimeZone("UTC"))
        cal.timeInMillis = GPS_EPOCH_MS + Math.floorDiv(utcNs, 1000000)
        val us = Math.floorMod(utcNs, 1000000000) / 1000
        val payload = ByteBuffer.allocate(45).order(ByteOrder.LITTLE_ENDIAN)
        payload.put(id.toByte()).put(12)
        for (v in values.take(3)) {
            val scaled = v * scale
            require(scaled.isFinite() && scaled in Int.MIN_VALUE.toDouble()..Int.MAX_VALUE.toDouble())
            payload.putInt(scaled.roundToInt())
        }
        payload.put(0x50).put(11).putInt((us / 1000).toInt())
            .putShort((cal.get(Calendar.YEAR) - 2000).toShort())
            .put((cal.get(Calendar.MONTH) + 1).toByte()).put(cal.get(Calendar.DAY_OF_MONTH).toByte())
            .put(cal.get(Calendar.HOUR_OF_DAY).toByte()).put(cal.get(Calendar.MINUTE).toByte())
            .put(cal.get(Calendar.SECOND).toByte())
        payload.put(0x51).put(4).putInt(us.toInt())
        // Free TLV 0x52: GPS week + nanoseconds of week, authoritative time.
        payload.put(0x52).put(10).putShort((gpsNs / WEEK_NS).toShort()).putLong(gpsNs % WEEK_NS)
        val frame = ByteBuffer.allocate(52).order(ByteOrder.LITTLE_ENDIAN)
        frame.put(0x59).put(0x53).putShort(tid.toShort()).put(45).put(payload.array())
        var a = 0; var b = 0
        for (i in 2 until 50) { a = (a + (frame.array()[i].toInt() and 255)) and 255; b = (b + a) and 255 }
        frame.put(a.toByte()).put(b.toByte())
        return frame.array()
    }
}

class GnssTimeSync {
    var gpsNs: Long = 0; private set
    var elapsedNs: Long = 0; private set
    var discontinuity: Int? = null; private set
    fun update(gps: Long, elapsed: Long, count: Int): Boolean {
        require(gps > 0 && elapsed > 0)
        val changed = discontinuity != null && (discontinuity != count ||
            abs((gps - gpsNs) - (elapsed - elapsedNs)) > 5000000L)
        gpsNs = gps; elapsedNs = elapsed; discontinuity = count
        return changed
    }
    fun at(elapsed: Long): Long? = if (elapsedNs > 0 && abs(elapsed - elapsedNs) <= 10000000000L)
        gpsNs + (elapsed - elapsedNs) else null
    fun clear() { gpsNs = 0; elapsedNs = 0; discontinuity = null }
}

data class PhoneObservation(
    val system: Int, val satellite: Int, val signal: Int, val frequency: Double,
    val range: Double, val phaseMeters: Double?, val rate: Double?, val cn0: Double,
    val adrState: Int, val gloChannel: Int = 0
)

object PhoneGnssMath {
    // Android constellation IDs; RTCM MSM signal numbers (not RINEX code IDs).
    fun signal(system: Int, frequency: Double, code: String): Int? {
        fun near(mhz: Double) = abs(frequency - mhz * 1e6) < 20000
        val band = when {
            system == 3 && frequency in 1598000000.0..1607000000.0 -> "1"
            system == 3 && frequency in 1242000000.0..1250000000.0 -> "2"
            near(1575.42) -> "1"; near(1227.60) -> "2"; near(1176.45) -> "5"
            near(1207.14) -> "7"; near(1191.795) -> "8"; near(1278.75) -> "6"
            near(1561.098) -> "2"; near(1268.52) -> "6"; near(2492.028) -> "9"
            else -> return null
        }
        // Unknown code types are not guessed; they remain in the raw CSV.
        val map = when (system) {
            1 -> mapOf("1C" to 2, "1P" to 3, "1W" to 4, "2C" to 8, "2P" to 9, "2W" to 10,
                "2S" to 15, "2L" to 16, "2X" to 17, "5I" to 22, "5Q" to 23, "5X" to 24,
                "1S" to 30, "1L" to 31, "1X" to 32)
            2 -> mapOf("1C" to 2, "5I" to 22, "5Q" to 23, "5X" to 24)
            3 -> mapOf("1C" to 2, "1P" to 3, "2C" to 8, "2P" to 9)
            4 -> mapOf("1C" to 2, "2S" to 15, "2L" to 16, "2X" to 17, "5I" to 22, "5Q" to 23,
                "5X" to 24, "1S" to 30, "1L" to 31, "1X" to 32, "6S" to 9, "6L" to 10, "6X" to 11)
            5 -> mapOf("2I" to 2, "2Q" to 3, "2X" to 4, "6I" to 8, "6Q" to 9, "6X" to 10,
                "7I" to 14, "7Q" to 15, "7X" to 16, "5D" to 22, "5P" to 23, "5X" to 24,
                "7D" to 25, "1D" to 30, "1P" to 31, "1X" to 32)
            6 -> mapOf("1C" to 2, "1A" to 3, "1B" to 4, "1X" to 5, "1Z" to 6,
                "6C" to 8, "6A" to 9, "6B" to 10, "6X" to 11, "6Z" to 12,
                "7I" to 14, "7Q" to 15, "7X" to 16, "8I" to 18, "8Q" to 19, "8X" to 20,
                "5I" to 22, "5Q" to 23, "5X" to 24)
            7 -> mapOf("5A" to 22, "9A" to 8)
            else -> return null
        }
        return map[band + code]
    }

    fun pseudorange(gpsNs: Long, offsetNs: Double, svNs: Long, system: Int, state: Int, leap: Int): Double? {
        if (state and 16 != 0 || !offsetNs.isFinite()) return null // millisecond ambiguity
        val known = if (system == 3) state and (128 or 32768) != 0 else state and (8 or 16384) != 0
        if (!known) return null
        val period = if (system == 3) CaptureFormats.DAY_NS else CaptureFormats.WEEK_NS
        val shift = when (system) { 3 -> (10800 - leap) * 1000000000L; 5 -> -14000000000L; else -> 0L }
        val receiver = Math.floorMod(gpsNs + shift, period)
        var travel = (receiver - svNs).toDouble() + offsetNs
        travel -= floor(travel / period) * period
        val range = travel * 1e-9 * CaptureFormats.C
        return range.takeIf { it.isFinite() && it in 1000000.0..60000000.0 }
    }
}

// MSM7 encoder: RTCM3 framing/CRC24Q, per-constellation epochs, signed invalid codes.
// Each phase arc is translated by integer wavelengths to fit the MSM phase residual.
// Android ADR itself is retained unchanged in gnss_raw.csv.
class RtcmMsm7 {
    private data class Arc(val offset: Double, val start: Long, var last: Long)
    private val arcs = mutableMapOf<String, Arc>()
    fun reset() = arcs.clear()
    fun encode(gpsNs: Long, leap: Int, observations: List<PhoneObservation>): List<ByteArray> {
        val groups = observations.groupBy { it.system }.toSortedMap().values.flatMap { list ->
            val unique = list.groupBy { it.satellite to it.signal }.values.map { it.maxBy { o -> o.cn0 } }
            val signals = unique.map { it.signal }.distinct().size
            unique.groupBy { it.satellite }.toSortedMap().values.chunked(max(1, 64 / signals))
                .map { it.flatten() }
        }
        return groups.mapIndexed { index, group -> message(gpsNs, leap, group, index < groups.lastIndex) }
    }
    private fun message(gpsNs: Long, leap: Int, obs: List<PhoneObservation>, more: Boolean): ByteArray {
        val sys = obs.first().system
        val type = mapOf(1 to 1077, 2 to 1107, 3 to 1087, 4 to 1117, 5 to 1127, 6 to 1097, 7 to 1137).getValue(sys)
        val sats = obs.map { it.satellite }.distinct().sorted()
        val sigs = obs.map { it.signal }.distinct().sorted()
        val byCell = obs.associateBy { it.satellite to it.signal }
        val cells = sats.flatMap { s -> sigs.mapNotNull { byCell[s to it] } }
        val base = sats.associateWith { s -> obs.first { it.satellite == s } }
        val rough = base.mapValues { (_, o) -> (o.range / (CaptureFormats.C * .001) * 1024).roundToLong() }
        val roughRate = base.mapValues { (_, o) -> o.rate?.takeIf { abs(it) < 8191 }?.roundToInt() }
        val phase = mutableListOf<Double?>(); val lock = mutableListOf<Int>()
        cells.forEach { o ->
            val key = "$sys/${o.satellite}/${o.signal}"
            if (o.phaseMeters == null) { arcs.remove(key); phase.add(null); lock.add(0) }
            else {
                val r = rough.getValue(o.satellite) * (CaptureFormats.C * .001) / 1024
                val wavelength = CaptureFormats.C / o.frequency
                var arc = arcs[key]
                if (arc == null || o.adrState and 6 != 0 || gpsNs - arc.last !in 1..2000000000L ||
                    abs(o.phaseMeters - arc.offset - r) > 1100) {
                    arc = Arc(((o.phaseMeters - r) / wavelength).roundToLong() * wavelength, gpsNs, gpsNs)
                    arcs[key] = arc
                }
                arc.last = gpsNs
                phase.add(o.phaseMeters - arc.offset - r)
                lock.add(lockIndicator((gpsNs - arc.start) / 1000000))
            }
        }
        val bits = Bits()
        bits.put(12, type.toLong()); bits.put(12, 0)
        val shift = when (sys) { 3 -> (10800 - leap) * 1000000000L; 5 -> -14000000000L; else -> 0L }
        val ms = Math.floorMod((gpsNs + shift + 500000) / 1000000, 604800000L)
        bits.put(30, if (sys == 3) ((ms / 86400000) shl 27) + ms % 86400000 else ms)
        bits.put(1, if (more) 1 else 0); bits.put(18, 0)
        for (s in 1..64) bits.put(1, if (s in sats) 1 else 0)
        for (s in 1..32) bits.put(1, if (s in sigs) 1 else 0)
        for (s in sats) for (g in sigs) bits.put(1, if (byCell.containsKey(s to g)) 1 else 0)
        sats.forEach { bits.put(8, rough.getValue(it) shr 10) }
        sats.forEach { bits.put(4, if (sys == 3) (base.getValue(it).gloChannel + 7).toLong() else 0) }
        sats.forEach { bits.put(10, rough.getValue(it) and 1023) }
        sats.forEach { bits.put(14, (roughRate[it] ?: -8192).toLong()) }
        cells.forEach { bits.signed(20, it.range - rough.getValue(it.satellite) * (CaptureFormats.C * .001) / 1024, CaptureFormats.C * .001 / 2.0.pow(29)) }
        phase.forEach { bits.signed(24, it, CaptureFormats.C * .001 / 2.0.pow(31)) }
        lock.forEach { bits.put(10, it.toLong()) }
        cells.forEach { bits.put(1, if (it.adrState and 8 == 0) 1 else 0) }
        cells.forEach { bits.put(10, (it.cn0 * 16).roundToLong().coerceIn(0, 1023)) }
        cells.forEach { o -> bits.signed(15, roughRate[o.satellite]?.let { o.rate?.minus(it) }, .0001) }
        val data = bits.bytes()
        require(data.size <= 1023)
        val packet = byteArrayOf(0xd3.toByte(), (data.size shr 8).toByte(), data.size.toByte()) + data
        val crc = crc24q(packet)
        return packet + byteArrayOf((crc shr 16).toByte(), (crc shr 8).toByte(), crc.toByte())
    }
    companion object {
        fun lockIndicator(ms: Long): Int {
            if (ms < 64) return ms.coerceAtLeast(0).toInt()
            for (i in 1..20) {
                val step = 1L shl i
                if (ms < 64 * step) return (32 * i + ms / step).toInt()
            }
            return 704
        }
        fun crc24q(data: ByteArray): Int {
            var crc = 0
            for (b in data) {
                crc = crc xor ((b.toInt() and 255) shl 16)
                repeat(8) { crc = (crc shl 1) xor (if (crc and 0x800000 != 0) 0x1864cfb else 0) }
            }
            return crc and 0xffffff
        }
    }
    private class Bits {
        private val buffer = ByteArrayOutputStream(); private var byte = 0; private var used = 0
        fun put(n: Int, value: Long) {
            for (i in n - 1 downTo 0) {
                byte = (byte shl 1) or ((value ushr i).toInt() and 1)
                if (++used == 8) { buffer.write(byte); byte = 0; used = 0 }
            }
        }
        fun signed(n: Int, value: Double?, unit: Double) {
            val invalid = -(1L shl (n - 1))
            val integer = value?.takeIf { it.isFinite() }?.let { (it / unit).roundToLong() }
            put(n, integer?.takeIf { it > invalid && it < -invalid } ?: invalid)
        }
        fun bytes(): ByteArray { if (used > 0) buffer.write(byte shl (8 - used)); return buffer.toByteArray() }
    }
}
