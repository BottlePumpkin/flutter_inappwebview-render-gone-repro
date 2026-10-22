# repro_app — flutter_inappwebview: renderer gone during `dispose()` kills the app (Android)

Minimal Flutter app that shows that an `InAppWebView` whose `dispose()` has started but whose
`destroy()` has not run yet makes Android WebView terminate the **whole app** when the renderer
process goes away, even though the app handles `onRenderProcessGone`.

The app has no WebViews other than the ones created by `flutter_inappwebview`. The renderer is
terminated from inside the app (no CDP, no adb):

- `kill`: `WebViewRenderProcess.terminate()` on one of the plugin's WebViews → `didCrash=false`
  (same path as a low-memory kill).
- `crash`: `loadUrl("chrome://crash")` on one of the plugin's WebViews → `didCrash=true`.

## Setup

The app uses `flutter_inappwebview` from a local clone next to this repository (path dependencies
in `pubspec.yaml`):

```
some_dir/
├── flutter_inappwebview/                   # upstream clone
└── flutter_inappwebview-render-gone-repro/ # this repo
```

```bash
git clone https://github.com/pichillilorenzo/flutter_inappwebview.git
cd flutter_inappwebview && git checkout 17527cae   # master, 6.2.0-beta.3 / android 1.2.0-beta.3
```

Apply one of the patches in `patches/` to the clone (`git apply ../flutter_inappwebview-render-gone-repro/patches/<name>`),
then build and install:

| patch | content |
|---|---|
| `instrument.patch` | logs only (`IAWV-dispose`, `IAWV-client` tags), no behavior change. Also adds the scenario B hook, which is gated by a system property the app sets. Used for "before fix". |
| `instrument-fixed.patch` | the same logs plus the fix. Used for "after fix". |
| `fix.patch` | the fix only, no logs (the PR). Apply it with `git am` or `git apply`. |

```bash
cd flutter_inappwebview-render-gone-repro
flutter build apk --release && adb install -r build/app/outputs/flutter-apk/app-release.apk
```

## Scenarios

Each run is a cold start driven by intent extras:
`adb shell am start -n dev.repro.repro_app/.MainActivity --es scenario X --ei delay N --es method kill|crash`

The home page shows one `InAppWebView` with `useOnRenderProcessGone: true`. Its
`onRenderProcessGone` recreates the WebView with a new widget key, the usual recovery pattern, and
that disposes the old platform WebView.

| id | what happens | method |
|---|---|---|
| K | kill once → recreate (no second kill) | kill |
| A | kill → recreate → kill the respawned renderer as soon as it is up, `delay` ms after the recreate | kill |
| B | recreate without a kill; the instrumented plugin terminates the renderer right after `dispose()` issues `loadUrl("about:blank")` (deterministic) | kill |
| C | push a second WebView page → pop it → kill `delay` ms after the page's `State.dispose()` | kill |
| G | push a second WebView page → crash the renderer through the home WebView → pop the second page `delay` ms later, while the crash is still being reported | crash |

`[METHOD=crash] tool/run.sh <label> <scenario> <delay> <runs>` runs N cold starts and saves the full logcat of each
to `logs/<label>/`. `tool/summarize.sh logs/<label>` classifies each run from its log:

- `KILL_UNHANDLED`: `Render process (pid) kill (OOM or update) wasn't handed by all associated webviews, killing application.`
- `CRASH_UNHANDLED`: `[FATAL:...crashpad_client_linux.cc] Render process (pid)'s crash wasn't handled by all associated  webviews, triggering application crash.`
- `ALIVE`: the app logged `ALIVE` 5 s after the scenario (15 s for `crash`).

## Results (emulator Pixel 9, Android 16, WebView 155.0.8059.43, Flutter 3.44.4)

App died, out of 10 cold starts:

| scenario | method | before fix (`instrument.patch`) | after fix (`instrument-fixed.patch`) | `fix.patch` only |
|---|---|---|---|---|
| A, delay 0 | kill (`didCrash=false`) | **10/10** | 0/10 | 0/10 |
| B | kill (`didCrash=false`) | **10/10** | 0/10 | – (needs the hook) |
| C, delay 0 | kill (`didCrash=false`) | **3/10** | 0/10 | – |
| G, delay 500 | crash (`didCrash=true`) | **9/10** | 0/10 | 0/5 |

Every app death in the "before" column is preceded by
`IAWV-dispose: dispose client onRenderProcessGone ... returns=false` for the WebView that is being
disposed. The other WebViews in the same run returned `true` through the plugin's normal client.
See `evidence/` for log excerpts and `evidence/summary_*.tsv` for each run.
