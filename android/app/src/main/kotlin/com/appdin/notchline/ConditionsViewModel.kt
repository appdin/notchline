package com.appdin.notchline

import android.app.Application
import android.net.ConnectivityManager
import android.net.Network
import android.os.SystemClock
import android.util.Log
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.appdin.notchline.core.AppSettings
import com.appdin.notchline.core.CatalogLocation
import com.appdin.notchline.core.CatalogRegion
import com.appdin.notchline.core.ConditionsSummary
import com.appdin.notchline.core.LocationResponse
import com.appdin.notchline.core.NotchlineCore
import com.appdin.notchline.core.PlannerSummary
import com.appdin.notchline.core.RatableDay
import com.appdin.notchline.core.Rating
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
    val settings: AppSettings,
    val summary: ConditionsSummary? = null,
    val planner: PlannerSummary? = null,
    /** [location] was planned this session, so a null [planner] means there was nothing to plan from. */
    val planned: Boolean = false,
    /** Stands in for a null [planner] once planned. */
    val plannerMessage: String? = null,
    val scoreHelp: List<String> = emptyList(),
    /** The recent days to rate while the rating dialog is open, newest first. */
    val ratingDays: List<RatableDay>? = null,
    /** True while this screen's own refresh of [location] runs, before the core reports it. */
    val refreshing: Boolean = false,
    val planning: Boolean = false,
    /** A bridge failure, such as an unknown location. Failed sources show in [summary] instead. */
    val error: String? = null,
)

/**
 * Screen state for the conditions screen. The core owns the snapshots, plans, ratings and their
 * rules; this holds the selection and settings, and decides when to refresh: on launch, on
 * location change, on returning to the app after the refresh interval, and when the network comes
 * back. Each refresh replans, as on the Mac, and a location shown from the cache is planned from
 * it. Each plan replaces the planner's notifications. `RefreshWorker` does the same in the
 * background.
 */
class ConditionsViewModel(application: Application) : AndroidViewModel(application) {
    private val prefs = AppPreferences(application)
    private val regions = NotchlineCore.start(application)
    private val locations = regions.flatMap { it.locations }

    private val _state = MutableStateFlow(
        ConditionsUiState(
            regions = regions,
            location = resolve(prefs.selectedLocationId),
            settings = prefs.settings,
        )
    )
    val state: StateFlow<ConditionsUiState> = _state.asStateFlow()

