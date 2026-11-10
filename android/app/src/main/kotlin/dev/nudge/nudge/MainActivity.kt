package dev.nudge.nudge

import android.content.Intent
import android.provider.Settings
import android.net.Uri
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dev.nudge/focus")
            .setMethodCallHandler { call, result ->
                try {
                    val manager = FocusProtection(this)
                    when (call.method) {
                        "status" -> result.success(manager.status())
                        "protect" -> {
                            manager.apply(
                                (call.argument<Number>("until") ?: 0).toLong(),
                                call.argument<String>("generation") ?: "",

                                call.argument<Boolean>("timerPaused") ?: false)
                            result.success(true)
                        }
                        "permission" -> {
                            val intent = when (call.argument<String>("kind")) {
                                "dnd" -> Intent(Settings.ACTION_NOTIFICATION_POLICY_ACCESS_SETTINGS)
                                else -> if (android.os.Build.VERSION.SDK_INT >= 31)
                                    Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM,
                                        Uri.parse("package:$packageName"))
                                else Intent(Settings.ACTION_SETTINGS)
                            }
                            startActivity(intent)
                            result.success(true)
                        }
                        "music" -> {
                            val action = call.argument<String>("action") ?: "stop"
                            StudyMusicService.command(this, action,
                                call.argument<Number>("track")?.toInt(),
                                call.argument<Number>("volume")?.toFloat(),
                                call.argument<Number>("until")?.toLong(),
                                call.argument<String>("run"),
                                call.argument<Number>("position")?.toLong(),
                                call.argument<Boolean>("timerPaused"))
                            result.success(true)
                        }
                        else -> result.notImplemented()
                    }
                } catch (error: Exception) {
                    result.error("DEVICE_CONTROL", error.message ?: "Device control unavailable", null)
                }
            }
    }
}
