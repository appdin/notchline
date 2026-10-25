package com.appdin.notchline.core

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.Locale

/**
 * The Swift core, through the JNI entry points in android/swift/Sources/NotchlineJNI. Values cross
 * as UTF-8 JSON in byte arrays. Native calls block until the core's async work finishes, so the
 * suspending wrappers run them on the IO dispatcher.
 */
object NotchlineCore {
    init {
        System.loadLibrary("NotchlineJNI")
    }

    @JvmStatic private external fun configure(locationsJson: ByteArray, confidenceJson: ByteArray, snapshotsDir: ByteArray): ByteArray

    @JvmStatic private external fun conditions(request: ByteArray): ByteArray

    @JvmStatic private external fun refresh(request: ByteArray): ByteArray

    @JvmStatic private external fun plan(request: ByteArray): ByteArray

    @Volatile private var regions: List<CatalogRegion>? = null

    /**
     * Loads the location catalog and confidence table from the app's assets into the core, with
     * snapshots cached in the app's files directory, and returns the catalog by region. Safe to
     * call more than once.
     */
    @Synchronized
    fun start(context: Context): List<CatalogRegion> {
        regions?.let { return it }
        val locations = context.assets.open("locations.json").use { it.readBytes() }
        val confidence = context.assets.open("confidence.json").use { it.readBytes() }
        val snapshots = File(context.filesDir, "snapshots").path
        val array = JSONArray(decode(configure(locations, confidence, snapshots.encode())))
        return List(array.length()) { CatalogRegion.from(array.getJSONObject(it)) }.also { regions = it }
    }

    /** The location's cached conditions and latest plan, without fetching or planning. */
    suspend fun conditions(locationId: String, units: UnitPreference): LocationResponse = call(::conditions, locationId, units)

    /** Fetches the location's conditions. Failed metrics keep their cached values, marked stale. */
    suspend fun refresh(locationId: String, units: UnitPreference): LocationResponse = call(::refresh, locationId, units)

    /** Plans the location from its cached conditions, without departures. Fetches the comparison models for confidence. */
    suspend fun plan(locationId: String, units: UnitPreference): LocationResponse = call(::plan, locationId, units)

    private suspend fun call(native: (ByteArray) -> ByteArray, locationId: String, units: UnitPreference) = withContext(Dispatchers.IO) {
        val request = JSONObject()
            .put("locationID", locationId)
            .put("units", units.raw)
            .put("locale", Locale.getDefault().toLanguageTag())
        LocationResponse.from(JSONObject(decode(native(request.toString().encode()))))
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

/** A location from the core's bundled catalog, with the coordinate directions go to. */
data class CatalogLocation(val id: String, val name: String, val defaultUnitsMetric: Boolean, val latitude: Double, val longitude: Double)

data class CatalogRegion(val region: String, val locations: List<CatalogLocation>) {
    companion object {
        fun from(json: JSONObject): CatalogRegion {
            val locations = json.getJSONArray("locations")
            return CatalogRegion(json.getString("region"), List(locations.length()) { index ->
                val location = locations.getJSONObject(index)
                CatalogLocation(
                    location.getString("id"), location.getString("name"), location.getString("defaultUnits") == "metric",
                    location.getDouble("latitude"), location.getDouble("longitude"))
            })
        }
    }
}

/**
 * What the screen shows for one location. [planned] is true once it was planned this session;
 * [plannerMessage] then stands in for a null [planner]. [scoreHelp] explains the scores, one paragraph each.
 */
data class LocationResponse(
    val conditions: ConditionsSummary,
    val planner: PlannerSummary?,
    val planned: Boolean,
    val plannerMessage: String?,
    val scoreHelp: List<String>,
) {
    companion object {
        fun from(json: JSONObject) = LocationResponse(
            ConditionsSummary.from(json.getJSONObject("conditions")),
            json.optJSONObject("planner")?.let(PlannerSummary::from),
            json.getBoolean("planned"),
            json.stringOrNull("plannerMessage"),
            json.getJSONArray("scoreHelp").strings(),
        )
    }
}

/** The core's `PlannerSummary`: each planned day's scores, best windows and confidence. */
data class PlannerSummary(val days: List<PlannerDay>, val warnings: List<String>) {
    companion object {
        fun from(json: JSONObject) = PlannerSummary(
            json.getJSONArray("days").objects().map(PlannerDay::from),
            json.getJSONArray("warnings").strings(),
        )
    }
}

data class PlannerDay(
    val title: String,
    /** Scored terrains, the headline first. Empty when no hour is skiable, and [noScoreReason] says why. */
    val scores: List<TerrainScore>,
    val confidence: String?,
    val confidenceNotes: List<String>,
    val rows: List<TerrainRow>,
    val noScoreReason: String?,
    /** When to be on the lift for the headline terrain's best window. */
    val liftTime: String?,
) {
    companion object {
        fun from(json: JSONObject) = PlannerDay(
            title = json.getString("title"),
            scores = json.getJSONArray("scores").objects().map {
                TerrainScore(it.getString("terrain"), it.getInt("score"), it.getBoolean("isHeadline"))
            },
            confidence = json.stringOrNull("confidence"),
            confidenceNotes = json.getJSONArray("confidenceNotes").strings(),
            rows = json.getJSONArray("rows").objects().map { TerrainRow(it.getString("label"), it.getString("window")) },
            noScoreReason = json.stringOrNull("noScoreReason"),
            liftTime = json.stringOrNull("liftTime"),
        )
    }
}

/** [terrain] is `groomed` or `ungroomed`. */
data class TerrainScore(val terrain: String, val score: Int, val isHeadline: Boolean)

/** A best window. Android plans without departures, so the core's advice and drive details are always empty here. */
data class TerrainRow(val label: String, val window: String)

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
            return MetricState(json.getBoolean("dimmed"), json.stringOrNull("age"), json.getJSONArray("problems").strings())
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

private fun JSONArray.objects(): List<JSONObject> = List(length()) { getJSONObject(it) }

private fun JSONArray.strings(): List<String> = List(length()) { getString(it) }

/** The core's encoder leaves out nil values. */
private fun JSONObject.stringOrNull(key: String): String? = if (has(key) && !isNull(key)) getString(key) else null
