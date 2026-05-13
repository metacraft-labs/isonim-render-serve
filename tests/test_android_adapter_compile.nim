## test_android_adapter_compile — RS-M6 Linux-side cross-compile gate.
##
## RS-M6's actual Android-runtime-touching capture path (in
## `src/isonim_render_serve/adapters/android_adapter.nim`) is gated
## `when defined(android)` because
##
##   1. `isonim_android/jni_callbacks` raises a hard `{.error.}`
##      unless either `-d:mockJni` (host-side test shim) or
##      `-d:commandBuffer` (real Android JNI bridge) is set, so the
##      `isonim_android/renderer` import itself can't live in the
##      plain Linux build (matching the EX-M6 pattern in
##      `isonim-examples/task_app/main_android.nim`).
##   2. The capture path drives
##      `android.view.View.draw(android.graphics.Canvas)` into a
##      `android.graphics.Bitmap` — both Java classes that live
##      inside the Android runtime (ART), reachable only via JNI
##      from a process running on an emulator or device.
##
## **Canonical RS-M6 acceptance gate.** Running a Nim test binary
## inside ART is non-trivial ceremony, and the same Nim adapter code
## is already driven through JNI by the Kotlin instrumented test at
##
##   isonim-android/app/src/androidTest/kotlin/com/metacraft/isonim/
##   examples/AdapterCaptureTest.kt
##
## The Kotlin instrumented test is the binding "real-device passes"
## gate for RS-M6: it launches a real `MainActivity`, drives a real
## scripted scenario, and calls
## `TaskAppBridge.captureRootViewToRgba(width, height)` which is a
## Nim-implemented JNI export (`Java_*_TaskAppBridge_captureRootViewToRgba`
## in `isonim-examples/task_app/main_android.nim`). Run it via:
##
##   cd isonim-android && nix develop --command \
##     ./gradlew :app:connectedNimexamplesDebugAndroidTest
##
## The previous Nim-only scaffold (`test_android_adapter_android_only.nim`)
## was deleted as part of RS-M6 completion — keeping a Nim test file
## that only says "real test lives elsewhere" was strictly worse than
## the cross-link in this docstring.
##
## This test runs *here on Linux* and validates the adapter surface
## without needing a device, by:
##
##   1. **Cross-compile gate.** Driving `nim check --os:android
##      -d:mockJni` over the real
##      `adapters/android_adapter.nim` and
##      `adapters/android_input_adapter.nim` modules — `nim check`
##      doesn't run the linker, so even though `--os:android`
##      defines `android` and pulls
##      `isonim_android/renderer` transitively, the `{.error.}` in
##      `jni_callbacks` is satisfied by `-d:mockJni`. The
##      type-level surface is validated against the Android target.
##      Drift in `AndroidRenderer` / `AndroidElement` / `fireEvent`
##      API surfaces here, not on the emulator host.
##
##      Mirrors the EX-M6 `test_android_leaves_compile.nim` cross-
##      compile-gate pattern. Unlike EX-M6 (which used a fixture
##      under `tests/helpers/views_compile_android.nim` to keep
##      the gate parallel with the EX-M5 Cocoa case), RS-M6 drives
##      `nim check --os:android` over the *real* adapter sources
##      directly — the adapters don't transit through
##      `isonim/core/signals` and don't include
##      `task_app/core/views`, so no fixture is needed (same
##      simplification RS-M5 made for the Cocoa cross-compile
##      gate).
##
##   2. **Static surface check.** Greping the real adapter sources
##      to assert the canonical entry points (`renderFrame`,
##      `toAny`, `newAndroidFrameSource`; `submit`,
##      `newAndroidInputSink`) are present plus the
##      `when defined(android):` gating is intact, so accidental
##      ungating (which would break the Linux build the moment the
##      macOS engineer's branch lands) is caught.
##
## See also `isonim-render-stream.status.org` § RS-M6 for the
## milestone's hand-off checklist.

import std/[unittest, os, osproc, strutils]

const
  # The repo root is two parents up from this test file. We use
  # `currentSourcePath()` so the test works regardless of where it's
  # invoked from (Justfile recipes `cd` into the repo first; manual
  # `nim c -r` invocations might not).
  repoRoot = currentSourcePath().parentDir.parentDir
  androidAdapterPath =
    repoRoot / "src" / "isonim_render_serve" / "adapters" / "android_adapter.nim"
  androidInputAdapterPath =
    repoRoot / "src" / "isonim_render_serve" / "adapters" / "android_input_adapter.nim"

