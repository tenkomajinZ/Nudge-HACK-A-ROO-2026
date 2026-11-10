package dev.nudge.nudge

import android.app.*
import android.content.*
import android.net.Uri
import android.os.Build
import android.os.SystemClock
import android.provider.Settings
import android.service.notification.Condition
import android.service.notification.ConditionProviderService
import android.service.notification.ZenPolicy

/** Owns only NUDGE's rule. Never changes the user's global DND switch. */
class FocusProtection(private val context: Context) {
    private val prefs = context.getSharedPreferences("nudge_focus", Context.MODE_PRIVATE)
    private val notifications = context.getSystemService(NotificationManager::class.java)
    private val alarms = context.getSystemService(AlarmManager::class.java)
    private val conditionId = Uri.parse("condition://${context.packageName}/study")
    fun alarmAccess() = Build.VERSION.SDK_INT < 31 || alarms.canScheduleExactAlarms()
    private fun bootCount() = Settings.Global.getInt(context.contentResolver, Settings.Global.BOOT_COUNT, 0)
    fun active(): Boolean =
        (prefs.getBoolean("timerPaused", false) ||
            prefs.getLong("untilElapsed", 0) > SystemClock.elapsedRealtime()) &&
            prefs.getInt("boot", -1) == bootCount()
    private fun alarmIntent(generation: String = "", deadline: Long = 0): PendingIntent =
        PendingIntent.getBroadcast(context, 77,
            Intent(context, FocusExpiryReceiver::class.java)
                .setAction("dev.nudge.EXPIRE")
                .putExtra("generation", generation).putExtra("deadline", deadline),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

    fun apply(until: Long, generation: String,
        timerPaused: Boolean = false) {
        if ((!timerPaused && until <= System.currentTimeMillis()) || !alarmAccess()) {
            clear()
            return
        }
        val elapsedDeadline = if (timerPaused) 0L
            else SystemClock.elapsedRealtime() + (until - System.currentTimeMillis())
        // An explicit timer pause holds the protection until resume or finish.
        if (timerPaused) {
            alarms.cancel(alarmIntent())
        } else {
            alarms.setExactAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP,
                elapsedDeadline, alarmIntent(generation, elapsedDeadline))
        }
        prefs.edit().putLong("untilElapsed", elapsedDeadline).putLong("untilWall", until)
            .putInt("boot", bootCount()).putString("generation", generation)
            .putBoolean("timerPaused", timerPaused)
            .remove("message").commit()
        if (notifications.isNotificationPolicyAccessGranted) {
            try {
                var id = prefs.getString("rule", null)
                if (id == null || notifications.getAutomaticZenRule(id) == null) {
                    val rule = if (Build.VERSION.SDK_INT >= 29) {
                        AutomaticZenRule("NUDGE study", null,
                            ComponentName(context, MainActivity::class.java), conditionId,
                            ZenPolicy.Builder().allowMedia(true).allowAlarms(true)
                                .allowCalls(ZenPolicy.PEOPLE_TYPE_STARRED)
                                .allowMessages(ZenPolicy.PEOPLE_TYPE_NONE)
                                .allowReminders(false).allowEvents(false).build(),
                            NotificationManager.INTERRUPTION_FILTER_PRIORITY, true)
                    } else {
                        AutomaticZenRule("NUDGE study",
                            ComponentName(context, FocusConditionService::class.java), conditionId,
                            NotificationManager.INTERRUPTION_FILTER_PRIORITY, true)
                    }
                    id = notifications.addAutomaticZenRule(rule)
                    prefs.edit().putString("rule", id).commit()
                }
                if (Build.VERSION.SDK_INT >= 29 && id != null) {
                    notifications.setAutomaticZenRuleState(id, condition(true))
                } else {
                    FocusConditionService.current?.publish(true)
                    ConditionProviderService.requestRebind(ComponentName(context, FocusConditionService::class.java))
                }
                prefs.edit().putBoolean("dndRequested", true).apply()
            } catch (_: Exception) {
                prefs.edit().putBoolean("dndRequested", false)
                    .putString("message", "Android could not enable NUDGE's DND rule. You can keep studying.").apply()
            }
        } else {
            prefs.edit().putBoolean("dndRequested", false).apply()
        }
    }

