package com.example.dictation_app

import android.app.Service
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.IBinder
import android.provider.Settings
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.ImageView
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * Owns the draggable microphone bubble that floats above other apps.
 *
 * The bubble is intentionally tiny and boring: it is not focusable, it only
 * exists while [DictationAccessibilityService] reports a focused, allow-listed
 * text field, and it never records by itself. Tapping it opens
 * [OverlayDictationActivity], which runs the normal Flutter STT/LLM pipeline.
 *
 * Keeping this as a foreground service means the bubble can be shown without
 * waiting for an activity, and Android is less likely to reclaim it while the
 * user is composing a message.
 */
class OverlayService : Service() {

        companion object {
        const val ACTION_START = "com.example.dictation_app.action.START_OVERLAY"
        const val ACTION_STOP = "com.example.dictation_app.action.STOP_OVERLAY"

        private const val START_DEBOUNCE_MS = 2_000L

        /** Compact mic bubble: small enough not to cover the message bar. */
        private const val BUBBLE_SIZE_DP = 44f
        private const val BUBBLE_ICON_DP = 22f
        private const val BUBBLE_MARGIN_DP = 10f

        @Volatile
        var isRunning: Boolean = false
            private set

        @Volatile
        private var instance: OverlayService? = null

        @Volatile
        private var pendingAnchorBottom: Int? = null

        @Volatile
        private var lastStartAttemptMs: Long = 0L

        /**
         * Shows/repositions the bubble. [anchorBottom] is a screen Y coordinate
         * the bubble should sit above (the IME top, or the focused field top
         * when the keyboard is not exposed as a window).
         */
        fun showBubble(anchorBottom: Int) {
            pendingAnchorBottom = anchorBottom
            instance?.show(anchorBottom)
        }

        fun hideBubble() {
            instance?.hide()
        }

        /**
         * Starts the foreground service if it is not running. Called by the
         * accessibility service when a target field gets focus, so the bubble
         * still comes back if an OEM battery saver stopped the service.
         */
        fun ensureRunning(context: Context): Boolean {
            if (instance != null) return true
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
                !Settings.canDrawOverlays(context)
            ) {
                return false
            }
            val now = System.currentTimeMillis()
            if (now - lastStartAttemptMs < START_DEBOUNCE_MS) return false
            lastStartAttemptMs = now
            return try {
                val intent = Intent(context, OverlayService::class.java)
                    .setAction(ACTION_START)
                context.startService(intent)
                true
            } catch (_: Exception) {
                false
            }
        }
    }

    private var windowManager: WindowManager? = null
    private var bubbleView: View? = null
    private var bubbleParams: WindowManager.LayoutParams? = null
    private var bubbleVisible = false
    private var preferredX: Int? = null
    private var lastAnchorBottom: Int? = null
    private var isDragging = false

    override fun onCreate() {
        super.onCreate()
        instance = this
        windowManager = getSystemService(WINDOW_SERVICE) as WindowManager
        pendingAnchorBottom?.let { show(it) }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }

        isRunning = true

        // The bubble is shown by the accessibility service on the next focus
        // event. A null intent means Android restarted the service.
        if (intent == null) {
            pendingAnchorBottom?.let { show(it) }
        }
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        hide()
        instance = null
        isRunning = false
        super.onDestroy()
    }

    private fun show(anchorBottom: Int) {
        if (!canDrawOverlays()) {
            stopSelf()
            return
        }
        val wm = windowManager ?: return
        // Typing in the target app fires frequent content events. Repositioning
        // for an unchanged anchor would make the bubble jitter (and would fight
        // a drag), so only move when the keyboard/field boundary really moved.
        if (bubbleVisible && (isDragging || lastAnchorBottom == anchorBottom)) return
        lastAnchorBottom = anchorBottom

        val view = bubbleView ?: createBubbleView().also { bubbleView = it }
        if (!bubbleVisible) {
            val params = createLayoutParams(anchorBottom)
            bubbleParams = params
            try {
                wm.addView(view, params)
                bubbleVisible = true
            } catch (_: Exception) {
                bubbleVisible = false
                return
            }
        }

        val params = bubbleParams ?: return
        val size = dp(BUBBLE_SIZE_DP)
        val margin = dp(BUBBLE_MARGIN_DP)
        val maxY = max(margin, screenHeight() - size - margin)
        params.y = (anchorBottom - size - margin).coerceIn(margin, maxY)
        params.x = (preferredX ?: (screenWidth() - size - margin))
            .coerceIn(0, max(0, screenWidth() - size))
        try {
            wm.updateViewLayout(view, params)
        } catch (_: Exception) {
            // The window may have been removed by the system; the next focus
            // event will recreate it.
        }
    }

    private fun hide() {
        val view = bubbleView ?: return
        if (!bubbleVisible) return
        try {
            windowManager?.removeView(view)
        } catch (_: Exception) {
            // Already detached.
        }
        bubbleVisible = false
    }

    private fun createBubbleView(): View {
        val size = dp(BUBBLE_SIZE_DP)
        val container = FrameLayout(this)
        val background = GradientDrawable(
            GradientDrawable.Orientation.TL_BR,
            intArrayOf(Color.parseColor("#F87171"), Color.parseColor("#DC2626")),
        ).apply {
            shape = GradientDrawable.OVAL
            setStroke(dp(2f), Color.parseColor("#66FFFFFF"))
        }
        container.background = background
        container.elevation = dp(8f).toFloat()
        container.contentDescription =
            getString(R.string.overlay_bubble_content_description)

        val icon = ImageView(this)
        icon.setImageResource(R.drawable.ic_mic_overlay)
        icon.contentDescription =
            getString(R.string.overlay_bubble_content_description)
        container.addView(
            icon,
            FrameLayout.LayoutParams(dp(BUBBLE_ICON_DP), dp(BUBBLE_ICON_DP), Gravity.CENTER),
        )

        container.setOnTouchListener(makeDragListener(size))
        return container
    }

    private fun makeDragListener(size: Int): View.OnTouchListener {
        val touchSlop = ViewConfiguration.get(this).scaledTouchSlop
        var startX = 0
        var startY = 0
        var downRawX = 0f
        var downRawY = 0f
        var dragging = false

        return View.OnTouchListener { _, event ->
            val params = bubbleParams ?: return@OnTouchListener false
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    startX = params.x
                    startY = params.y
                    downRawX = event.rawX
                    downRawY = event.rawY
                    dragging = false
                    isDragging = false
                    true
                }

                MotionEvent.ACTION_MOVE -> {
                    val dx = (event.rawX - downRawX).roundToInt()
                    val dy = (event.rawY - downRawY).roundToInt()
                    if (!dragging && (abs(dx) > touchSlop || abs(dy) > touchSlop)) {
                        dragging = true
                        isDragging = true
                    }
                    if (dragging) {
                        params.x = (startX + dx).coerceIn(0, max(0, screenWidth() - size))
                        params.y = (startY + dy).coerceIn(0, max(0, screenHeight() - size))
                        preferredX = params.x
                        try {
                            windowManager?.updateViewLayout(bubbleView, params)
                        } catch (_: Exception) {
                            // Keep dragging even if one frame could not be applied.
                        }
                    }
                    true
                }

                MotionEvent.ACTION_UP -> {
                    if (!dragging) {
                        hide()
                        openDictationActivity()
                    }
                    isDragging = false
                    true
                }

                MotionEvent.ACTION_CANCEL -> {
                    dragging = false
                    isDragging = false
                    true
                }

                else -> false
            }
        }
    }

    private fun openDictationActivity() {
        val intent = Intent(this, OverlayDictationActivity::class.java)
            .addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP,
            )
        try {
            startActivity(intent)
        } catch (_: Exception) {
            // No activity could be opened; leave the bubble available.
            pendingAnchorBottom?.let { show(it) }
        }
    }

    private fun createLayoutParams(anchorBottom: Int): WindowManager.LayoutParams {
        val size = dp(BUBBLE_SIZE_DP)
        val windowType = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        } else {
            @Suppress("DEPRECATION")
            WindowManager.LayoutParams.TYPE_PHONE
        }
        return WindowManager.LayoutParams(
            size,
            size,
            windowType,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            val margin = dp(BUBBLE_MARGIN_DP)
            x = (screenWidth() - size - margin).coerceAtLeast(0)
            y = (anchorBottom - size - margin)
                .coerceIn(margin, max(margin, screenHeight() - size - margin))
        }
    }

    private fun canDrawOverlays(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.M || Settings.canDrawOverlays(this)

    private fun screenWidth(): Int = resources.displayMetrics.widthPixels

    private fun screenHeight(): Int = resources.displayMetrics.heightPixels

    private fun dp(value: Float): Int =
        (value * resources.displayMetrics.density).roundToInt()
}
