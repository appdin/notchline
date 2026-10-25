package com.appdin.notchline

import android.content.Context
import com.appdin.notchline.core.AppSettings
import com.appdin.notchline.core.UnitPreference

/** What the user picked, shared by the screen and the background refresh. */
class AppPreferences(context: Context) {
    private val prefs = context.getSharedPreferences("notchline", Context.MODE_PRIVATE)

    var selectedLocationId: String?
        get() = prefs.getString(SELECTED_LOCATION_KEY, null)
        set(value) = prefs.edit().putString(SELECTED_LOCATION_KEY, value).apply()

    var settings: AppSettings
        get() = AppSettings(
            units = UnitPreference.from(prefs.getString(UNITS_KEY, null)),
            // Stored as 0 when off, so a missing key keeps the default.
            notifyThreshold = prefs.getInt(THRESHOLD_KEY, AppSettings.DEFAULT_THRESHOLD).takeIf { it > 0 },
            summaryTime = prefs.getString(SUMMARY_TIME_KEY, null) ?: AppSettings.DEFAULT_SUMMARY_TIME,
        )
        set(value) = prefs.edit()
            .putString(UNITS_KEY, value.units.raw)
            .putInt(THRESHOLD_KEY, value.notifyThreshold ?: 0)
            .putString(SUMMARY_TIME_KEY, value.summaryTime)
            .apply()

    /** True once the app has asked for the notification permission, so it asks only once. */
    var askedForNotifications: Boolean
        get() = prefs.getBoolean(ASKED_NOTIFICATIONS_KEY, false)
        set(value) = prefs.edit().putBoolean(ASKED_NOTIFICATIONS_KEY, value).apply()

    private companion object {
        const val SELECTED_LOCATION_KEY = "selectedLocationID"
        const val UNITS_KEY = "units"
        const val THRESHOLD_KEY = "notificationScoreThreshold"
        const val SUMMARY_TIME_KEY = "eveningSummaryTime"
        const val ASKED_NOTIFICATIONS_KEY = "askedForNotifications"
    }
}
