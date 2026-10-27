package com.example.dictation_app

import android.content.ComponentName
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Hosts the normal Flutter app and the small settings bridge used by the
 * floating dictation bubble.
 *
 * The bubble window lives in [BubbleOverlay] and is hosted by
 * [DictationAccessibilityService]; the focused-field detection and the paste
 * live in that same service. There is no foreground service (and therefore no
 * persistent notification).
 */
class MainActivity : FlutterActivity() {

    companion object {
        const val OVERLAY_CHANNEL = "dictation_app/overlay"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, OVERLAY_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getStatus" -> result.success(overlayStatus())
                    "requestOverlayPermission" -> result.success(openOverlayPermission())
                    "openAccessibilitySettings" -> result.success(openAccessibilitySettings())
                    "startOverlay" -> result.success(startOverlayService())
                    "stopOverlay" -> result.success(stopOverlayService())
                    else -> result.notImplemented()
                }
            }
    }

    private fun overlayStatus(): Map<String, Boolean> = mapOf(
        "canDrawOverlays" to canDrawOverlays(),
        "accessibilityEnabled" to isAccessibilityServiceEnabled(),
        // No foreground service exists any more: "running" means the bubble is
        // hosted by the accessibility binding and can be shown.
        "serviceRunning" to BubbleOverlay.isAttached(),
    )

    private fun canDrawOverlays(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.M || Settings.canDrawOverlays(this)

    private fun isAccessibilityServiceEnabled(): Boolean {
        val masterEnabled = Settings.Secure.getInt(
            contentResolver,
            Settings.Secure.ACCESSIBILITY_ENABLED,
            0,
        ) == 1
        if (!masterEnabled) return false

        val enabledServices = Settings.Secure.getString(
            contentResolver,
            Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES,
        ) ?: return false

        val expected = ComponentName(this, DictationAccessibilityService::class.java)
        return enabledServices
            .split(':')
            .mapNotNull { ComponentName.unflattenFromString(it) }
            .any { it == expected }
    }

    private fun openOverlayPermission(): Boolean {
        if (canDrawOverlays()) return true
        val packageUri = Uri.parse("package:$packageName")
        return try {
            startActivity(
                Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, packageUri)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
            true
        } catch (_: Exception) {
            try {
                startActivity(
                    Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                )
                true
            } catch (_: Exception) {
                false
            }
        }
    }

    /**
     * Opens the system Accessibility settings, where the user can turn the
     * Dictation service off (Settings → Accessibility → Dictation bubble).
     *
     * There is deliberately no way to toggle it from here: Android only lets
     * the user change this permission, and hiding or auto-disabling it would
     * be exactly the behaviour banking apps are trying to detect.
     */
    private fun openAccessibilitySettings(): Boolean {
        val intents = listOf(
            Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS),
            Intent(
                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.parse("package:$packageName"),
            ),
        )
        for (intent in intents) {
            try {
                startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                return true
            } catch (_: Exception) {
                // Try the next supported screen.
            }
        }
        return false
    }

    /**
     * There is no foreground service to start any more. The bubble is hosted by
     * the accessibility binding, so this only asks it to re-evaluate focus —
     * that shows the bubble immediately when a supported field is focused.
     */
    private fun startOverlayService(): Boolean {
        if (!canDrawOverlays()) return false
        if (!isAccessibilityServiceEnabled()) return false
        DictationAccessibilityService.requestEvaluate()
        return true
    }

    /** Removes the bubble window (the accessibility binding stays connected). */
    private fun stopOverlayService(): Boolean {
        BubbleOverlay.hide()
        return true
    }
}
