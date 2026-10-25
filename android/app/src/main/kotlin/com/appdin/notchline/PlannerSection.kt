package com.appdin.notchline

import android.app.NotificationManager
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.LifecycleResumeEffect
import com.appdin.notchline.core.CatalogLocation
import com.appdin.notchline.core.PlannerDay
import com.appdin.notchline.core.Rating
import com.appdin.notchline.core.RatableDay

/**
 * Snow condition scores: a day picker, both scores, the best window for each terrain, confidence,
 * and a button that opens Google Maps driving directions to the location. The app plans no
 * departures, so the user checks Maps' ETA against the lift time shown here. Also a way to rate a
 * recent day, which nothing asks for, and what keeps notifications from arriving on time.
 */
@Composable
fun PlannerSection(state: ConditionsUiState, actions: ScreenActions, onExplain: (title: String, lines: List<String>) -> Unit) {
    var showsHelp by rememberSaveable { mutableStateOf(false) }
    var selected by rememberSaveable(state.location.id) { mutableIntStateOf(0) }
    val days = state.planner?.days.orEmpty()

    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("Snow condition scores", style = MaterialTheme.typography.titleMedium)
            Text(
                if (showsHelp) "Hide ?" else "?",
                color = MaterialTheme.colorScheme.primary,
                modifier = Modifier.clickable { showsHelp = !showsHelp }.padding(4.dp),
            )
            state.planner?.warnings?.takeIf { it.isNotEmpty() }?.let { warnings ->
                Text(
                    "ⓘ",
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.clickable { onExplain("Planner", warnings) }.padding(4.dp),
                )
            }
            Spacer(Modifier.weight(1f))
            if (state.planning) CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
        }
        if (showsHelp) ScoreHelp(state.scoreHelp)

        if (days.isEmpty()) {
            val message = state.plannerMessage ?: if (state.planning || !state.planned) "Planning…" else null
            message?.let { Text(it, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant) }
        } else {
            val index = selected.coerceIn(0, days.lastIndex)
            Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                days.forEachIndexed { i, day ->
                    FilterChip(selected = i == index, onClick = { selected = i }, label = { Text(day.title) })
                }
            }
            Day(days[index], state.location, onExplain)
        }
        TextButton(onClick = actions.openRatings) { Text("Rate a day you skied") }
        if (state.settings.notifyThreshold != null) DeliveryNotes()
    }

    state.ratingDays?.takeIf { it.isNotEmpty() }?.let { RatingDialog(it, actions) }
}

/**
 * Rates one of the location's recent days: groomed, ungroomed or both from 1 to 5, as on the Mac.
 * A day already rated starts from its rating, marked ✓ in the picker, and saving replaces it. The
 * Mac's optional left-home and on-lift times are left out.
 */
@Composable
private fun RatingDialog(days: List<RatableDay>, actions: ScreenActions) {
    var index by remember(days) { mutableIntStateOf(0) }
    val day = days[index]
    var groomed by remember(day) { mutableStateOf(day.groomed) }
    var ungroomed by remember(day) { mutableStateOf(day.ungroomed) }
    AlertDialog(
        onDismissRequest = actions.closeRatings,
        title = { Text(day.title) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    days.forEachIndexed { i, option ->
                        FilterChip(
                            selected = i == index,
                            onClick = { index = i },
                            label = { Text(if (option.isRated) "${option.label} ✓" else option.label) },
                        )
                    }
                }
                Text(day.note, style = MaterialTheme.typography.bodyMedium)
                RatingRow("Groomed", groomed) { groomed = it }
                RatingRow("Ungroomed", ungroomed) { ungroomed = it }
            }
        },
        confirmButton = {
            TextButton(
                onClick = { actions.rate(Rating(day.day, groomed = groomed, ungroomed = ungroomed)) },
                enabled = (groomed != null || ungroomed != null) && (groomed != day.groomed || ungroomed != day.ungroomed),
            ) { Text("Save") }
        },
        dismissButton = { TextButton(onClick = actions.closeRatings) { Text("Cancel") } },
    )
}

/** 1 to 5, or none for terrain not skied. Tapping the chosen score again clears it. */
@Composable
private fun RatingRow(label: String, value: Int?, onChange: (Int?) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(label, style = MaterialTheme.typography.labelLarge)
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            (1..5).forEach { score ->
                FilterChip(selected = value == score, onClick = { onChange(if (value == score) null else score) }, label = { Text("$score") })
            }
        }
    }
}

/**
 * What keeps the evening summary from arriving on time, with a way to fix each: notifications
 * turned off, no exact alarm permission, and battery optimization, which Samsung phones apply
 * by default. Rechecked each time the app comes back from Settings.
 */
@Composable
private fun DeliveryNotes() {
    val context = LocalContext.current
    var checks by remember { mutableIntStateOf(0) }
    LifecycleResumeEffect(Unit) {
        checks++
        onPauseOrDispose {}
    }
    val notes = remember(checks) {
        val packageUri = Uri.fromParts("package", context.packageName, null)
        buildList {
            if (!context.getSystemService(NotificationManager::class.java).areNotificationsEnabled()) {
                add("Notifications are off, so summaries won't arrive." to
                    Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName))
            }
            if (!PlannerAlarms.firesOnTime(context) && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                add("Without the alarms permission, summaries can arrive late." to
                    Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM, packageUri))
            }
            if (!context.getSystemService(PowerManager::class.java).isIgnoringBatteryOptimizations(context.packageName)) {
                add("If summaries arrive late, set Notchline's battery use to Unrestricted under Battery." to
                    Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, packageUri))
            }
        }
    }
    notes.forEach { (note, intent) ->
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(note, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.weight(1f))
            TextButton(onClick = { context.startActivity(intent) }) { Text("Settings") }
        }
    }
}

@Composable
private fun Day(day: PlannerDay, location: CatalogLocation, onExplain: (String, List<String>) -> Unit) {
    val context = LocalContext.current
    day.noScoreReason?.let {
        Text(it, style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
        return
    }
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
            day.scores.forEach { score ->
                Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(
                        "${score.score}",
                        style = if (score.isHeadline) MaterialTheme.typography.headlineMedium else MaterialTheme.typography.titleLarge,
                        fontWeight = FontWeight.SemiBold,
                    )
                    Text(
                        score.terrain,
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(bottom = 4.dp),
                    )
                }
            }
            Spacer(Modifier.weight(1f))
            day.confidence?.let {
                Text(
                    "$it ⓘ",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.clickable { onExplain("Confidence", day.confidenceNotes) }.padding(bottom = 4.dp),
                )
            }
        }
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            day.rows.forEach { row ->
                Row {
                    Text(row.label, style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.SemiBold, modifier = Modifier.width(96.dp))
                    Text(row.window, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }
        day.liftTime?.let { lift ->
            Text(
                "Be on the lift by $lift. Check the drive time in Google Maps against it.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Button(onClick = { context.startActivity(Directions.intent(context, location.latitude, location.longitude)) }) {
            Text("Directions")
        }
    }
}

@Composable
private fun ScoreHelp(paragraphs: List<String>) {
    Column(
        Modifier.fillMaxWidth()
            .background(MaterialTheme.colorScheme.surfaceVariant, RoundedCornerShape(8.dp))
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        paragraphs.forEach {
            Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}
