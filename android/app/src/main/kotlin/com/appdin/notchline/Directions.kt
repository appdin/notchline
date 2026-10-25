package com.appdin.notchline

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri

/**
 * Google Maps driving directions from the phone's location to a coordinate. Maps URLs can't set
 * an arrival time, so Maps gives the live ETA. Opens in the browser when Google Maps isn't
 * installed. The manifest's `<queries>` lets the app see whether it is.
 */
object Directions {
    private const val GOOGLE_MAPS_PACKAGE = "com.google.android.apps.maps"

    fun intent(context: Context, latitude: Double, longitude: Double): Intent {
        val uri = Uri.parse("https://www.google.com/maps/dir/").buildUpon()
            .appendQueryParameter("api", "1")
            .appendQueryParameter("destination", "$latitude,$longitude")
            .appendQueryParameter("travelmode", "driving")
            .build()
        val intent = Intent(Intent.ACTION_VIEW, uri)
        return if (hasGoogleMaps(context)) intent.setPackage(GOOGLE_MAPS_PACKAGE) else intent
    }

    private fun hasGoogleMaps(context: Context): Boolean = try {
        context.packageManager.getPackageInfo(GOOGLE_MAPS_PACKAGE, 0)
        true
    } catch (_: PackageManager.NameNotFoundException) {
        false
    }
}
