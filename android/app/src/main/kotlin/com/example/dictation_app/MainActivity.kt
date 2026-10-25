package com.example.dictation_app

import android.Manifest
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
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
 * The bubble itself lives in [OverlayService]; the focused-field detection and
 * paste live in [DictationAccessibilityService].
 */
class MainActivity : FlutterActivity() {

    companion object {
        const val OVERLAY_CHANNEL = "dictation_app/overlay"
        private const val NOTIFICATION_PERMISSION_REQUEST = 1001
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
                    "requestNotificationPermission" -> {
                        requestNotificationPermission()
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun overlayStatus(): Map<String, Boolean> = mapOf(
        "canDrawOverlays" to canDrawOverlays(),
        "accessibilityEnabled" to isAccessibilityServiceEnabled(),
        "serviceRunning" to OverlayService.isRunning,
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

    private fun openAccessibilitySettings(): Boolean = try {
        startActivity(
            Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        )
        true
    } catch (_: Exception) {
        false
    }

    private fun startOverlayService(): Boolean {
        if (!canDrawOverlays()) return false
        val intent = Intent(this, OverlayService::class.java)
            .setAction(OverlayService.ACTION_START)
        return try {
            startService(intent)
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun stopOverlayService(): Boolean {
        stopService(Intent(this, OverlayService::class.java))
        OverlayService.hideBubble()
        return true
    }

    private fun requestNotificationPermission() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        requestPermissions(
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            NOTIFICATION_PERMISSION_REQUEST,
        )
    }
}
