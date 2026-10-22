package dev.repro.repro_app

import android.os.Bundle
import android.util.Log
import android.view.View
import android.view.ViewGroup
import android.webkit.WebView
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.lang.ref.WeakReference

/**
 * Test harness only. Terminates the (shared) WebView renderer from inside the app via
 * WebViewRenderProcess.terminate() — no CDP, no adb. The WebView used for the call is one of the
 * plugin's own InAppWebViews found in the view tree (hybrid composition), so the app contains no
 * WebView other than the ones created by flutter_inappwebview.
 */
class MainActivity : FlutterActivity() {
    private val seen = mutableListOf<WeakReference<WebView>>()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val killInDispose = intent?.getStringExtra("scenario") == "B"
        System.setProperty("iawv.repro.killInDispose", if (killInDispose) "1" else "0")
        Log.w(TAG, "onCreate extras=${intent?.extras?.keySet()?.associateWith { intent?.extras?.get(it) }} killInDispose=$killInDispose")
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "repro").setMethodCallHandler { call, result ->
            when (call.method) {
                "getConfig" -> result.success(
                    mapOf(
                        "scenario" to (intent?.getStringExtra("scenario") ?: ""),
                        "delay" to (intent?.getIntExtra("delay", 0) ?: 0),
                        "method" to (intent?.getStringExtra("method") ?: "kill"),
                        "thenKillAfter" to (intent?.getIntExtra("thenKillAfter", -1) ?: -1),
                    )
                )
                "remember" -> {
                    collect()
                    result.success(null)
                }
                "terminate" -> {
                    val reason = call.argument<String>("reason") ?: ""
                    val useCrash = intent?.getStringExtra("method") == "crash" && call.argument<Boolean>("forceKill") != true
                    result.success(if (useCrash) crash(reason, call.argument<String>("target") ?: "last") else terminate(reason))
                }
                "log" -> {
                    Log.w(TAG, "dart: ${call.argument<String>("msg")}")
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    /** Walks the view tree and remembers every WebView found (weakly). */
    private fun collect(): List<WebView> {
        val found = mutableListOf<WebView>()
        fun walk(v: View) {
            if (v is WebView) found.add(v)
            if (v is ViewGroup) for (i in 0 until v.childCount) walk(v.getChildAt(i))
        }
        walk(window.decorView)
        for (w in found) if (seen.none { it.get() === w }) seen.add(WeakReference(w))
        seen.removeAll { it.get() == null }
        Log.w(TAG, "collect inTree=${found.map { id(it) }} remembered=${seen.mapNotNull { it.get() }.map { "${id(it)}(attached=${it.isAttachedToWindow})" }}")
        return found
    }

    private fun terminate(reason: String): Map<String, Any?> {
        if (!WebViewFeature.isFeatureSupported(WebViewFeature.WEB_VIEW_RENDERER_TERMINATE)) {
            Log.w(TAG, "terminate: WEB_VIEW_RENDERER_TERMINATE not supported")
            return mapOf("ok" to false)
        }
        val inTree = collect()
        val candidates = (inTree + seen.mapNotNull { it.get() }).distinct()
        for (w in candidates) {
            try {
                val rp = WebViewCompat.getWebViewRenderProcess(w) ?: continue
                val ok = rp.terminate()
                Log.w(TAG, "terminate reason=$reason via id=${id(w)} attached=${w.isAttachedToWindow} ok=$ok")
                if (ok) return mapOf("ok" to true, "via" to id(w))
            } catch (t: Throwable) {
                Log.w(TAG, "terminate via id=${id(w)} threw $t")
            }
        }
        Log.w(TAG, "terminate reason=$reason: no live renderer among ${candidates.map { id(it) }}")
        return mapOf("ok" to false)
    }

    /**
     * didCrash=true path: navigates an attached plugin WebView to chrome://crash, which crashes the
     * shared renderer (same debug URL the AOSP WebView onRenderProcessGone tests use).
     * Only succeeds once the WebView has a live renderer, so callers poll like terminate().
     * target: "last" = newest attached WebView in the view tree, "first" = oldest remembered one.
     */
    private fun crash(reason: String, target: String): Map<String, Any?> {
        val inTree = collect()
        val w = if (target == "first") seen.firstNotNullOfOrNull { it.get() } else inTree.lastOrNull { it.isAttachedToWindow }
        if (w == null) {
            Log.w(TAG, "crash reason=$reason: no attached WebView")
            return mapOf("ok" to false)
        }
        val alive = try {
            WebViewFeature.isFeatureSupported(WebViewFeature.WEB_VIEW_RENDERER_TERMINATE) &&
                WebViewCompat.getWebViewRenderProcess(w) != null && w.progress == 100
        } catch (t: Throwable) { false }
        if (!alive) {
            Log.w(TAG, "crash reason=$reason: id=${id(w)} renderer not ready (progress=${w.progress})")
            return mapOf("ok" to false)
        }
        Log.w(TAG, "crash reason=$reason target=$target via id=${id(w)} attached=${w.isAttachedToWindow} loadUrl(chrome://crash)")
        w.loadUrl("chrome://crash")
        return mapOf("ok" to true, "via" to id(w))
    }

    private fun id(w: WebView) = System.identityHashCode(w)

    companion object {
        private const val TAG = "REPRO"
    }
}
