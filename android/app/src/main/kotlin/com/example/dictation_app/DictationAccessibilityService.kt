package com.example.dictation_app

import android.accessibilityservice.AccessibilityService
import android.content.Context
import android.content.SharedPreferences
import android.graphics.Rect
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo
import android.widget.Toast

/**
 * Watches focus in allow-listed apps and performs the final paste.
 *
 * It deliberately does **not** read the screen for logging or storage. The only
 * node it keeps is the currently focused editable field (needed to paste after
 * the Flutter sheet closes), and it is replaced on every focus change.
 *
 * The service is what makes the bubble context-aware: it shows the bubble only
 * while a text field is focused in a target app, hides it when focus moves away,
 * and uses the IME window bounds to keep the bubble just above the keyboard.
 */
class DictationAccessibilityService : AccessibilityService() {

    companion object {
        private const val PREFS_NAME = "FlutterSharedPreferences"
        private const val PREF_PREFIX = "flutter."
        private const val DEFAULT_TARGET_APPS = "com.whatsapp"

        private const val EVALUATE_DEBOUNCE_MS = 90L
        private const val INSERT_DELAY_MS = 700L
        private const val PASTE_VERIFY_DELAY_MS = 450L

        @Volatile
        private var instance: DictationAccessibilityService? = null

        fun isConnected(): Boolean = instance != null

        /**
         * Queues an insert into the last focused editable field. Returns false
         * when the service is not running (the caller then leaves the text on
         * the clipboard as a manual fallback).
         */
        fun queueInsert(text: String): Boolean {
            val service = instance ?: return false
            if (text.isEmpty()) return false
            service.handler.postDelayed({ service.performInsert(text) }, INSERT_DELAY_MS)
            return true
        }

        /**
         * Re-checks focus shortly after the overlay sheet closes. The target app
         * does not always emit a window event when it regains focus, so the
         * bubble would otherwise stay hidden until the next focus change.
         */
        fun requestEvaluate(delayMs: Long = 350L) {
            val service = instance ?: return
            service.handler.postDelayed({ service.evaluateFocus() }, delayMs)
        }
    }

    private val handler = Handler(Looper.getMainLooper())
    private val evaluateRunnable = Runnable { evaluateFocus() }

