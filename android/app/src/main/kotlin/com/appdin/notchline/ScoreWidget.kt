package com.appdin.notchline

import android.content.Context
import android.text.format.DateUtils
import android.util.Log
import androidx.compose.runtime.Composable
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.datastore.preferences.core.longPreferencesKey
import androidx.glance.Button
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.GlanceTheme
import androidx.glance.action.actionStartActivity
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetManager
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.action.actionStartActivity
import androidx.glance.appwidget.cornerRadius
import androidx.glance.appwidget.provideContent
import androidx.glance.appwidget.state.updateAppWidgetState
import androidx.glance.appwidget.updateAll
import androidx.glance.background
import androidx.glance.currentState
import androidx.glance.layout.Alignment
import androidx.glance.layout.Column
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.layout.width
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import com.appdin.notchline.core.CatalogLocation
import com.appdin.notchline.core.LocationResponse
import org.json.JSONException
import org.json.JSONObject
import java.text.DateFormat

/**
 * The home screen widget for the selected location: the next day with a score, its headline and
 * other terrain's scores and the lift time. Tapping it opens the app, and Directions opens Google
 * Maps. The widget can't call the core, so each plan of the selected location stores what it
 * shows, in the app or the background refresh, and redraws it.
 */
class ScoreWidget : GlanceAppWidget() {
    override suspend fun provideGlance(context: Context, id: GlanceId) {
        provideContent {
            // show() bumps the version, so this reruns and rereads what it stored.
            currentState(VERSION_KEY)
            GlanceTheme { Content(context, stored(context)) }
        }
    }

    @Composable
    private fun Content(context: Context, shown: Shown?) {
        val secondary = TextStyle(color = GlanceTheme.colors.onSurfaceVariant, fontSize = 13.sp)
        Column(
            GlanceModifier.fillMaxSize()
                .background(GlanceTheme.colors.widgetBackground)
                .cornerRadius(16.dp)
                .padding(12.dp)
                .clickable(actionStartActivity<MainActivity>()),
        ) {
            if (shown == null) {
                Text("Open Notchline to see scores.", style = secondary)
                return@Column
            }
            Text(shown.locationName, style = secondary, maxLines = 1)
            Text(shown.dayTitle ?: "", style = TextStyle(color = GlanceTheme.colors.onSurface, fontSize = 15.sp, fontWeight = FontWeight.Medium))
            Spacer(GlanceModifier.height(4.dp))
            if (shown.headline == null) {
                Text(shown.message ?: "", style = secondary)
            } else {
                Row(verticalAlignment = Alignment.Bottom) {
                    Text("${shown.headline.score}", style = TextStyle(color = GlanceTheme.colors.onSurface, fontSize = 32.sp, fontWeight = FontWeight.Bold))
                    Spacer(GlanceModifier.width(4.dp))
                    Text(shown.headline.terrain, style = secondary, modifier = GlanceModifier.padding(bottom = 6.dp))
                    shown.other?.let { other ->
                        Spacer(GlanceModifier.width(12.dp))
                        Text("${other.score}", style = TextStyle(color = GlanceTheme.colors.onSurface, fontSize = 20.sp, fontWeight = FontWeight.Medium))
                        Spacer(GlanceModifier.width(4.dp))
                        Text(other.terrain, style = secondary, modifier = GlanceModifier.padding(bottom = 3.dp))
                    }
                }
                shown.liftTime?.let { Text("Be on the lift by $it", style = secondary) }
            }
            // Android redraws the widget hourly, so scores the background refresh hasn't replaced in a while say when they are from.
            val now = System.currentTimeMillis()
            if (now - shown.updatedAtMillis > STALE_AFTER_MS) {
                Text("Updated ${DateUtils.formatSameDayTime(shown.updatedAtMillis, now, DateFormat.SHORT, DateFormat.SHORT)}", style = secondary)
            }
            Spacer(GlanceModifier.defaultWeight())
            Button("Directions", actionStartActivity(Directions.intent(context, shown.latitude, shown.longitude)))
        }
    }

    /** What the widget shows, kept from the last plan of the selected location. */
    private class Shown(
        val locationName: String,
        val latitude: Double,
        val longitude: Double,
        val updatedAtMillis: Long,
        /** `Today`, `Tomorrow` or the weekday. null when there was no plan. */
        val dayTitle: String?,
        val headline: Score?,
        val other: Score?,
        val liftTime: String?,
        /** Why there is no score, in place of the scores. */
        val message: String?,
    ) {
        fun toJson(): JSONObject = JSONObject()
            .put("locationName", locationName).put("latitude", latitude).put("longitude", longitude)
            .put("updatedAtMillis", updatedAtMillis)
            .putOpt("dayTitle", dayTitle).putOpt("headline", headline?.toJson()).putOpt("other", other?.toJson())
            .putOpt("liftTime", liftTime).putOpt("message", message)

        companion object {
            fun from(json: JSONObject) = Shown(
                json.getString("locationName"), json.getDouble("latitude"), json.getDouble("longitude"),
                json.getLong("updatedAtMillis"),
                json.optString("dayTitle").ifEmpty { null },
                json.optJSONObject("headline")?.let(Score::from), json.optJSONObject("other")?.let(Score::from),
                json.optString("liftTime").ifEmpty { null }, json.optString("message").ifEmpty { null })
        }
    }

    private class Score(val score: Int, val terrain: String) {
        fun toJson(): JSONObject = JSONObject().put("score", score).put("terrain", terrain)

        companion object {
            fun from(json: JSONObject) = Score(json.getInt("score"), json.getString("terrain"))
        }
    }

    companion object {
        private const val TAG = "Notchline"
        private const val STORED_KEY = "widget"
        private const val STALE_AFTER_MS = 2 * 60 * 60 * 1000L
        private val VERSION_KEY = longPreferencesKey("updatedAtMillis")

        /**
         * Stores what the widget shows from a plan of the selected [location] and redraws it. The
         * day is today while it has a score, so after the lifts close it moves on to tomorrow,
         * which shows why when it has none.
         */
        suspend fun show(context: Context, location: CatalogLocation, response: LocationResponse) {
            val days = response.planner?.days.orEmpty()
            val day = days.firstOrNull()?.takeIf { it.scores.isNotEmpty() } ?: days.getOrNull(1) ?: days.firstOrNull()
            val scores = day?.scores.orEmpty().map { Score(it.score, it.terrain) }
            val shown = Shown(
                location.name, location.latitude, location.longitude, System.currentTimeMillis(),
                day?.title, scores.getOrNull(0), scores.getOrNull(1), day?.liftTime,
                day?.noScoreReason ?: response.plannerMessage)
            prefs(context).edit().putString(STORED_KEY, shown.toJson().toString()).apply()
            try {
                GlanceAppWidgetManager(context).getGlanceIds(ScoreWidget::class.java).forEach { id ->
                    updateAppWidgetState(context, id) { it[VERSION_KEY] = shown.updatedAtMillis }
                }
                ScoreWidget().updateAll(context)
            } catch (error: IllegalStateException) {
                Log.e(TAG, "Widget update failed: ${error.message}")
            }
        }

        /** null before the first planner run, or when what was stored can't be read. */
        private fun stored(context: Context): Shown? = try {
            prefs(context).getString(STORED_KEY, null)?.let { Shown.from(JSONObject(it)) }
        } catch (error: JSONException) {
            null
        }

        private fun prefs(context: Context) = context.getSharedPreferences("notchline", Context.MODE_PRIVATE)
    }
}

class ScoreWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget = ScoreWidget()
}
