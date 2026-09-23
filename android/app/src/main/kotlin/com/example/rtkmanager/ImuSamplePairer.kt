package com.example.rtkmanager

import java.util.ArrayDeque
import kotlin.math.abs

data class TimedAxes(val timestamp: Long, val values: FloatArray)
data class PairedImu(val accel: TimedAxes, val gyro: TimedAxes)

/** One-to-one, chronological pairing within half the requested IMU period.
 * No sample reuse, interpolation or fabricated zeros. Original times remain available.
 */
class ImuSamplePairer(val toleranceNs: Long) {
    private val accel = ArrayDeque<TimedAxes>()
    private val gyro = ArrayDeque<TimedAxes>()
    private val last = mutableMapOf<String, Long>()
    var dropped: Long = 0; private set

    fun add(key: String, timestamp: Long, values: FloatArray): List<PairedImu> {
        require(key == "accel" || key == "gyro")
        if (timestamp <= (last[key] ?: 0) || values.size < 3 || values.take(3).any { !it.isFinite() }) {
            dropped++; return emptyList()
        }
        last[key] = timestamp
        val queue = if (key == "accel") accel else gyro
        queue.addLast(TimedAxes(timestamp, values.copyOf(3)))
        if (queue.size > 256) { queue.removeFirst(); dropped++ }
        val result = mutableListOf<PairedImu>()
        while (accel.isNotEmpty() && gyro.isNotEmpty()) {
            val a = accel.first; val g = gyro.first
            when {
                abs(a.timestamp - g.timestamp) <= toleranceNs ->
                    result.add(PairedImu(accel.removeFirst(), gyro.removeFirst()))
                a.timestamp < g.timestamp -> { accel.removeFirst(); dropped++ }
                else -> { gyro.removeFirst(); dropped++ }
            }
        }
        return result
    }

    fun finish() { dropped += accel.size + gyro.size; accel.clear(); gyro.clear() }
}

/** Frequency from hardware sample timestamps, independent of callback batching. */
class SensorSampleRate {
    private val times = ArrayDeque<Long>()
    private var first = 0L
    private var last = 0L
    private var count = 0L
    fun add(timestamp: Long) {
        if (timestamp <= last) return
        if (count++ == 0L) first = timestamp
        last = timestamp
        times.addLast(timestamp)
        while (times.size > 1024 || (times.size > 2 && timestamp - times.first > 2000000000L)) times.removeFirst()
    }
    fun hz(now: Long): Double = if (times.size < 2 || now - last > 2000000000L) 0.0
        else (times.size - 1) * 1e9 / (times.last - times.first)
    fun averageHz(): Double = if (count < 2 || last <= first) 0.0 else (count - 1) * 1e9 / (last - first)
}
