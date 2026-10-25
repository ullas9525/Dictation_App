package com.example.dictation_app

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
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

    override fun getDartEntrypointFunctionName(): String = "overlayMain"

    override fun getBackgroundMode(): FlutterActivityLaunchConfigs.BackgroundMode =
        FlutterActivityLaunchConfigs.BackgroundMode.transparent

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
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
        super.onDestroy()
        // The bubble was hidden when this sheet took focus. Ask the
        // accessibility service to bring it back once the app underneath is
        // interactive again (unless the focus is gone by then).
        DictationAccessibilityService.requestEvaluate()
    }

    private fun copyToClipboard(text: String) {
        val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        clipboard.setPrimaryClip(ClipData.newPlainText("Dictation", text))
    }
}
