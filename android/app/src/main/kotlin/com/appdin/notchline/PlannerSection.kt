package com.appdin.notchline

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
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
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
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
import com.appdin.notchline.core.CatalogLocation
import com.appdin.notchline.core.PlannerDay

/**
 * Snow condition scores: a day picker, both scores, the best window for each terrain, confidence,
 * and a button that opens Google Maps driving directions to the location. The app plans no
 * departures, so the user checks Maps' ETA against the lift time shown here.
 */
@Composable
fun PlannerSection(state: ConditionsUiState, onExplain: (title: String, lines: List<String>) -> Unit) {
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
            return@Column
        }
        val index = selected.coerceIn(0, days.lastIndex)
        Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            days.forEachIndexed { i, day ->
                FilterChip(selected = i == index, onClick = { selected = i }, label = { Text(day.title) })
            }
        }
        Day(days[index], state.location, onExplain)
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
        Button(onClick = { openDirections(context, location) }) { Text("Directions") }
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

/**
 * Google Maps driving directions from the phone's location to [location]. Maps URLs can't set an
 * arrival time, so Maps gives the live ETA. Opens in the browser when Google Maps isn't installed.
 */
private fun openDirections(context: Context, location: CatalogLocation) {
    val uri = Uri.parse("https://www.google.com/maps/dir/").buildUpon()
        .appendQueryParameter("api", "1")
        .appendQueryParameter("destination", "${location.latitude},${location.longitude}")
        .appendQueryParameter("travelmode", "driving")
        .build()
    val maps = Intent(Intent.ACTION_VIEW, uri).setPackage(GOOGLE_MAPS_PACKAGE)
    try {
        context.startActivity(maps)
    } catch (_: ActivityNotFoundException) {
        context.startActivity(Intent(Intent.ACTION_VIEW, uri))
    }
}

private const val GOOGLE_MAPS_PACKAGE = "com.google.android.apps.maps"