    fun condition(on: Boolean) = Condition(conditionId, "NUDGE study",
        if (on) Condition.STATE_TRUE else Condition.STATE_FALSE)
    fun clear() {
        alarms.cancel(alarmIntent())
        // Remove the app-owned rule entirely, including a user-disabled stale rule.
        val id = prefs.getString("rule", null)
        if (id != null && notifications.isNotificationPolicyAccessGranted) {
            try {
                notifications.removeAutomaticZenRule(id)
                prefs.edit().remove("rule").apply()
            } catch (_: Exception) {
                FocusConditionService.current?.publish(false)
            }
        }
        prefs.edit().putLong("untilElapsed", 0).putLong("untilWall", 0)
            .remove("timerPaused")
            .putBoolean("dndRequested", false).remove("message").commit()
    }

    fun expire(intent: Intent) {
        when (intent.action) {
            "dev.nudge.EXPIRE" -> {
                val deadline = prefs.getLong("untilElapsed", 0)
                if (deadline <= 0 || deadline > SystemClock.elapsedRealtime() ||
                    prefs.getBoolean("timerPaused", false) ||
                    intent.getStringExtra("generation") != prefs.getString("generation", "") ||
                    intent.getLongExtra("deadline", -1) != deadline) return
            }
            Intent.ACTION_BOOT_COMPLETED -> Unit
            else -> {
                // Clock and alarm access changes can invalidate a deadline, not a manual hold.
                if (!active() || !prefs.getBoolean("timerPaused", false)) clear()
                if (!prefs.getBoolean("musicTimerPaused", false)) {
                    StudyMusicService.command(context, "stop")
                }
                return
            }
        }
        clear()
        StudyMusicService.command(context, "stop")
    }

    fun status(): Map<String, Any?> {
        if (!active() &&
            (prefs.getBoolean("timerPaused", false) || prefs.getLong("untilElapsed", 0) != 0L)) {
            clear()
        }
        val id = prefs.getString("rule", null)
        val ruleEnabled = if (id != null && notifications.isNotificationPolicyAccessGranted) {
            try { notifications.getAutomaticZenRule(id)?.isEnabled == true } catch (_: Exception) { false }
        } else false
        return mapOf("dndAccess" to notifications.isNotificationPolicyAccessGranted,
            "alarmAccess" to alarmAccess(),
            "dndActive" to (active() && ruleEnabled && prefs.getBoolean("dndRequested", false) &&
                notifications.currentInterruptionFilter != NotificationManager.INTERRUPTION_FILTER_ALL),
            "message" to prefs.getString("message", null),
            "playing" to (StudyMusicService.current?.player?.isPlaying == true),
            "volume" to (StudyMusicService.current?.player?.volume ?: prefs.getFloat("musicVolume", 0.5f)),
            "track" to (StudyMusicService.current?.player?.currentMediaItemIndex ?: 0),
            "position" to (StudyMusicService.current?.player?.currentPosition ?: 0L),
            "duration" to maxOf(0L, StudyMusicService.current?.player?.duration ?: 0L),
            "seekable" to (StudyMusicService.current?.player?.isCurrentMediaItemSeekable == true),
            "previewing" to (StudyMusicService.current != null && prefs.getString("musicRun", null) == "__preview__"),
            "audioError" to StudyMusicService.lastError)
    }

}
class FocusExpiryReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) { FocusProtection(context).expire(intent) }
}
class FocusConditionService : ConditionProviderService() {
    companion object { var current: FocusConditionService? = null }
    override fun onConnected() { current = this; publish(FocusProtection(this).active()) }
    override fun onSubscribe(conditionId: Uri?) { publish(FocusProtection(this).active()) }
    override fun onUnsubscribe(conditionId: Uri?) {}
    fun publish(on: Boolean) { notifyCondition(FocusProtection(this).condition(on)) }
    override fun onDestroy() { current = null; super.onDestroy() }
}
