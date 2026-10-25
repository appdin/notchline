package com.appdin.notchline

import android.content.Context
import android.util.Log
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.appdin.notchline.core.NotchlineCore
import java.util.concurrent.TimeUnit

/**
 * Refreshes and replans the selected location in the background, then replaces the planner's
 * notifications, so summaries follow the forecast while the app is closed. Runs every 30 minutes,
 * the Mac's default interval, when there is a network. Android may run it later than that,
 * especially with battery optimization on.
 */
class RefreshWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        val prefs = AppPreferences(applicationContext)
        val locations = NotchlineCore.start(applicationContext).flatMap { it.locations }
        val location = locations.firstOrNull { it.id == prefs.selectedLocationId } ?: return Result.success()
        val settings = prefs.settings
        return try {
            NotchlineCore.refresh(location.id, settings)
            val response = NotchlineCore.plan(location.id, settings)
            response.notifications?.let { PlannerAlarms.replace(applicationContext, it, location) }
            Result.success()
        } catch (error: IllegalStateException) {
            Log.e(TAG, "Background refresh of ${location.id} failed: ${error.message}")
            Result.retry()
        }
    }

    companion object {
        private const val TAG = "Notchline"
        private const val WORK_NAME = "refresh"

        /** Starts the periodic refresh, keeping the schedule if it is already set. */
        fun enqueue(context: Context) {
            val request = PeriodicWorkRequestBuilder<RefreshWorker>(30, TimeUnit.MINUTES)
                .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
                .build()
            WorkManager.getInstance(context).enqueueUniquePeriodicWork(WORK_NAME, ExistingPeriodicWorkPolicy.KEEP, request)
        }
    }
}
