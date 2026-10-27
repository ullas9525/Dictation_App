package com.example.dictation_app

import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.SystemClock
import android.provider.Settings
import android.util.Log
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
 * The window is hosted by [DictationAccessibilityService], not by a foreground
 * service, so the bubble needs **no persistent notification**: Android requires
 * one only for a running foreground service, and the accessibility binding is
 * already the thing that decides when the bubble may exist (a focused,
 * allow-listed text field). If the user disables the accessibility service,
 * [detach] removes the window with it.
 *
 * The bubble is intentionally tiny and boring: not focusable, never recording by
 * itself, and it only opens [OverlayDictationActivity] on tap.
 *
 * All methods must be called on the main thread (accessibility callbacks and
 * click listeners already are).
 */
object BubbleOverlay {

    // Shared with the Flutter Settings screen (FlutterSharedPreferences uses the
    // "flutter." prefix for every Dart-written key).
    private const val PREFS_NAME = "FlutterSharedPreferences"
    private const val PREF_OVERLAY_ENABLED = "flutter.overlay_enabled"
    private const val PREF_PRIVACY_MODE = "flutter.overlay_privacy_mode"

    /** Compact mic bubble: small enough not to cover the message bar. */
    private const val BUBBLE_SIZE_DP = 44f
    private const val BUBBLE_ICON_DP = 22f
    private const val BUBBLE_MARGIN_DP = 10f

    /**
     * Safety net: if the sheet is destroyed without running its cleanup
     * (process-level crash, OEM task killer), the bubble must not stay hidden
     * forever. Generous enough for a long recording session.
     */
    private const val DICTATION_ACTIVE_TIMEOUT_MS = 15 * 60 * 1000L

    private var appContext: Context? = null
    private var windowManager: WindowManager? = null
    private var bubbleView: View? = null
    private var bubbleParams: WindowManager.LayoutParams? = null
    private var bubbleVisible = false
    private var preferredX: Int? = null
    private var lastAnchorBottom: Int? = null
    private var isDragging = false
    private var pendingAnchorBottom: Int? = null

    /**
     * True from the moment the dictation sheet is launched until it is
     * destroyed. This is the single source of truth for "the pill is on
     * screen", and it must not be inferred from window focus: the sheet is
     * `FLAG_NOT_FOCUSABLE`, so the input-focus owner stays the app underneath
     * and accessibility still reports that app as active.
     */
    @Volatile
    private var dictationActive = false

    @Volatile
    private var dictationActiveSinceMs = 0L

    /**
     * Monotonic owner token. An activity instance that is being replaced
     * (rotate / re-create) must not clear the state that its successor has
     * already claimed, so only the newest owner may end dictation.
     */
    @Volatile
    private var dictationGeneration = 0L

    /** Binds the bubble to the accessibility service that will host it. */
    fun attach(context: Context) {
        appContext = context.applicationContext
        windowManager =
            context.applicationContext.getSystemService(Context.WINDOW_SERVICE)
                as WindowManager
        // A bubble left over from a previous binding must not survive.
        if (isPrivacyMode(context) || !isOverlayEnabled(context)) hide()
    }

    /** Releases the window (accessibility service disabled or destroyed). */
    fun detach() {
        hide()
        bubbleView = null
        bubbleParams = null
        preferredX = null
        pendingAnchorBottom = null
        windowManager = null
        appContext = null
    }

