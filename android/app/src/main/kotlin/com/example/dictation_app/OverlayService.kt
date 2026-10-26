package com.example.dictation_app

import android.app.Service
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.IBinder
import android.os.SystemClock
import android.provider.Settings
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.util.Log
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

        /**
         * True from the moment the dictation sheet is launched until it is
         * destroyed. This is the single source of truth for "the pill is on
         * screen", and it must not be inferred from window focus: the sheet is
         * `FLAG_NOT_FOCUSABLE`, so the input-focus owner stays the app
         * underneath and accessibility still reports that app as active.
         */
        @Volatile
        private var dictationActive: Boolean = false

        @Volatile
        private var dictationActiveSinceMs: Long = 0L

        /**
         * Monotonic owner token. An activity instance that is being replaced
         * (rotate / re-create) must not clear the state that its successor has
         * already claimed, so only the newest owner may end dictation.
         */
        @Volatile
        private var dictationGeneration: Long = 0L

        /**
         * Safety net: if the sheet is destroyed without running its cleanup
         * (process-level crash, OEM task killer), the bubble must not stay
         * hidden forever. Generous enough for a long recording session.
         */
        private const val DICTATION_ACTIVE_TIMEOUT_MS = 15 * 60 * 1000L

        fun isDictationActive(): Boolean {
            if (!dictationActive) return false
            val elapsed = SystemClock.elapsedRealtime() - dictationActiveSinceMs
            if (elapsed > DICTATION_ACTIVE_TIMEOUT_MS) {
                Log.w(
                    "OverlayDebug",
                    "dictationActive expired after ${elapsed}ms; assuming the sheet is gone",
                )
                dictationActive = false
                return false
            }
            return true
        }

        /**
         * Marks the sheet as on screen and removes the bubble in one step.
         * Returns the generation token the caller must pass back to
         * [endDictation] so a stale instance cannot clear a newer claim.
         *
         * Order matters: the flag is set *before* the launch, so an
         * accessibility re-evaluation triggered by the activity window (or by
         * the still-visible IME) can never recreate the bubble in the gap
         * between hiding it and the activity actually starting.
         */
        fun beginDictation(): Long {
            dictationGeneration += 1
            dictationActiveSinceMs = SystemClock.elapsedRealtime()
            dictationActive = true
            Log.d("OverlayDebug", "dictation active: bubble hidden (gen=$dictationGeneration)")
            instance?.hide()
            return dictationGeneration
        }

        /** The sheet is gone: the bubble may be restored by the next evaluation. */
        fun endDictation(generation: Long = -1L) {
            if (!dictationActive) return
            if (generation >= 0L && generation != dictationGeneration) {
                Log.d(
                    "OverlayDebug",
                    "endDictation ignored: gen=$generation is not the owner " +
                        "(current=$dictationGeneration)",
                )
                return
            }
            dictationActive = false
            dictationActiveSinceMs = 0L
            Log.d("OverlayDebug", "dictation inactive: bubble may be restored")
        }

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
        // The visualizer owns the screen while it is open. Remember the anchor
        // so the bubble can come back afterwards, but never draw over the pill.
        if (isDictationActive()) {
            pendingAnchorBottom = anchorBottom
            Log.d("OverlayDebug", "bubble show suppressed: visualizer is active")
            hide()
            return
        }
        val wm = windowManager ?: return

        // `bubbleVisible` can desync from reality if the system dropped the
        // window (overlay permission revoked, display/rotation change). Trust
        // the view, not the flag, so we never add a second bubble — and check
        // this before the "same anchor" shortcut, or a removed view would be
        // skipped forever.
        if (bubbleVisible && bubbleView?.isAttachedToWindow != true) {
            Log.w("OverlayDebug", "bubble was marked visible but is detached; re-adding")
            bubbleVisible = false
        }

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
                Log.d(
                    "OverlayDebug",
                    "bubble shown anchor=$anchorBottom y=${params.y} " +
                        "attached=${view.isAttachedToWindow}",
                )
            } catch (t: Throwable) {
                bubbleVisible = false
                Log.e("OverlayDebug", "bubble addView failed", t)
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
        val view = bubbleView
        val wasVisible = bubbleVisible || view?.isAttachedToWindow == true
        if (view != null && wasVisible) {
            try {
                windowManager?.removeView(view)
            } catch (_: Exception) {
                // Already detached.
            }
        }
        bubbleVisible = false
        // A fresh show() must position itself for the anchor of the moment, so
        // a restored bubble never reuses a stale keyboard position.
        lastAnchorBottom = null
        if (wasVisible) {
            Log.d("OverlayDebug", "bubble hidden (view removed)")
        }
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
                    Log.d("OverlayDebug", "bubble ACTION_DOWN x=${event.x} y=${event.y}")
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
                    Log.d("OverlayDebug", "bubble ACTION_UP dragging=$dragging")
                    if (!dragging) {
                        // beginDictation() inside openDictationActivity() hides
                        // the bubble and sets the active flag before launching.
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
        // Claim the screen first: the accessibility service may re-evaluate in
        // response to the new activity window or the still-visible IME, and
        // from that moment on it must not put the bubble back.
        beginDictation()
        val intent = Intent(this, OverlayDictationActivity::class.java)
            .addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP,
            )
        try {
            startActivity(intent)
            Log.d("OverlayDebug", "openDictationActivity: startActivity ok")
        } catch (t: Throwable) {
            Log.e("OverlayDebug", "openDictationActivity: startActivity failed", t)
            // No activity could be opened. Release the claim and put the
            // bubble back immediately; otherwise it would stay hidden until
            // the next focus change.
            endDictation()
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
