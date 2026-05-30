## test_per_backend_hover_dispatch — FUH-M2 Phase A.
##
## Per-backend correctness gate for the hover-dispatch path added to
## every input adapter's ``submit()`` ``iekMouse`` arm. Mirrors the
## ``test_per_backend_diff_stability`` shape: build a synthetic
## shadow tree, drive ``submit`` directly with crafted ``maMove``
## events, then assert against the sink's structured log + against
## handler-side counters wired through the renderer's real
## ``addEventListener`` / ``fireEvent`` plumbing.
##
## For each backend (gpui / freya / cocoa / android-mock) we:
##   1. Build a synthetic shadow tree of one root + two row leaves.
##   2. Register ``"mouseenter"`` / ``"mouseleave"`` handlers on both
##      leaves so the dispatch path's reach is observable through
##      real counters, not just through the sink's log.
##   3. Construct the input sink with a ``hitChain`` callback that
##      delegates to the adapter's ``hitTestPath``.
##   4. Drive a ``maMove`` sequence that crosses the two leaves:
##      a. Move into row 0     → mouseenter on chain[row0, root]
##      b. Move within row 0   → no new fires (hit-test throttle)
##      c. Move into row 1     → mouseleave on prior chain, then
##                                mouseenter on the new chain
##      d. Move out of the tree → mouseleave on the prior chain,
##                                 no mouseenter (chain empty)
##   5. Assert that:
##      * Per-leaf enter/leave counters match the projected
##        deepest-first walk-up dispatch.
##      * The sink's structured log records exactly one
##        ``hover-enter <N>`` and one ``hover-leave <N>`` per
##        observable transition (proving the throttle works).
##
## Per the FUH-M1 audit § 1, the Android adapter previously lacked
## the ``hitChain`` field. FUH-M2 brings the Android sink to parity
## (HitChainTester + hitChain field + optional newAndroidInputSink
## arg + android_adapter.hitTestPath). The Android branch is gated
## ``when defined(mockJni)`` per the existing
## ``test_per_backend_diff_stability`` convention — the Android
## renderer's ``jni_callbacks`` raises a hard ``{.error.}`` without
## either ``-d:mockJni`` or ``-d:commandBuffer``.
##
## The Cocoa backend's hover dispatch is itself gated
## ``when defined(macosx)`` per the partial-Linux scaffold (see the
## FUH-M1 audit § 3.3). On Linux the throttle bookkeeping still
## runs (the sink's ``lastHoveredNode`` / ``lastHoveredChain`` and
## the structured log entries are produced), but the real
## ``r.fireEvent`` AppKit dispatch is deferred. The Cocoa test
## therefore asserts the log / throttle invariants on every host
## and tightens to the handler-counter assertions only under
## ``when defined(macosx)``.

import std/[strutils, unittest]

import isonim_render_serve

# ---------------------------------------------------------------------------
# Shared shape: tree builder yields a parent + two stacked row leaves.
# The walkLayout heuristic (shared across all four adapters) carves a
# 12-pixel header band off the top, then splits the remaining body
# evenly among the children. For a 400x240 surface that lands:
#   * parent: (0, 0, 400, 240)
#   * child 0: (4,  12, 392, 114)
#   * child 1: (4, 126, 392, 114)
# so a click at (200, 50) lands inside child 0 and (200, 180) inside
# child 1; (200, 250) falls outside the tree.
# ---------------------------------------------------------------------------

const
  TreeW = 400
  TreeH = 240
  XInsideRow0 = 200
  YInsideRow0 = 50
  YInsideRow0Alt = 80   # still inside row 0; no new fire expected
  XInsideRow1 = 200
  YInsideRow1 = 180
  XOutside = 200
  YOutside = 320

proc makeMove(x, y: int): InputEvent =
  InputEvent(kind: iekMouse, mouseAction: maMove,
             button: 0, mouseX: x, mouseY: y,
             mouseModifiers: Modifiers())

# ---------------------------------------------------------------------------
# GPUI
# ---------------------------------------------------------------------------

import isonim_gpui/renderer as gpui_renderer
import isonim_gpui/bindings as gpui_bindings
import isonim_render_serve/adapters/gpui_adapter as gpui_adapter
import isonim_render_serve/adapters/gpui_input_adapter

