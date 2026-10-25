package com.appdin.notchline.core

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray

/** A location from the core's bundled catalog. */
data class CatalogLocation(val id: String, val name: String)

/**
 * The Swift core, through the JNI entry points in android/swift/Sources/NotchlineJNI. Values cross
 * as UTF-8 JSON in byte arrays. Native calls block until the core's async work finishes, so the
 * suspending wrappers run them on the IO dispatcher.
 */
object NotchlineCore {
    init {
        System.loadLibrary("NotchlineJNI")
    }

    @JvmStatic private external fun configure(locationsJson: ByteArray)

    @JvmStatic private external fun refresh(locationId: ByteArray): ByteArray

    @Volatile private var locations: List<CatalogLocation>? = null

    /** Loads the location catalog from the app's assets into the core. Safe to call more than once. */
    fun start(context: Context): List<CatalogLocation> {
        locations?.let { return it }
        val json = context.assets.open("locations.json").use { it.readBytes() }
        configure(json)
        val array = JSONArray(String(json, Charsets.UTF_8))
        return List(array.length()) { index ->
            val location = array.getJSONObject(index)
            CatalogLocation(location.getString("id"), location.getString("name"))
        }.also { locations = it }
    }

    /** A fresh snapshot for [locationId] with its errors and warnings, as pretty-printed JSON. */
    suspend fun refreshJson(locationId: String): String = withContext(Dispatchers.IO) {
        String(refresh(locationId.toByteArray(Charsets.UTF_8)), Charsets.UTF_8)
    }
}
