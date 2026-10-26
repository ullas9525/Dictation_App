package com.example.dictation_app

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.util.Log
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.android.FlutterActivityLaunchConfigs
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Translucent Flutter host for the dictation sheet.
 *
 * It runs the separate `overlayMain` Dart entrypoint, which owns recording,
 * STT/LLM processing and the three-format preview. This activity only bridges
 * the final action: put the chosen text on the clipboard and ask
 * [DictationAccessibilityService] to paste it into the app underneath.
 *
 * It must not finish inside `insertText`: the accessibility service waits for
 * this window to disappear so the target app regains input focus before the
 * delayed ACTION_PASTE runs. Dart explicitly calls `close` afterwards.
 */
class OverlayDictationActivity : FlutterActivity() {

    companion object {
        private const val CHANNEL = "dictation_app/overlay_activity"
    }

    private var channel: MethodChannel? = null

    /** Owner token of this instance's dictation claim (see OverlayService). */
    private var dictationGeneration: Long = -1L

    override fun getDartEntrypointFunctionName(): String = "overlayMain"

    override fun getBackgroundMode(): FlutterActivityLaunchConfigs.BackgroundMode =
        FlutterActivityLaunchConfigs.BackgroundMode.transparent

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)

        // Claim the overlay slot for as long as this sheet exists. The service
        // already claims it before launching; claiming again here makes the
        // state survive an activity re-create and gives this instance the token
        // that only it may release.
        dictationGeneration = OverlayService.beginDictation()

        // ── Keep the keyboard exactly as the user left it ────────────────────
        // A normal activity window takes window focus, becomes the input-method
        // target, and (having no text editor of its own) makes the IME hide;
        // the keyboard then reopens when the target app regains focus. This
        // window is only a floating recorder, so it has no reason to own the
        // IME: making it non-focusable leaves focus (and the IME connection)
        // with the app underneath.
        //
        // Touch is unaffected by FLAG_NOT_FOCUSABLE — pointer events are still
        // delivered to this window, so the pill stays fully interactive. This
        // is the same mechanism the native bubble already relies on. Key and
        // back events go to the app underneath; the pill has its own ✕/Close.
        //
        // Deliberately NOT set: FLAG_ALT_FOCUSABLE_IM. With FLAG_NOT_FOCUSABLE
        // already present it would re-request the IME target (the opposite of
        // what is wanted) and can push this window below the keyboard.
        window.addFlags(WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE)

        // The overlay never needs keyboard insets, so a keyboard that stays
        // visible must not resize this window or re-center the pill.
        window.setSoftInputMode(
            WindowManager.LayoutParams.SOFT_INPUT_STATE_UNCHANGED or
                WindowManager.LayoutParams.SOFT_INPUT_ADJUST_NOTHING,
        )

        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        Log.d(
            "OverlayDebug",
            "dictation activity created: visualizer active; " +
                "flags=0x${Integer.toHexString(window.attributes.flags)} " +
                "softInputMode=0x${Integer.toHexString(window.attributes.softInputMode)}",
        )
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .also { methodChannel ->
                methodChannel.setMethodCallHandler { call, result ->
                    when (call.method) {
                        "insertText" -> {
                            val text = call.argument<String>("text") ?: ""
                            if (text.isEmpty()) {
                                result.success(false)
                            } else {
                                copyToClipboard(text)
                                result.success(DictationAccessibilityService.queueInsert(text))
                            }
                        }

                        "copyText" -> {
                            val text = call.argument<String>("text") ?: ""
                            if (text.isEmpty()) {
                                result.success(false)
                            } else {
                                copyToClipboard(text)
                                result.success(true)
                            }
                        }

                        "close" -> {
                            result.success(true)
                            // Let the reply reach Dart before the window goes away.
                            window.decorView.post { finish() }
                        }

                        "accessibilityConnected" ->
                            result.success(DictationAccessibilityService.isConnected())

                        else -> result.notImplemented()
                    }
                }
            }
    }

    override fun onDestroy() {
        channel?.setMethodCallHandler(null)
        channel = null
        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        // Release the claim before asking for a restore: the visualizer is
        // gone, so the bubble is allowed to come back. Without this the
        // accessibility service would keep suppressing it forever. The token
        // makes a replaced instance a no-op instead of clearing a live claim.
        OverlayService.endDictation(dictationGeneration)
        Log.d(
            "OverlayDebug",
            "dictation activity destroyed: visualizer closed " +
                "(gen=$dictationGeneration, active=${OverlayService.isDictationActive()})",
        )
        super.onDestroy()
        // The bubble was hidden when this sheet opened. Ask the accessibility
        // service to bring it back exactly once, after the app underneath is
        // interactive again (unless the focus is gone by then).
        DictationAccessibilityService.requestEvaluate()
    }

    private fun copyToClipboard(text: String) {
        val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        clipboard.setPrimaryClip(ClipData.newPlainText("Dictation", text))
    }
}
