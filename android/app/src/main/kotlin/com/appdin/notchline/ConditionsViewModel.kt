package com.appdin.notchline

import android.app.Application
import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.os.SystemClock
import android.util.Log
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.appdin.notchline.core.CatalogLocation
import com.appdin.notchline.core.CatalogRegion
import com.appdin.notchline.core.ConditionsSummary
import com.appdin.notchline.core.NotchlineCore
import com.appdin.notchline.core.UnitPreference
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

data class ConditionsUiState(
    val regions: List<CatalogRegion>,
    val location: CatalogLocation,
    val units: UnitPreference,
    val summary: ConditionsSummary? = null,
    /** True while this screen's own refresh of [location] runs, before the core reports it. */
    val refreshing: Boolean = false,
    /** A bridge failure, such as an unknown location. Failed sources show in [summary] instead. */
    val error: String? = null,
)

/**
 * Screen state for the conditions screen. The core owns the snapshots and their cache rules; this
 * holds the selection and units, and decides when to refresh: on launch, on location change, on
 * returning to the app after the refresh interval, and when the network comes back.
 */
class ConditionsViewModel(application: Application) : AndroidViewModel(application) {
    private val prefs = application.getSharedPreferences("notchline", Context.MODE_PRIVATE)
    private val regions = NotchlineCore.start(application)
    private val locations = regions.flatMap { it.locations }

    private val _state = MutableStateFlow(
        ConditionsUiState(
            regions = regions,
            location = resolve(prefs.getString(SELECTED_LOCATION_KEY, null)),
            units = UnitPreference.from(prefs.getString(UNITS_KEY, null)),
        )
    )
    val state: StateFlow<ConditionsUiState> = _state.asStateFlow()

    /** Elapsed-realtime of the last refresh per location this session. */
    private val lastRefresh = mutableMapOf<String, Long>()
    @Volatile private var networkWasDown = false

    private val networkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            if (networkWasDown) viewModelScope.launch { refresh() }
            networkWasDown = false
        }

        override fun onLost(network: Network) {
            networkWasDown = true
        }
    }
    private val connectivity = application.getSystemService(ConnectivityManager::class.java)

    init {
        // Starting offline gets no onLost, so the first onAvailable must count as coming back.
        networkWasDown = connectivity.activeNetwork == null
        connectivity.registerDefaultNetworkCallback(networkCallback)
        // Shows the cached snapshot at once. whileVisible starts the first refresh.
        viewModelScope.launch { reload() }
    }

    override fun onCleared() {
        connectivity.unregisterNetworkCallback(networkCallback)
    }

    fun select(location: CatalogLocation) {
        if (location.id == _state.value.location.id) return
        prefs.edit().putString(SELECTED_LOCATION_KEY, location.id).apply()
        _state.update { it.copy(location = location, summary = null, refreshing = false, error = null) }
        viewModelScope.launch {
            reload()
            refresh()
        }
    }

    fun setUnits(units: UnitPreference) {
        prefs.edit().putString(UNITS_KEY, units.raw).apply()
        _state.update { it.copy(units = units) }
        viewModelScope.launch { reload() }
    }

    /** Fetches the selected location. The core ignores a refresh while one for the location is running. */
    fun refreshNow() {
        viewModelScope.launch { refresh() }
    }

    /**
     * Runs while the screen is visible: refreshes when the last refresh is older than the interval,
     * and rereads the cached conditions each minute so ages and outdated values stay current.
     */
    suspend fun whileVisible() {
        while (true) {
            val last = lastRefresh[_state.value.location.id]
            if (last == null || SystemClock.elapsedRealtime() - last >= REFRESH_INTERVAL_MS) {
                viewModelScope.launch { refresh() }
            } else {
                reload()
            }
            delay(60_000)
        }
    }

    private suspend fun reload() {
        val (location, units) = _state.value.let { it.location to it.units }
        try {
            val summary = NotchlineCore.conditions(location.id, units)
            _state.update { if (it.location.id == location.id) it.copy(summary = summary, error = null) else it }
        } catch (error: IllegalStateException) {
            fail(location, error)
        }
    }

    private suspend fun refresh() {
        val location = _state.value.location
        lastRefresh[location.id] = SystemClock.elapsedRealtime()
        _state.update { it.copy(refreshing = true) }
        try {
            NotchlineCore.refresh(location.id, _state.value.units)
            // Units may have changed during the fetch, so reread rather than show the returned summary.
            _state.update { if (it.location.id == location.id) it.copy(refreshing = false) else it }
            reload()
        } catch (error: IllegalStateException) {
            fail(location, error)
        }
    }

    private fun fail(location: CatalogLocation, error: IllegalStateException) {
        Log.e(TAG, "${location.id}: ${error.message}")
        _state.update { if (it.location.id == location.id) it.copy(refreshing = false, error = error.message) else it }
    }

    private fun resolve(id: String?): CatalogLocation =
        locations.firstOrNull { it.id == id } ?: locations.firstOrNull { it.id == DEFAULT_LOCATION_ID } ?: locations.first()

    private companion object {
        const val TAG = "Notchline"
        const val SELECTED_LOCATION_KEY = "selectedLocationID"
        const val UNITS_KEY = "units"
        const val DEFAULT_LOCATION_ID = "mt-baker"
        /** The Mac's default refresh interval. */
        const val REFRESH_INTERVAL_MS = 30 * 60 * 1000L
    }
}
