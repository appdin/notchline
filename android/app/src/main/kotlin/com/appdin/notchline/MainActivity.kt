package com.appdin.notchline

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.appdin.notchline.core.CatalogLocation
import com.appdin.notchline.core.NotchlineCore
import kotlinx.coroutines.launch

/** Phase 1's end-to-end check: pick a location and show the core's snapshot JSON for it. */
class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val locations = NotchlineCore.start(this)
        setContent {
            MaterialTheme(colorScheme = if (isSystemInDarkTheme()) darkColorScheme() else lightColorScheme()) {
                Surface(Modifier.fillMaxSize()) {
                    SnapshotScreen(locations)
                }
            }
        }
    }
}

@Composable
private fun SnapshotScreen(locations: List<CatalogLocation>) {
    var selected by remember { mutableStateOf(locations.first()) }
    var output by remember { mutableStateOf("") }
    var loading by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()

    fun load() {
        loading = true
        scope.launch {
            output = try {
                NotchlineCore.refreshJson(selected.id)
            } catch (error: IllegalStateException) {
                "Error: ${error.message}"
            }
            loading = false
        }
    }

    LaunchedEffect(Unit) { load() }

    Column(Modifier.safeDrawingPadding().padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            locations.forEach { location ->
                FilterChip(
                    selected = location == selected,
                    onClick = { selected = location; load() },
                    label = { Text(location.name) },
                )
            }
        }
        Button(onClick = { load() }, enabled = !loading) {
            Text(if (loading) "Loading..." else "Refresh")
        }
        Text(
            output,
            fontFamily = FontFamily.Monospace,
            fontSize = 11.sp,
            modifier = Modifier.verticalScroll(rememberScrollState()).horizontalScroll(rememberScrollState()),
        )
    }
}