    /** True while the bubble window is hosted (accessibility service bound). */
    fun isAttached(): Boolean = windowManager != null

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
     * Marks the sheet as on screen and removes the bubble in one step. Returns
     * the generation token the caller must pass back to [endDictation] so a
     * stale instance cannot clear a newer claim.
     *
     * Order matters: the flag is set *before* the launch, so an accessibility
     * re-evaluation triggered by the activity window (or by the still-visible
     * IME) can never recreate the bubble in the gap between hiding it and the
     * activity actually starting.
     */
    fun beginDictation(): Long {
        dictationGeneration += 1
        dictationActiveSinceMs = SystemClock.elapsedRealtime()
        dictationActive = true
        Log.d("OverlayDebug", "dictation active: bubble hidden (gen=$dictationGeneration)")
        hide()
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

    /** True when the user's explicit Privacy mode must suppress everything. */
    fun isPrivacyMode(context: Context): Boolean =
        prefs(context).getBoolean(PREF_PRIVACY_MODE, false)

    /** Mirrors the Flutter "Enable floating bubble" toggle. */
    fun isOverlayEnabled(context: Context): Boolean =
        prefs(context).getBoolean(PREF_OVERLAY_ENABLED, false)

    /**
     * Shows/repositions the bubble. [anchorBottom] is a screen Y coordinate the
     * bubble should sit above (the IME top, or the focused field top when the
     * keyboard is not exposed as a window).
     */
    fun show(anchorBottom: Int) {
        val context = appContext ?: return
        pendingAnchorBottom = anchorBottom

        if (isPrivacyMode(context) || !isOverlayEnabled(context)) {
            hide()
            return
        }
        if (!canDrawOverlays(context)) {
            hide()
            return
        }
        // The visualizer owns the screen while it is open. Remember the anchor
        // so the bubble can come back afterwards, but never draw over the pill.
        if (isDictationActive()) {
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

        val view = bubbleView ?: createBubbleView(context).also { bubbleView = it }
        if (!bubbleVisible) {
            val params = createLayoutParams(context, anchorBottom)
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
        val size = dp(context, BUBBLE_SIZE_DP)
        val margin = dp(context, BUBBLE_MARGIN_DP)
        val maxY = max(margin, screenHeight(context) - size - margin)
        params.y = (anchorBottom - size - margin).coerceIn(margin, maxY)
        params.x = (preferredX ?: (screenWidth(context) - size - margin))
            .coerceIn(0, max(0, screenWidth(context) - size))
        try {
            wm.updateViewLayout(view, params)
        } catch (_: Exception) {
            // The window may have been removed by the system; the next focus
            // event will recreate it.
        }
    }

    /** Removes the bubble window. Safe to call at any time, on any thread usage. */
    fun hide() {
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

    private fun createBubbleView(context: Context): View {
        val size = dp(context, BUBBLE_SIZE_DP)
        val container = FrameLayout(context)
        val background = GradientDrawable(
            GradientDrawable.Orientation.TL_BR,
            intArrayOf(Color.parseColor("#F87171"), Color.parseColor("#DC2626")),
        ).apply {
            shape = GradientDrawable.OVAL
            setStroke(dp(context, 2f), Color.parseColor("#66FFFFFF"))
        }
        container.background = background
        container.elevation = dp(context, 8f).toFloat()
        container.contentDescription =
            context.getString(R.string.overlay_bubble_content_description)

        val icon = ImageView(context)
        icon.setImageResource(R.drawable.ic_mic_overlay)
        icon.contentDescription =
            context.getString(R.string.overlay_bubble_content_description)
        container.addView(
            icon,
            FrameLayout.LayoutParams(
                dp(context, BUBBLE_ICON_DP),
                dp(context, BUBBLE_ICON_DP),
                Gravity.CENTER,
            ),
        )

        container.setOnTouchListener(makeDragListener(context, size))
        return container
    }

    private fun makeDragListener(context: Context, size: Int): View.OnTouchListener {
        val touchSlop = ViewConfiguration.get(context).scaledTouchSlop
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
                        params.x = (startX + dx)
                            .coerceIn(0, max(0, screenWidth(context) - size))
                        params.y = (startY + dy)
                            .coerceIn(0, max(0, screenHeight(context) - size))
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
                        openDictationActivity(context)
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

    private fun openDictationActivity(context: Context) {
        // Privacy mode / the overlay toggle blocks the activity at the last
        // possible moment, even if a stale bubble view somehow survived.
        if (isPrivacyMode(context) || !isOverlayEnabled(context)) {
            Log.d(
                "OverlayDebug",
                "openDictationActivity blocked: overlay disabled or privacy mode on",
            )
            hide()
            return
        }
        // Claim the screen first: the accessibility service may re-evaluate in
        // response to the new activity window or the still-visible IME, and
        // from that moment on it must not put the bubble back.
        beginDictation()
        val intent = Intent(context, OverlayDictationActivity::class.java)
            .addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP,
            )
        try {
            context.startActivity(intent)
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

    private fun createLayoutParams(
        context: Context,
        anchorBottom: Int,
    ): WindowManager.LayoutParams {
        val size = dp(context, BUBBLE_SIZE_DP)
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
            val margin = dp(context, BUBBLE_MARGIN_DP)
            x = (screenWidth(context) - size - margin).coerceAtLeast(0)
            y = (anchorBottom - size - margin)
                .coerceIn(margin, max(margin, screenHeight(context) - size - margin))
        }
    }

    private fun canDrawOverlays(context: Context): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
            Settings.canDrawOverlays(context)

    private fun screenWidth(context: Context): Int =
        context.resources.displayMetrics.widthPixels

    private fun screenHeight(context: Context): Int =
        context.resources.displayMetrics.heightPixels

    private fun dp(context: Context, value: Float): Int =
        (value * context.resources.displayMetrics.density).roundToInt()

    private fun prefs(context: Context): SharedPreferences =
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
}
