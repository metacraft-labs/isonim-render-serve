## test_cocoa_adapter_compile — RS-M5 Linux-side cross-compile gate.
##
## RS-M5 ships the Cocoa adapter as a partial-linux scaffold: the
## actual AppKit-touching capture path (in
## `src/isonim_render_serve/adapters/cocoa_adapter.nim`) is gated
## `when defined(macosx)` because `isonim_cocoa/renderer` transitively
## imports the AppKit / Objective-C-runtime wrappers, whose link-time
## `{.passL: "-framework Foundation -lobjc ...".}` pragmas cannot
## resolve on a Linux host. The macOS engineer runs the real
## integration test (`test_cocoa_adapter_macos_only.nim`) on a macOS
## box; this test runs *here on Linux* and validates the adapter
## surface without needing AppKit by:
##
##   1. **Cross-compile gate.** Driving `nim check --os:macosx` over
##      the real `adapters/cocoa_adapter.nim` and
##      `adapters/cocoa_input_adapter.nim` modules — `nim check`
##      doesn't run the C linker, so AppKit-link-time pragmas don't
##      bite, and the type-level surface is validated against the
##      macOS target. Drift in `CocoaRenderer` / `CocoaElement` /
##      `fireEvent` API surfaces here, not on the macOS host.
##
##      Mirrors the EX-M5 `test_cocoa_leaves_compile.nim` cross-
##      compile-gate pattern, but RS-M5's adapters don't include
##      `task_app/core/views` and therefore don't transit through the
##      reactive-core macOS regression deferred from EX-M5 — so we can
##      drive `nim check --os:macosx` over the *real* adapter sources
##      directly (no fixture needed). If a future change to
##      `isonim_cocoa/renderer` adds a transitive dependency on
##      `isonim/core/signals` and the deferred reactive-core macOS
##      regression resurfaces, fall back to the EX-M5 fixture pattern.
##
##   2. **Static surface check.** Greping the real adapter sources to
##      assert the canonical entry points (`renderFrame`, `toAny`,
##      `newCocoaFrameSource`; `submit`, `newCocoaInputSink`) are
##      present plus the `when defined(macosx):` gating is intact, so
##      accidental ungating (which would break the Linux build the
##      moment the macOS engineer's branch lands) is caught.
##
## See also `isonim-render-stream.status.org` § RS-M5 for the
## milestone's hand-off checklist.

import std/[unittest, os, osproc, strutils]

const
  # The repo root is two parents up from this test file. We use
  # `currentSourcePath()` so the test works regardless of where it's
  # invoked from (Justfile recipes `cd` into the repo first; manual
  # `nim c -r` invocations might not).
  repoRoot = currentSourcePath().parentDir.parentDir
  cocoaAdapterPath =
    repoRoot / "src" / "isonim_render_serve" / "adapters" / "cocoa_adapter.nim"
  cocoaInputAdapterPath =
    repoRoot / "src" / "isonim_render_serve" / "adapters" / "cocoa_input_adapter.nim"

suite "RS-M5: Cocoa adapter cross-compile gate (Linux-side)":

  test "cross-compile: nim check --os:macosx accepts cocoa_adapter.nim":
    ## Drive `nim check --os:macosx` over the real Cocoa frame-source
    ## adapter. The adapter imports `isonim_cocoa/renderer`, which
    ## `nim check` accepts on both Linux (`SuccessX`) and `--os:macosx`
    ## (the macOS-only `appkit/*` modules type-check cleanly under the
    ## macOS target). If `CocoaRenderer`'s public API drifts, this
    ## gate catches it from this Linux host.
    let cmd = "nim check --os:macosx --mm:orc " &
              "--styleCheck:usages --styleCheck:error " &
              "--path:" & (repoRoot / "src") & " " &
              "--path:" & (repoRoot / "tests") & " " &
              cocoaAdapterPath.quoteShell
    let (output, exitCode) = execCmdEx(cmd)
    if exitCode != 0:
      echo "----- nim check --os:macosx output (cocoa_adapter) -----"
      echo output
      echo "--------------------------------------------------------"
    check exitCode == 0

  test "cross-compile: nim check --os:macosx accepts cocoa_input_adapter.nim":
    ## Same idea for the input adapter. `r.fireEvent` is gated `when
    ## defined(macosx)` inside `submit`, so the macOS path is exercised
    ## here (and only here on the Linux host).
    let cmd = "nim check --os:macosx --mm:orc " &
              "--styleCheck:usages --styleCheck:error " &
              "--path:" & (repoRoot / "src") & " " &
              "--path:" & (repoRoot / "tests") & " " &
              cocoaInputAdapterPath.quoteShell
    let (output, exitCode) = execCmdEx(cmd)
    if exitCode != 0:
      echo "----- nim check --os:macosx output (cocoa_input_adapter) -----"
      echo output
      echo "--------------------------------------------------------------"
    check exitCode == 0

  test "static surface: cocoa_adapter declares the canonical entry points":
    ## Catch accidental rename / deletion of the adapter's public
    ## surface (the bridge consumes `toAny`; tests construct via
    ## `newCocoaFrameSource`; the macOS engineer wires real capture
    ## inside `renderFrame`).
    check fileExists(cocoaAdapterPath)
    let body = readFile(cocoaAdapterPath)
    check "type" in body
    check "CocoaFrameSource* = ref object" in body
    check "CocoaCaptureMode* = enum" in body
    check "proc renderFrame*(src: CocoaFrameSource): Frame" in body
    check "proc close*(src: CocoaFrameSource)" in body
    check "proc newCocoaFrameSource*" in body
    check "proc toAny*(src: CocoaFrameSource): AnyFrameSource" in body
    # AppKit-touching body must be macosx-gated so the Linux build
    # stays clean; protect against accidental ungating.
    check "when defined(macosx):" in body
    # The capture-path spec must remain documented for the macOS
    # engineer. Drop any of these strings and the gate fails before
    # the engineer ever opens the file.
    check "bitmapImageRepForCachingDisplayInRect" in body
    check "CGWindowListCreateImage" in body
    check "NSBitmapImageRep" in body

  test "static surface: cocoa_input_adapter declares the canonical entry points":
    check fileExists(cocoaInputAdapterPath)
    let body = readFile(cocoaInputAdapterPath)
    check "CocoaInputSink* = ref object" in body
    check "HitTester* = proc(x, y: int): CocoaElement" in body
    check "proc newCocoaInputSink*" in body
    check "proc submit*(sink: CocoaInputSink; event: InputEvent)" in body
    check "proc toAny*(sink: CocoaInputSink): AnyInputSink" in body
    # AppKit `fireEvent` dispatch must be macosx-gated.
    check "when defined(macosx):" in body
    check "sink.renderer.fireEvent(target, \"click\")" in body
