package com.appdin.notchline

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.sizeIn
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.appdin.notchline.core.AvalancheSummary
import com.appdin.notchline.core.CatalogLocation
import com.appdin.notchline.core.CatalogRegion
import com.appdin.notchline.core.ConditionsSummary
import com.appdin.notchline.core.MetricState
import com.appdin.notchline.core.MetricSummary
import com.appdin.notchline.core.UnitPreference

/** Dimmed values match the Mac's opacity for stale, outdated and cached values. */
private const val DIMMED_ALPHA = 0.45f

/**
 * Header with the location picker and units menu, the snow, temperature and wind metrics and the
 * avalanche summary. Pull down to refresh. Tapping a value with problems in its last refresh
 * explains them, where the Mac shows a tooltip.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ConditionsScreen(
    state: ConditionsUiState,
    onSelect: (CatalogLocation) -> Unit,
    onUnits: (UnitPreference) -> Unit,
    onRefresh: () -> Unit,
) {
    var problems by remember { mutableStateOf<List<String>?>(null) }
    val refreshing = state.refreshing || state.summary?.isRefreshing == true

    Scaffold(
        topBar = {
            TopAppBar(
                title = { LocationPicker(state.regions, state.location, onSelect) },
                actions = { UnitsMenu(state.units, state.location, onUnits) },
            )
        },
    ) { padding ->
        PullToRefreshBox(isRefreshing = refreshing, onRefresh = onRefresh, modifier = Modifier.padding(padding).fillMaxSize()) {
            Column(
                Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(20.dp),
            ) {
                Text(
                    state.summary?.status ?: if (refreshing) "loading" else "",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                state.error?.let {
                    Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodyMedium)
                }
                state.summary?.let { summary ->
                    Metrics(summary) { problems = it }
                    HorizontalDivider()
                    Avalanche(summary.avalanche) { problems = it }
                }
            }
        }
    }

    problems?.let {
        AlertDialog(
            onDismissRequest = { problems = null },
            confirmButton = { TextButton(onClick = { problems = null }) { Text("OK") } },
            title = { Text("Last refresh") },
            text = { Text(it.joinToString("\n")) },
        )
    }
}

@Composable
private fun LocationPicker(regions: List<CatalogRegion>, selected: CatalogLocation, onSelect: (CatalogLocation) -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    Box {
        Text(
            "${selected.name} ▾",
            modifier = Modifier.clickable { expanded = true }.padding(vertical = 8.dp),
            maxLines = 1,
        )
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            regions.forEach { region ->
                Text(
                    region.region,
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                )
                region.locations.forEach { location ->
                    DropdownMenuItem(
                        text = {
                            Text(location.name, fontWeight = if (location.id == selected.id) FontWeight.SemiBold else null)
                        },
                        onClick = { expanded = false; onSelect(location) },
                    )
                }
            }
        }
    }
}

@Composable
private fun UnitsMenu(units: UnitPreference, location: CatalogLocation, onUnits: (UnitPreference) -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    Box {
        TextButton(onClick = { expanded = true }) { Text("Units") }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            val labels = mapOf(
                UnitPreference.AUTOMATIC to "Automatic (${if (location.defaultUnitsMetric) "Metric" else "Imperial"})",
                UnitPreference.IMPERIAL to "Imperial (in, °F, mph)",
                UnitPreference.METRIC to "Metric (cm, °C, km/h)",
            )
            labels.forEach { (option, label) ->
                DropdownMenuItem(
                    text = { Text(label) },
                    leadingIcon = { RadioButton(selected = option == units, onClick = null) },
                    onClick = { expanded = false; onUnits(option) },
                )
            }
        }
    }
}

@Composable
private fun Metrics(summary: ConditionsSummary, onProblems: (List<String>) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
        listOf(
            listOf(summary.base, summary.last24h, summary.next24h),
            listOf(summary.tempNow, summary.highLow, summary.wind),
        ).forEach { row ->
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                row.forEach { MetricCell(it, Modifier.weight(1f), onProblems) }
            }
        }
    }
}

@Composable
private fun MetricCell(metric: MetricSummary, modifier: Modifier, onProblems: (List<String>) -> Unit) {
    Column(
        modifier.dimmed(metric.state).explainsProblems(metric.state, onProblems),
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Text(metric.title, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(metric.value ?: "–", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.SemiBold)
        Text(
            metric.caption + if (metric.state.problems.isEmpty()) "" else " ⓘ",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 2,
        )
    }
}

@Composable
private fun Avalanche(avalanche: AvalancheSummary, onProblems: (List<String>) -> Unit) {
    val context = LocalContext.current
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(
            Modifier.fillMaxWidth().dimmed(avalanche.state).explainsProblems(avalanche.state, onProblems),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalAlignment = Alignment.Top,
        ) {
            if (avalanche.level != null) {
                DangerBadge(avalanche.level)
            } else {
                Text("⚠", style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(
                    avalanche.headline + if (avalanche.state.problems.isEmpty()) "" else " ⓘ",
                    style = MaterialTheme.typography.titleMedium,
                    color = if (avalanche.level == null) MaterialTheme.colorScheme.onSurfaceVariant else Color.Unspecified,
                )
                avalanche.bands?.let {
                    Text(it, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                avalanche.state.age?.let {
                    Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }
        avalanche.forecastUrl?.let { url ->
            OutlinedButton(onClick = { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url))) }) {
                Text("Avalanche forecast")
            }
        }
    }
}

/** The danger scale's colors, as on the Mac: gray for no rating, black with a light outline for extreme. */
@Composable
private fun DangerBadge(level: Int) {
    val (background, foreground) = when (level) {
        1 -> Color(0xFF4FB84A) to Color.Black
        2 -> Color(0xFFFFF000) to Color.Black
        3 -> Color(0xFFF7941C) to Color.Black
        4 -> Color(0xFFED1C24) to Color.White
        5 -> Color.Black to Color.White
        else -> Color.Gray to Color.White
    }
    val shape = RoundedCornerShape(6.dp)
    Box(
        Modifier.sizeIn(minWidth = 32.dp, minHeight = 32.dp)
            .background(background, shape)
            .border(1.dp, if (level == 5) Color.White.copy(alpha = 0.6f) else Color.Transparent, shape),
        contentAlignment = Alignment.Center,
    ) {
        Text(if (level == 0) "–" else "$level", color = foreground, fontWeight = FontWeight.Bold, style = MaterialTheme.typography.titleMedium)
    }
}

private fun Modifier.dimmed(state: MetricState) = alpha(if (state.dimmed) DIMMED_ALPHA else 1f)

private fun Modifier.explainsProblems(state: MetricState, onProblems: (List<String>) -> Unit) =
    if (state.problems.isEmpty()) this else clickable { onProblems(state.problems) }