suite "RS-M6: Android adapter cross-compile gate (Linux-side)":

  test "cross-compile: nim check --os:android accepts android_adapter.nim":
    ## Drive `nim check --os:android -d:mockJni` over the real
    ## Android frame-source adapter. The adapter imports
    ## `isonim_android/renderer` under `when defined(android)`,
    ## which `nim check --os:android` enters; the `-d:mockJni`
    ## switch satisfies `jni_callbacks`'s hard `{.error.}` requiring
    ## either `-d:mockJni` or `-d:commandBuffer`. If
    ## `AndroidRenderer`'s public API drifts (e.g. `fireEvent`
    ## changes shape), this gate catches it from this Linux host.
    let cmd = "nim check --os:android --mm:orc " &
              "-d:mockJni " &
              "--styleCheck:usages --styleCheck:error " &
              "--path:" & (repoRoot / "src") & " " &
              "--path:" & (repoRoot / "tests") & " " &
              androidAdapterPath.quoteShell
    let (output, exitCode) = execCmdEx(cmd)
    if exitCode != 0:
      echo "----- nim check --os:android output (android_adapter) -----"
      echo output
      echo "-----------------------------------------------------------"
    check exitCode == 0

  test "cross-compile: nim check --os:android accepts android_input_adapter.nim":
    ## Same idea for the input adapter. `r.fireEvent` is gated
    ## `when defined(android)` inside `submit`, so the Android
    ## path is exercised here (and only here on the Linux host).
    let cmd = "nim check --os:android --mm:orc " &
              "-d:mockJni " &
              "--styleCheck:usages --styleCheck:error " &
              "--path:" & (repoRoot / "src") & " " &
              "--path:" & (repoRoot / "tests") & " " &
              androidInputAdapterPath.quoteShell
    let (output, exitCode) = execCmdEx(cmd)
    if exitCode != 0:
      echo "----- nim check --os:android output (android_input_adapter) -----"
      echo output
      echo "-----------------------------------------------------------------"
    check exitCode == 0

  test "static surface: android_adapter declares the canonical entry points":
    ## Catch accidental rename / deletion of the adapter's public
    ## surface (the bridge consumes `toAny`; tests construct via
    ## `newAndroidFrameSource`; the macOS engineer wires real
    ## capture inside `renderFrame`).
    check fileExists(androidAdapterPath)
    let body = readFile(androidAdapterPath)
    check "type" in body
    check "AndroidFrameSource* = ref object" in body
    check "AndroidCaptureMode* = enum" in body
    check "proc renderFrame*(src: AndroidFrameSource): Frame" in body
    check "proc close*(src: AndroidFrameSource)" in body
    check "proc newAndroidFrameSource*" in body
    check "proc toAny*(src: AndroidFrameSource): AnyFrameSource" in body
    # Android-runtime-touching body must be android-gated so the
    # Linux build stays clean; protect against accidental ungating.
    # RS-M11c relaxed the gate to also accept ``defined(mockJni)`` so
    # the host-side launcher can build an in-process Android tree
    # for the element-tree manifest builder under ``-d:mockJni``.
    check ("when defined(android):" in body or
           "when defined(android) or defined(mockJni):" in body)
    # The capture-path spec must remain documented for the macOS
    # engineer. Drop any of these strings and the gate fails before
    # the engineer ever opens the file.
    check "View.draw(Canvas)" in body
    check "Bitmap" in body
    check "screencap" in body

  test "static surface: android_input_adapter declares the canonical entry points":
    check fileExists(androidInputAdapterPath)
    let body = readFile(androidInputAdapterPath)
    check "AndroidInputSink* = ref object" in body
    check "HitTester* = proc(x, y: int): AndroidElement" in body
    check "proc newAndroidInputSink*" in body
    check "proc submit*(sink: AndroidInputSink; event: InputEvent)" in body
    check "proc toAny*(sink: AndroidInputSink): AnyInputSink" in body
    # JNI `fireEvent` dispatch must be android-gated.
    check "when defined(android):" in body
    check "sink.renderer.fireEvent(target, \"click\")" in body
