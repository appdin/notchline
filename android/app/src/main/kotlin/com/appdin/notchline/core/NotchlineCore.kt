package com.appdin.notchline.core

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * The Swift core, through the JNI entry points in android/swift/Sources/NotchlineJNI. Values cross
 * as UTF-8 JSON in byte arrays. Native calls block until the core's async work finishes, so the
 * suspending wrappers run them on the IO dispatcher.
 */
object NotchlineCore {
    init {
        System.loadLibrary("NotchlineJNI")
    }

    @JvmStatic private external fun configure(locationsJson: ByteArray, snapshotsDir: ByteArray): ByteArray

    @JvmStatic private external fun conditions(locationId: ByteArray, units: ByteArray): ByteArray

    @JvmStatic private external fun refresh(locationId: ByteArray, units: ByteArray): ByteArray

    @Volatile private var regions: List<CatalogRegion>? = null

    /**
     * Loads the location catalog from the app's assets into the core, with snapshots cached in the
     * app's files directory, and returns the catalog by region. Safe to call more than once.
     */
    @Synchronized
    fun start(context: Context): List<CatalogRegion> {
        regions?.let { return it }
        val json = context.assets.open("locations.json").use { it.readBytes() }
        val snapshots = File(context.filesDir, "snapshots").path
        val array = JSONArray(decode(configure(json, snapshots.encode())))
        return List(array.length()) { CatalogRegion.from(array.getJSONObject(it)) }.also { regions = it }
    }

    /** The location's cached conditions, without fetching. */
    suspend fun conditions(locationId: String, units: UnitPreference): ConditionsSummary = withContext(Dispatchers.IO) {
        ConditionsSummary.from(JSONObject(decode(conditions(locationId.encode(), units.raw.encode()))))
    }

    /** Fetches the location and returns its conditions. Failed metrics keep their cached values, marked stale. */
    suspend fun refresh(locationId: String, units: UnitPreference): ConditionsSummary = withContext(Dispatchers.IO) {
        ConditionsSummary.from(JSONObject(decode(refresh(locationId.encode(), units.raw.encode()))))
    }

    private fun String.encode() = toByteArray(Charsets.UTF_8)

    private fun decode(bytes: ByteArray) = String(bytes, Charsets.UTF_8)
}

/** Units picked in settings, as the core's `UnitPreference`. Automatic follows the location's country. */
enum class UnitPreference(val raw: String) {
    AUTOMATIC("automatic"), IMPERIAL("imperial"), METRIC("metric");

    companion object {
        fun from(raw: String?) = entries.firstOrNull { it.raw == raw } ?: AUTOMATIC
    }
}

/** A location from the core's bundled catalog. */
data class CatalogLocation(val id: String, val name: String, val defaultUnitsMetric: Boolean)

data class CatalogRegion(val region: String, val locations: List<CatalogLocation>) {
    companion object {
        fun from(json: JSONObject): CatalogRegion {
            val locations = json.getJSONArray("locations")
            return CatalogRegion(json.getString("region"), List(locations.length()) { index ->
                val location = locations.getJSONObject(index)
                CatalogLocation(location.getString("id"), location.getString("name"), location.getString("defaultUnits") == "metric")
            })
        }
    }
}

/** The core's `ConditionsSummary`: display strings for the conditions screen. */
data class ConditionsSummary(
    val locationName: String,
    val status: String,
    val isRefreshing: Boolean,
    val base: MetricSummary,
    val last24h: MetricSummary,
    val next24h: MetricSummary,
    val tempNow: MetricSummary,
    val highLow: MetricSummary,
    val wind: MetricSummary,
    val avalanche: AvalancheSummary,
) {
    companion object {
        fun from(json: JSONObject) = ConditionsSummary(
            locationName = json.getString("locationName"),
            status = json.getString("status"),
            isRefreshing = json.getBoolean("isRefreshing"),
            base = MetricSummary.from(json.getJSONObject("base")),
            last24h = MetricSummary.from(json.getJSONObject("last24h")),
            next24h = MetricSummary.from(json.getJSONObject("next24h")),
            tempNow = MetricSummary.from(json.getJSONObject("tempNow")),
            highLow = MetricSummary.from(json.getJSONObject("highLow")),
            wind = MetricSummary.from(json.getJSONObject("wind")),
            avalanche = AvalancheSummary.from(json.getJSONObject("avalanche")),
        )
    }
}

/** Whether a value is dimmed, its age when stale or outdated, and the last refresh's problems with it. */
data class MetricState(val dimmed: Boolean, val age: String?, val problems: List<String>) {
    companion object {
        fun from(json: JSONObject): MetricState {
            val problems = json.getJSONArray("problems")
            return MetricState(json.getBoolean("dimmed"), json.stringOrNull("age"), List(problems.length()) { problems.getString(it) })
        }
    }
}

data class MetricSummary(val title: String, val value: String?, val caption: String, val state: MetricState) {
    companion object {
        fun from(json: JSONObject) = MetricSummary(
            json.getString("title"), json.stringOrNull("value"), json.getString("caption"), MetricState.from(json.getJSONObject("state")))
    }
}

/** The avalanche line. [level] is the danger scale's 0 (no rating) to 5, or null when there is no danger to show. */
data class AvalancheSummary(val level: Int?, val headline: String, val bands: String?, val forecastUrl: String?, val state: MetricState) {
    companion object {
        fun from(json: JSONObject) = AvalancheSummary(
            level = if (json.has("level")) json.getInt("level") else null,
            headline = json.getString("headline"),
            bands = json.stringOrNull("bands"),
            forecastUrl = json.stringOrNull("forecastURL"),
            state = MetricState.from(json.getJSONObject("state")),
        )
    }
}

/** The core's encoder leaves out nil values. */
private fun JSONObject.stringOrNull(key: String): String? = if (has(key) && !isNull(key)) getString(key) else null