suite "FUH-M2: GPUI per-backend hover dispatch":

  test "maMove fires mouseenter/mouseleave with hit-test throttle":
    gpui_bindings.gpui_reset_tree()
    let r = GpuiRenderer()
    let root = r.createElement("div")
    r.setAttribute(root, ComponentPathAttr, "demo/Root")
    r.setAttribute(root, ElementKindAttr, "app-shell")
    let row0 = r.createElement("li")
    r.setAttribute(row0, ComponentPathAttr, "demo/Row#0")
    r.setAttribute(row0, ElementKindAttr, "row")
    r.appendChild(root, row0)
    let row1 = r.createElement("li")
    r.setAttribute(row1, ComponentPathAttr, "demo/Row#1")
    r.setAttribute(row1, ElementKindAttr, "row")
    r.appendChild(root, row1)

    var row0Enters, row0Leaves, row1Enters, row1Leaves = 0
    r.addEventListener(row0, "mouseenter", proc() = inc row0Enters)
    r.addEventListener(row0, "mouseleave", proc() = inc row0Leaves)
    r.addEventListener(row1, "mouseenter", proc() = inc row1Enters)
    r.addEventListener(row1, "mouseleave", proc() = inc row1Leaves)

    let capturedRoot = root
    let hitChain = proc(x, y: int): seq[GpuiElement] {.gcsafe.} =
      {.cast(gcsafe).}:
        gpui_adapter.hitTestPath(capturedRoot, TreeW, TreeH, x, y)
    let hitTester = proc(x, y: int): GpuiElement {.gcsafe.} =
      {.cast(gcsafe).}: capturedRoot
    let sink = newGpuiInputSink(hitTester, hitChain)

    # Step 1: enter row 0. Chain = [row0, root]. mouseenter fires on
    # both (deepest-first walk-up).
    sink.submit(makeMove(XInsideRow0, YInsideRow0))
    check row0Enters == 1
    check row0Leaves == 0
    check row1Enters == 0
    check row1Leaves == 0

    # Step 2: move within row 0 to a different coord but same leaf.
    # No new fires (hit-test throttle).
    sink.submit(makeMove(XInsideRow0, YInsideRow0Alt))
    check row0Enters == 1
    check row0Leaves == 0

    # Step 3: cross into row 1. mouseleave fires on prior chain,
    # mouseenter on new chain.
    sink.submit(makeMove(XInsideRow1, YInsideRow1))
    check row0Enters == 1
    check row0Leaves == 1
    check row1Enters == 1
    check row1Leaves == 0

    # Step 4: leave the tree entirely. mouseleave fires on prior
    # chain; no new mouseenter (chain is empty).
    sink.submit(makeMove(XOutside, YOutside))
    check row1Leaves == 1
    check row0Enters == 1
    check row1Enters == 1

    # Throttle log: exactly two hover-enter entries (steps 1 and 3)
    # and two hover-leave entries (steps 3 and 4); the within-leaf
    # move in step 2 records the mouseMove log line but no
    # hover-enter / hover-leave entry.
    var enterCount, leaveCount = 0
    for line in sink.log:
      if line.startsWith("hover-enter"): inc enterCount
      elif line.startsWith("hover-leave"): inc leaveCount
    check enterCount == 2
    check leaveCount == 2

# ---------------------------------------------------------------------------
# Freya
# ---------------------------------------------------------------------------

import isonim_freya/renderer as freya_renderer
import isonim_freya/bindings as freya_bindings
import isonim_render_serve/adapters/freya_adapter as freya_adapter
import isonim_render_serve/adapters/freya_input_adapter

