package com.appdin.notchline

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.launch

/** The conditions screen for the selected location. */
class MainActivity : ComponentActivity() {
    private val model: ConditionsViewModel by viewModels()
    private val askForNotifications = registerForActivityResult(ActivityResultContracts.RequestPermission()) {}

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) { model.whileVisible() }
        }
        val actions = ScreenActions(
            select = model::select,
            refresh = model::refreshNow,
            setUnits = model::setUnits,
            setNotifyThreshold = model::setNotifyThreshold,
            setSummaryTime = model::setSummaryTime,
            openRatings = model::openRatings,
            closeRatings = model::closeRatings,
            rate = model::rate,
        )
        setContent {
            val dark = isSystemInDarkTheme()
            val context = LocalContext.current
            val colors = when {
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.S -> if (dark) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
                dark -> darkColorScheme()
                else -> lightColorScheme()
            }
            MaterialTheme(colorScheme = colors) {
                val state by model.state.collectAsStateWithLifecycle()
                // Asks once, when the first plan gives the planner something to notify about.
                LaunchedEffect(state.planner != null && state.settings.notifyThreshold != null) {
                    if (state.planner != null && state.settings.notifyThreshold != null) askForNotificationsOnce()
                }
                ConditionsScreen(state, actions)
            }
        }
    }

    private fun askForNotificationsOnce() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) return
        val prefs = AppPreferences(this)
        if (prefs.askedForNotifications) return
        prefs.askedForNotifications = true
        askForNotifications.launch(Manifest.permission.POST_NOTIFICATIONS)
    }
}