    /** Elapsed-realtime of the last refresh per location this session. */
    private val lastRefresh = mutableMapOf<String, Long>()
    /** Locations being planned now, and those to plan again when that finishes. Main thread only. */
    private val planning = mutableSetOf<String>()
    private val replan = mutableSetOf<String>()
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
        // The background refresh goes by the stored selection, so store the default on first launch.
        prefs.selectedLocationId = _state.value.location.id
        RefreshWorker.enqueue(application)
        // Shows the cached snapshot at once. whileVisible starts the first refresh.
        viewModelScope.launch { reload() }
    }

    override fun onCleared() {
        connectivity.unregisterNetworkCallback(networkCallback)
    }

    fun select(location: CatalogLocation) {
        if (location.id == _state.value.location.id) return
        prefs.selectedLocationId = location.id
        _state.update {
            it.copy(
                location = location, summary = null, planner = null, planned = false, plannerMessage = null,
                ratingDays = null, refreshing = false, planning = false, error = null)
        }
        viewModelScope.launch {
            reload()
            refresh()
        }
    }

    fun setUnits(units: UnitPreference) {
        update(_state.value.settings.copy(units = units))
        viewModelScope.launch { reload() }
    }

    /** null turns the planner's notifications off. */
    fun setNotifyThreshold(threshold: Int?) {
        update(_state.value.settings.copy(notifyThreshold = threshold))
        viewModelScope.launch { plan(_state.value.location) }
    }

    /** `HH:mm` in the phone's time zone. */
    fun setSummaryTime(time: String) {
        update(_state.value.settings.copy(summaryTime = time))
        viewModelScope.launch { plan(_state.value.location) }
    }

    /** Opens the rating dialog with the selected location's recent days. Nothing asks for ratings; the user rates when they choose. */
    fun openRatings() {
        val location = _state.value.location
        viewModelScope.launch {
            try {
                val days = NotchlineCore.ratableDays(location.id, _state.value.settings)
                _state.update { if (it.location.id == location.id) it.copy(ratingDays = days) else it }
            } catch (error: IllegalStateException) {
                fail(location, error)
            }
        }
    }

    fun closeRatings() {
        _state.update { it.copy(ratingDays = null) }
    }

    /** Stores the rating and closes the dialog. */
    fun rate(rating: Rating) {
        val location = _state.value.location
        closeRatings()
        viewModelScope.launch {
            try {
                show(location, NotchlineCore.rate(location.id, _state.value.settings, rating))
            } catch (error: IllegalStateException) {
                fail(location, error)
            }
        }
    }

    private fun update(settings: AppSettings) {
        prefs.settings = settings
        _state.update { it.copy(settings = settings) }
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
        val location = _state.value.location
        try {
            val response = NotchlineCore.conditions(location.id, _state.value.settings)
            show(location, response)
            if (!response.planned) viewModelScope.launch { plan(location) }
        } catch (error: IllegalStateException) {
            fail(location, error)
        }
    }

    private suspend fun refresh() {
        val location = _state.value.location
        lastRefresh[location.id] = SystemClock.elapsedRealtime()
        _state.update { it.copy(refreshing = true) }
        try {
            NotchlineCore.refresh(location.id, _state.value.settings)
            // Units may have changed during the fetch, so reread rather than show the returned summary.
            _state.update { if (it.location.id == location.id) it.copy(refreshing = false) else it }
            reload()
            plan(location)
        } catch (error: IllegalStateException) {
            fail(location, error)
        }
    }

    private suspend fun plan(location: CatalogLocation) {
        if (!planning.add(location.id)) {
            // A refresh landed during the plan, so the plan is from the snapshot before it.
            replan.add(location.id)
            return
        }
        _state.update { if (it.location.id == location.id) it.copy(planning = true) else it }
        try {
            val response = NotchlineCore.plan(location.id, _state.value.settings)
            // Only the selected location gets notifications, as on the Mac.
            if (location.id == prefs.selectedLocationId) {
                response.notifications?.let { PlannerAlarms.replace(getApplication(), it, location) }
            }
            _state.update { if (it.location.id == location.id) it.copy(planning = false) else it }
            reload()
        } catch (error: IllegalStateException) {
            fail(location, error)
        } finally {
            planning.remove(location.id)
            if (replan.remove(location.id)) viewModelScope.launch { plan(location) }
        }
    }

    private fun show(location: CatalogLocation, response: LocationResponse) {
        _state.update {
            if (it.location.id != location.id) return@update it
            it.copy(
                summary = response.conditions, planner = response.planner, planned = response.planned,
                plannerMessage = response.plannerMessage, scoreHelp = response.scoreHelp, error = null)
        }
    }

    private fun fail(location: CatalogLocation, error: IllegalStateException) {
        Log.e(TAG, "${location.id}: ${error.message}")
        _state.update { if (it.location.id == location.id) it.copy(refreshing = false, planning = false, error = error.message) else it }
    }

    private fun resolve(id: String?): CatalogLocation =
        locations.firstOrNull { it.id == id } ?: locations.firstOrNull { it.id == DEFAULT_LOCATION_ID } ?: locations.first()

    private companion object {
        const val TAG = "Notchline"
        const val DEFAULT_LOCATION_ID = "mt-baker"
        /** The Mac's default refresh interval. */
        const val REFRESH_INTERVAL_MS = 30 * 60 * 1000L
    }
}