    private var lastEditable: AccessibilityNodeInfo? = null

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
        // The user may have enabled the service while already sitting in a
        // text field, so look once instead of waiting for the next event.
        handler.postDelayed(evaluateRunnable, 300)
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event == null) return
        when (event.eventType) {
            AccessibilityEvent.TYPE_VIEW_FOCUSED,
            AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED,
            AccessibilityEvent.TYPE_WINDOWS_CHANGED,
            -> scheduleEvaluate()

            AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED -> {
                // Typing fires this constantly. Only re-scan for our own window
                // (to hide the bubble) or an allow-listed app; keyboard show /
                // hide is covered by TYPE_WINDOWS_CHANGED above.
                val eventPackage = event.packageName?.toString()
                if (eventPackage == packageName ||
                    (eventPackage != null && isTargetPackage(eventPackage))
                ) {
                    scheduleEvaluate()
                }
            }
        }
    }

    override fun onInterrupt() {
        OverlayService.hideBubble()
    }

    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null)
        OverlayService.hideBubble()
        if (instance === this) instance = null
        super.onDestroy()
    }

    private fun scheduleEvaluate() {
        handler.removeCallbacks(evaluateRunnable)
        handler.postDelayed(evaluateRunnable, EVALUATE_DEBOUNCE_MS)
    }

    /**
     * Decides whether the bubble should be visible right now.
     *
     * Own activity -> hidden (the sheet is already on screen). Target app with
     * a focused editable field -> shown above the keyboard. Anything else ->
     * hidden. [lastEditable] is intentionally kept when our own activity takes
     * focus, because the paste happens after that activity closes.
     */
    private fun evaluateFocus() {
        if (!overlayEnabled()) {
            OverlayService.hideBubble()
            return
        }

        val activePackage = activePackageName()
        if (activePackage == packageName) {
            OverlayService.hideBubble()
            return
        }

        val node = findFocusedEditable()
        if (node == null) {
            OverlayService.hideBubble()
            return
        }

        // The bubble sits above the keyboard. If no IME window is visible
        // (a message bar focused without the keyboard open), stay hidden so
        // the bubble never interrupts screens that are not currently typing.
        val anchor = anchorBottomFor(node)
        if (anchor == null) {
            OverlayService.hideBubble()
            return
        }

        lastEditable = node
        OverlayService.ensureRunning(this)
        OverlayService.showBubble(anchor)
    }

    private fun activePackageName(): String? = try {
        rootInActiveWindow?.packageName?.toString()
    } catch (_: Exception) {
        null
    }

    private fun findFocusedEditable(): AccessibilityNodeInfo? {
        // Typing fires content events often. Reuse the cached field when it is
        // still focused in the active target app instead of walking the whole
        // hierarchy on every keystroke.
        val activePackage = activePackageName()
        val cached = lastEditable
        if (cached != null && activePackage != null &&
            cached.packageName?.toString() == activePackage &&
            isTargetPackage(activePackage)
        ) {
            try {
                if (cached.refresh() && cached.isEditable && !cached.isPassword &&
                    cached.isFocused
                ) {
                    return cached
                }
            } catch (_: Exception) {
                // Fall through to a fresh scan.
            }
        }

        val windows = try {
            windows
        } catch (_: Exception) {
            null
        } ?: return null

        for (window in windows.asReversed()) {
            if (window.type == AccessibilityWindowInfo.TYPE_INPUT_METHOD) continue
            if (window.type == AccessibilityWindowInfo.TYPE_SYSTEM) continue
            // Only the window the user is actually interacting with may own
            // the bubble. Without this, a background target app in a
            // multi-window/recents state could keep the bubble visible over a
            // completely different app.
            if (!window.isActive && !window.isFocused) continue

            val root = try {
                window.root
            } catch (_: Exception) {
                null
            } ?: continue

            val rootPackage = root.packageName?.toString() ?: continue
            if (rootPackage == packageName || !isTargetPackage(rootPackage)) continue

            val focused = try {
                root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
            } catch (_: Exception) {
                null
            }
            if (focused != null && focused.isEditable && !focused.isPassword) {
                return focused
            }

            // Some editors expose the text field as a child and mark it
            // focused rather than reporting it as FOCUS_INPUT on the root.
            findFocusedEditableBelow(root)?.let { return it }

            // Compatibility fallback: a window with exactly one editable field
            // is unambiguous even when no node advertises focus.
            val editables = ArrayList<AccessibilityNodeInfo>(2)
            collectEditables(root, editables, 0)
            if (editables.size == 1) return editables.first()
        }
        return null
    }

    private fun findFocusedEditableBelow(
        node: AccessibilityNodeInfo,
        depth: Int = 0,
    ): AccessibilityNodeInfo? {
        if (depth > 12) return null
        if (node.isEditable && node.isFocused && !node.isPassword) return node
        for (index in 0 until node.childCount) {
            val child = try {
                node.getChild(index)
            } catch (_: Exception) {
                null
            } ?: continue
            findFocusedEditableBelow(child, depth + 1)?.let { return it }
        }
        return null
    }

    private fun collectEditables(
        node: AccessibilityNodeInfo,
        out: MutableList<AccessibilityNodeInfo>,
        depth: Int,
    ) {
        if (out.size >= 4 || depth > 12) return
        if (node.isEditable && !node.isPassword && node.isVisibleToUser) {
            out.add(node)
            return
        }
        for (index in 0 until node.childCount) {
            val child = try {
                node.getChild(index)
            } catch (_: Exception) {
                null
            } ?: continue
            collectEditables(child, out, depth + 1)
            if (out.size >= 4) return
        }
    }

    /**
     * The bubble's bottom edge: the top of the IME. Returns `null` when no
     * input-method window is on screen — the bubble is only meaningful above
     * the keyboard, never floating over a bare message bar.
     */
    private fun anchorBottomFor(node: AccessibilityNodeInfo): Int? {
        try {
            val windows = try {
                windows
            } catch (_: Exception) {
                null
            }
            if (windows != null) {
                for (window in windows) {
                    if (window.type != AccessibilityWindowInfo.TYPE_INPUT_METHOD) continue
                    val bounds = Rect()
                    window.getBoundsInScreen(bounds)
                    if (bounds.height() > 0 && bounds.top > 0) return bounds.top
                }
            }
        } catch (_: Exception) {
            // Fall through to "no keyboard".
        }
        return null
    }

    private fun performInsert(text: String) {
        val node = findFocusedEditable() ?: lastEditable
        if (node == null) {
            showManualPasteHint()
            return
        }
        try {
            node.refresh()
        } catch (_: Exception) {
            // Still try; some nodes reject refresh but accept actions.
        }
        if (!node.isEditable) {
            showManualPasteHint()
            return
        }

        val before = try {
            node.text?.toString() ?: ""
        } catch (_: Exception) {
            ""
        }

        try {
            node.performAction(AccessibilityNodeInfo.ACTION_FOCUS)
        } catch (_: Exception) {
            // The field is usually already focused.
        }
        moveCaretToEnd(node)

        val pasted = try {
            node.performAction(AccessibilityNodeInfo.ACTION_PASTE)
        } catch (_: Exception) {
            false
        }

        if (!pasted) {
            if (!spliceText(node, before, text)) showManualPasteHint()
            return
        }

        // Verify the paste. If the field is unreadable, assume it worked rather
        // than risk inserting the same text twice via ACTION_SET_TEXT.
        handler.postDelayed({
            val current = findFocusedEditable()
            val after = try {
                current?.text?.toString()
            } catch (_: Exception) {
                null
            }
            if (after == null) return@postDelayed
            if (after == before) {
                if (!spliceText(current ?: node, before, text)) showManualPasteHint()
            }
        }, PASTE_VERIFY_DELAY_MS)
    }

    /**
     * Last-resort insert for editors that ignore ACTION_PASTE. This appends to
     * the existing draft rather than replacing it.
     */
    private fun spliceText(
        node: AccessibilityNodeInfo,
        before: String,
        text: String,
    ): Boolean {
        val merged = before + text
        val arguments = Bundle().apply {
            putCharSequence(
                AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE,
                merged,
            )
        }
        val ok = try {
            node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, arguments)
        } catch (_: Exception) {
            false
        }
        if (ok) moveCaretToEnd(node, merged.length)
        return ok
    }

    private fun moveCaretToEnd(node: AccessibilityNodeInfo, knownLength: Int? = null) {
        val length = knownLength ?: try {
            node.text?.length ?: 0
        } catch (_: Exception) {
            0
        }
        val arguments = Bundle().apply {
            putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, length)
            putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, length)
        }
        try {
            node.performAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, arguments)
        } catch (_: Exception) {
            // Cursor movement is best-effort.
        }
    }

    private fun showManualPasteHint() {
        handler.post {
            Toast.makeText(
                applicationContext,
                R.string.overlay_insert_failed,
                Toast.LENGTH_LONG,
            ).show()
        }
    }

    private fun isTargetPackage(packageName: String): Boolean {
        if (packageName == this.packageName) return false
        val targets = targetPackages()
        return targets.contains("*") || targets.contains(packageName)
    }

    private fun overlayEnabled(): Boolean =
        prefs().getBoolean("${PREF_PREFIX}overlay_enabled", false)

    private fun targetPackages(): Set<String> {
        val raw = prefs().getString(
            "${PREF_PREFIX}overlay_target_apps",
            DEFAULT_TARGET_APPS,
        ) ?: DEFAULT_TARGET_APPS
        return raw
            .split(',')
            .map { it.trim() }
            .filter { it.isNotEmpty() }
            .toSet()
    }

    private fun prefs(): SharedPreferences =
        getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
}
