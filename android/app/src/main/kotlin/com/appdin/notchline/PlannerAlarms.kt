package com.appdin.notchline

import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import com.appdin.notchline.core.CatalogLocation
import com.appdin.notchline.core.ScheduledNotification
import com.appdin.notchline.core.objects
import org.json.JSONArray
import org.json.JSONObject

/**
 * Delivers the planner's notifications. Android has no scheduled notifications, so each one is an
 * alarm that posts it when it fires. Each plan replaces every pending one, so a day that drops
 * below the threshold loses its summary. The pending ones are kept in preferences so a reboot,
 * which clears alarms, can set them again.
 */
object PlannerAlarms {
    private const val TAG = "Notchline"
    private const val CHANNEL_ID = "planner"
    private const val STORED_KEY = "plannerAlarms"
    private const val EXTRA_NOTIFICATION = "notification"

    /** Replaces every pending planner notification with [notifications], all for [location]. */
    fun replace(context: Context, notifications: List<ScheduledNotification>, location: CatalogLocation) {
        val alarms = context.getSystemService(AlarmManager::class.java)
        stored(context).forEach { alarms.cancel(alarmIntent(context, it)) }
        val pending = notifications
            .filter { it.fireAtMillis > System.currentTimeMillis() }
            .map { Pending(it, location.latitude, location.longitude) }
        prefs(context).edit().putString(STORED_KEY, JSONArray(pending.map { it.toJson() }).toString()).apply()
        pending.forEach { schedule(context, it) }
        Log.i(TAG, "Scheduled ${pending.size} planner notifications")
    }

    /** Sets the stored alarms again, after a reboot or an app update cleared them. */
    fun restore(context: Context) {
        stored(context).filter { it.notification.fireAtMillis > System.currentTimeMillis() }.forEach { schedule(context, it) }
    }

    /**
     * True when alarms fire at their time. Without the exact alarm permission, Android may hold
     * an alarm back while the phone idles, and the evening summary can arrive late.
     */
    fun firesOnTime(context: Context): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.S || context.getSystemService(AlarmManager::class.java).canScheduleExactAlarms()

    private fun schedule(context: Context, pending: Pending) {
        val alarms = context.getSystemService(AlarmManager::class.java)
        val intent = alarmIntent(context, pending)
        if (firesOnTime(context)) {
            alarms.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, pending.notification.fireAtMillis, intent)
        } else {
            alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, pending.notification.fireAtMillis, intent)
        }
    }

    /** One alarm per notification ID, told apart by the intent's data so each can be cancelled. */
    private fun alarmIntent(context: Context, pending: Pending): PendingIntent {
        val intent = Intent(context, PlannerAlarmReceiver::class.java)
            .setData(Uri.parse("notchline://planner/${pending.notification.id}"))
            .putExtra(EXTRA_NOTIFICATION, pending.toJson().toString())
        return PendingIntent.getBroadcast(context, 0, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    /** Posts the evening summary. Tapping it opens Google Maps directions to the location. */
    internal fun post(context: Context, json: String) {
        val pending = Pending.from(JSONObject(json))
        val notification = pending.notification
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "Evening summaries", NotificationManager.IMPORTANCE_DEFAULT).apply {
                description = "Evening-before summaries of good ski days"
            })
        val tap = Directions.intent(context, pending.latitude, pending.longitude).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        val built = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(notification.title)
            .setContentText(notification.body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(notification.body))
            .setContentIntent(PendingIntent.getActivity(context, notification.id.hashCode(), tap, PendingIntent.FLAG_IMMUTABLE))
            .setAutoCancel(true)
            .build()
        if (manager.areNotificationsEnabled()) manager.notify(notification.id, 0, built)
    }

    private fun stored(context: Context): List<Pending> =
        prefs(context).getString(STORED_KEY, null)?.let { json -> JSONArray(json).objects().map(Pending::from) }.orEmpty()

    private fun prefs(context: Context) = context.getSharedPreferences("notchline", Context.MODE_PRIVATE)

    /** A notification with the coordinate its directions go to. */
    private class Pending(val notification: ScheduledNotification, val latitude: Double, val longitude: Double) {
        fun toJson(): JSONObject = notification.toJson().put("latitude", latitude).put("longitude", longitude)

        companion object {
            fun from(json: JSONObject) = Pending(ScheduledNotification.from(json), json.getDouble("latitude"), json.getDouble("longitude"))
        }
    }

    internal fun notificationJson(intent: Intent): String? = intent.getStringExtra(EXTRA_NOTIFICATION)
}

/** Posts a planner notification when its alarm fires. */
class PlannerAlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        PlannerAlarms.notificationJson(intent)?.let { PlannerAlarms.post(context, it) }
    }
}

/** Sets the planner's alarms again after a reboot or app update, and restarts the background refresh. */
class RestoreReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED && intent.action != Intent.ACTION_MY_PACKAGE_REPLACED) return
        PlannerAlarms.restore(context)
        RefreshWorker.enqueue(context)
    }
}