suite "FUH-M2: Freya per-backend hover dispatch":

  test "maMove fires mouseenter/mouseleave with hit-test throttle":
    freya_bindings.freya_reset_tree()
    let r = FreyaRenderer()
    let root = r.createElement("div")
    r.setAttribute(root, ComponentPathAttr, "demo/Root")
    r.setAttribute(root, ElementKindAttr, "app-shell")
    let row0 = r.createElement("li")
    r.setAttribute(row0, ComponentPathAttr, "demo/Row#0")
    r.setAttribute(row0, ElementKindAttr, "row")
    r.appendChild(root, row0)
    let row1 = r.createElement("li")
    r.setAttribute(row1, ComponentPathAttr, "demo/Row#1")
    r.setAttribute(row1, ElementKindAttr, "row")
    r.appendChild(root, row1)

    var row0Enters, row0Leaves, row1Enters, row1Leaves = 0
    r.addEventListener(row0, "mouseenter", proc() = inc row0Enters)
    r.addEventListener(row0, "mouseleave", proc() = inc row0Leaves)
    r.addEventListener(row1, "mouseenter", proc() = inc row1Enters)
    r.addEventListener(row1, "mouseleave", proc() = inc row1Leaves)

    let capturedRoot = root
    let hitChain = proc(x, y: int): seq[FreyaElement] {.gcsafe.} =
      {.cast(gcsafe).}:
        freya_adapter.hitTestPath(capturedRoot, TreeW, TreeH, x, y)
    let hitTester = proc(x, y: int): FreyaElement {.gcsafe.} =
      {.cast(gcsafe).}: capturedRoot
    let sink = newFreyaInputSink(hitTester, hitChain)

    sink.submit(makeMove(XInsideRow0, YInsideRow0))
    check row0Enters == 1
    check row0Leaves == 0
    check row1Enters == 0
    check row1Leaves == 0

    sink.submit(makeMove(XInsideRow0, YInsideRow0Alt))
    check row0Enters == 1
    check row0Leaves == 0

    sink.submit(makeMove(XInsideRow1, YInsideRow1))
    check row0Enters == 1
    check row0Leaves == 1
    check row1Enters == 1
    check row1Leaves == 0

    sink.submit(makeMove(XOutside, YOutside))
    check row1Leaves == 1
    check row0Enters == 1
    check row1Enters == 1

    var enterCount, leaveCount = 0
    for line in sink.log:
      if line.startsWith("hover-enter"): inc enterCount
      elif line.startsWith("hover-leave"): inc leaveCount
    check enterCount == 2
    check leaveCount == 2

# ---------------------------------------------------------------------------
# Cocoa (Linux-portable headless side-tables; fireEvent gated macosx)
# ---------------------------------------------------------------------------

import isonim_cocoa/renderer as cocoa_renderer
import isonim_render_serve/adapters/cocoa_adapter as cocoa_adapter
import isonim_render_serve/adapters/cocoa_input_adapter

suite "FUH-M2: Cocoa per-backend hover dispatch":

  test "maMove updates throttle state + logs hover transitions":
    cocoa_renderer.resetTree()
    let r = CocoaRenderer()
    let root = r.createElement("div")
    r.setAttribute(root, ComponentPathAttr, "demo/Root")
    r.setAttribute(root, ElementKindAttr, "app-shell")
    let row0 = r.createElement("li")
    r.setAttribute(row0, ComponentPathAttr, "demo/Row#0")
    r.setAttribute(row0, ElementKindAttr, "row")
    r.appendChild(root, row0)
    let row1 = r.createElement("li")
    r.setAttribute(row1, ComponentPathAttr, "demo/Row#1")
    r.setAttribute(row1, ElementKindAttr, "row")
    r.appendChild(root, row1)

    var row0Enters, row0Leaves, row1Enters, row1Leaves = 0
    r.addEventListener(row0, "mouseenter", proc() = inc row0Enters)
    r.addEventListener(row0, "mouseleave", proc() = inc row0Leaves)
    r.addEventListener(row1, "mouseenter", proc() = inc row1Enters)
    r.addEventListener(row1, "mouseleave", proc() = inc row1Leaves)

    let capturedRoot = root
    let capturedRenderer = r
    let hitChain = proc(x, y: int): seq[CocoaElement] {.gcsafe.} =
      {.cast(gcsafe).}:
        cocoa_adapter.hitTestPath(capturedRenderer, capturedRoot,
                                  TreeW, TreeH, x, y)
    let hitTester = proc(x, y: int): CocoaElement {.gcsafe.} =
      {.cast(gcsafe).}: capturedRoot
    let sink = newCocoaInputSink(r, hitTester, hitChain)

    sink.submit(makeMove(XInsideRow0, YInsideRow0))
    sink.submit(makeMove(XInsideRow0, YInsideRow0Alt))
    sink.submit(makeMove(XInsideRow1, YInsideRow1))
    sink.submit(makeMove(XOutside, YOutside))

    # Throttle assertion: regardless of host, the sink's structured
    # log records exactly two enter / two leave transitions (the
    # within-leaf move in step 2 produces a plain ``mouse move`` line
    # but no hover-enter / hover-leave entry).
    var enterCount, leaveCount = 0
    for line in sink.log:
      if line.startsWith("hover-enter"): inc enterCount
      elif line.startsWith("hover-leave"): inc leaveCount
    check enterCount == 2
    check leaveCount == 2

    # macOS host: real AppKit dispatch fires the leaf-registered
    # handler. The Linux scaffold doesn't link AppKit so the
    # ``fireEvent`` call is gated out (the FUH-M1 audit § 3.3
    # documents the gate); the handler-counter check tightens only
    # on macOS.
    when defined(macosx):
      check row0Enters == 1
      check row0Leaves == 1
      check row1Enters == 1
      check row1Leaves == 1

# ---------------------------------------------------------------------------
# Android (mockJni only — the Android renderer's jni_callbacks
# hard-errors without either ``-d:mockJni`` or ``-d:commandBuffer``).
# ---------------------------------------------------------------------------

when defined(mockJni):
  import isonim_android/renderer as android_renderer
  import isonim_render_serve/adapters/android_adapter as android_adapter
  import isonim_render_serve/adapters/android_input_adapter

  suite "FUH-M2: Android per-backend hover dispatch (mockJni)":

    test "maMove fires mouseenter/mouseleave with hit-test throttle":
      android_renderer.resetRenderer()
      let r = AndroidRenderer()
      let root = r.createElement("div")
      r.setAttribute(root, ComponentPathAttr, "demo/Root")
      r.setAttribute(root, ElementKindAttr, "app-shell")
      let row0 = r.createElement("li")
      r.setAttribute(row0, ComponentPathAttr, "demo/Row#0")
      r.setAttribute(row0, ElementKindAttr, "row")
      r.appendChild(root, row0)
      let row1 = r.createElement("li")
      r.setAttribute(row1, ComponentPathAttr, "demo/Row#1")
      r.setAttribute(row1, ElementKindAttr, "row")
      r.appendChild(root, row1)

      var row0Enters, row0Leaves, row1Enters, row1Leaves = 0
      r.addEventListener(row0, "mouseenter", proc() = inc row0Enters)
      r.addEventListener(row0, "mouseleave", proc() = inc row0Leaves)
      r.addEventListener(row1, "mouseenter", proc() = inc row1Enters)
      r.addEventListener(row1, "mouseleave", proc() = inc row1Leaves)

      let capturedRoot = root
      let capturedRenderer = r
      let hitChain = proc(x, y: int): seq[AndroidElement] {.gcsafe.} =
        {.cast(gcsafe).}:
          android_adapter.hitTestPath(capturedRenderer, capturedRoot,
                                       TreeW, TreeH, x, y)
      let hitTester = proc(x, y: int): AndroidElement {.gcsafe.} =
        {.cast(gcsafe).}: capturedRoot
      let sink = newAndroidInputSink(r, hitTester, hitChain)

      sink.submit(makeMove(XInsideRow0, YInsideRow0))
      check row0Enters == 1
      check row0Leaves == 0
      check row1Enters == 0
      check row1Leaves == 0

      sink.submit(makeMove(XInsideRow0, YInsideRow0Alt))
      check row0Enters == 1
      check row0Leaves == 0

      sink.submit(makeMove(XInsideRow1, YInsideRow1))
      check row0Enters == 1
      check row0Leaves == 1
      check row1Enters == 1
      check row1Leaves == 0

      sink.submit(makeMove(XOutside, YOutside))
      check row1Leaves == 1
      check row0Enters == 1
      check row1Enters == 1

      var enterCount, leaveCount = 0
      for line in sink.log:
        if line.startsWith("hover-enter"): inc enterCount
        elif line.startsWith("hover-leave"): inc leaveCount
      check enterCount == 2
      check leaveCount == 2
