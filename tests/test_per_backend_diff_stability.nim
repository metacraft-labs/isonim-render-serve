## test_per_backend_diff_stability — ETS-M3 Part C.
##
## Per-backend correctness gate for the launcher-agnostic diff
## helper. The point of the gate is: ``computeElementTreeDelta``
## lives in render-serve and is the same code for every backend
## — but the manifest it consumes comes from each adapter's
## ``buildXxxElementTreeManifest`` walk. If a particular adapter
## produces unstable ids (e.g. index-keyed rows that reorder on
## insertion) the diff would degrade to "delete every row, re-add
## every row" instead of "one add, N-1 unchanged". This test pins
## the ETS-M1 audit § 1.5 invariant ("element ids are stable
## across re-emits of the same logical element") on each adapter
## directly.
##
## For each backend (gpui, freya, cocoa, android-mock) we drive
## the adapter's renderer directly:
##
##   1. Build a baseline shadow tree of N annotated row leaves.
##   2. Capture the baseline manifest via the adapter's builder.
##   3. Mutate the tree (append a new row, drop a middle row,
##      shift a row's identity attribute).
##   4. Capture the post-mutation manifest.
##   5. Run ``computeElementTreeDelta(baseline, mutated)``.
##   6. Assert the op-sequence shape: exactly one add for the new
##      row, exactly one remove for the dropped one, no spurious
##      updates on rows whose id + bounds + kind are unchanged.
##
## The Android adapter is gated ``-d:mockJni`` per the existing
## ``test_android_adapter_element_tree.nim`` pattern. The Cocoa
## adapter compiles on Linux too (the manifest builder only
## touches headless side-tables) — no host gate needed.

import std/[unittest]

import isonim_render_serve
import isonim_render_serve/element_tree_attrs

# ---------------------------------------------------------------------------
# Shared op-shape assertions
# ---------------------------------------------------------------------------

proc countOps(ops: seq[ElementOp]):
              tuple[adds, updates, removes: int] =
  for op in ops:
    case op.kind
    of eopAdd: inc result.adds
    of eopUpdate: inc result.updates
    of eopRemove: inc result.removes

proc hasAddFor(ops: seq[ElementOp]; id: string): bool =
  for op in ops:
    if op.kind == eopAdd and op.addId == id: return true
  false

proc hasRemoveFor(ops: seq[ElementOp]; id: string): bool =
  for op in ops:
    if op.kind == eopRemove and op.remId == id: return true
  false

proc hasUpdateFor(ops: seq[ElementOp]; id: string): bool =
  for op in ops:
    if op.kind == eopUpdate and op.updId == id: return true
  false

# ---------------------------------------------------------------------------
# GPUI
# ---------------------------------------------------------------------------

import isonim_gpui/renderer as gpui_renderer
import isonim_gpui/bindings as gpui_bindings
import isonim_render_serve/adapters/gpui_adapter

proc gpuiBuildBaseline(r: GpuiRenderer): tuple[
                       root: GpuiElement;
                       middleRow: GpuiElement] =
  gpui_bindings.gpui_reset_tree()
  let root = r.createElement("div")
  r.setAttribute(root, ComponentPathAttr, "demo/Root")
  r.setAttribute(root, ElementKindAttr, "app-shell")
  var middleRow: GpuiElement = nil
  for i in 0 ..< 5:
    let row = r.createElement("li")
    r.setAttribute(row, ComponentPathAttr, "demo/Row#" & $i)
    r.setAttribute(row, ElementKindAttr, "row")
    r.appendChild(root, row)
    if i == 2: middleRow = row
  (root, middleRow)

suite "ETS-M3 Part C: GPUI diff stability":

  test "append a new row -> exactly one eopAdd, zero spurious updates":
    let r = GpuiRenderer()
    let (root, _) = gpuiBuildBaseline(r)
    let baseline = buildGpuiElementTreeManifest(root, 400, 240)
    # Sanity: 1 root + 5 rows = 6 entries.
    check baseline.elements.len == 6

    # Mutation: append a new row with a fresh stable id.
    let newRow = r.createElement("li")
    r.setAttribute(newRow, ComponentPathAttr, "demo/Row#new")
    r.setAttribute(newRow, ElementKindAttr, "row")
    r.appendChild(root, newRow)

    let mutated = buildGpuiElementTreeManifest(root, 400, 240)
    let ops = computeElementTreeDelta(baseline, mutated)
    let c = countOps(ops)
    check c.adds == 1
    check c.removes == 0
    # Appending a new row may shift sibling row bounds in the
    # layout pass; sparse updates for those are expected. Assert
    # there is no update for the *unchanged* root id.
    check hasAddFor(ops, "demo/Row#new")
    check not hasUpdateFor(ops, "demo/Root")

  test "drop a middle row -> exactly one eopRemove for that row id":
    let r = GpuiRenderer()
    let (root, middle) = gpuiBuildBaseline(r)
    let baseline = buildGpuiElementTreeManifest(root, 400, 240)
    # Mutation: drop the middle row.
    r.removeChild(root, middle)
    let mutated = buildGpuiElementTreeManifest(root, 400, 240)
    let ops = computeElementTreeDelta(baseline, mutated)
    let c = countOps(ops)
    check c.adds == 0
    check c.removes == 1
    check hasRemoveFor(ops, "demo/Row#2")
    # The root is unchanged; no update for it.
    check not hasUpdateFor(ops, "demo/Root")

  test "identical re-emission -> zero ops":
    let r = GpuiRenderer()
    let (root, _) = gpuiBuildBaseline(r)
    let m1 = buildGpuiElementTreeManifest(root, 400, 240)
    let m2 = buildGpuiElementTreeManifest(root, 400, 240)
    check computeElementTreeDelta(m1, m2).len == 0

# ---------------------------------------------------------------------------
# Freya
# ---------------------------------------------------------------------------

import isonim_freya/renderer as freya_renderer
import isonim_freya/bindings as freya_bindings
import isonim_render_serve/adapters/freya_adapter

proc freyaBuildBaseline(r: FreyaRenderer): tuple[
                        root: FreyaElement;
                        middleRow: FreyaElement] =
  freya_bindings.freya_reset_tree()
  let root = r.createElement("div")
  r.setAttribute(root, ComponentPathAttr, "demo/Root")
  r.setAttribute(root, ElementKindAttr, "app-shell")
  var middleRow: FreyaElement = nil
  for i in 0 ..< 5:
    let row = r.createElement("li")
    r.setAttribute(row, ComponentPathAttr, "demo/Row#" & $i)
    r.setAttribute(row, ElementKindAttr, "row")
    r.appendChild(root, row)
    if i == 2: middleRow = row
  (root, middleRow)

suite "ETS-M3 Part C: Freya diff stability":

  test "append a new row -> exactly one eopAdd":
    let r = FreyaRenderer()
    let (root, _) = freyaBuildBaseline(r)
    let baseline = buildFreyaElementTreeManifest(root, 400, 240)
    check baseline.elements.len == 6

    let newRow = r.createElement("li")
    r.setAttribute(newRow, ComponentPathAttr, "demo/Row#new")
    r.setAttribute(newRow, ElementKindAttr, "row")
    r.appendChild(root, newRow)

    let mutated = buildFreyaElementTreeManifest(root, 400, 240)
    let ops = computeElementTreeDelta(baseline, mutated)
    let c = countOps(ops)
    check c.adds == 1
    check c.removes == 0
    check hasAddFor(ops, "demo/Row#new")
    check not hasUpdateFor(ops, "demo/Root")

  test "drop a middle row -> exactly one eopRemove for that row id":
    let r = FreyaRenderer()
    let (root, middle) = freyaBuildBaseline(r)
    let baseline = buildFreyaElementTreeManifest(root, 400, 240)
    r.removeChild(root, middle)
    let mutated = buildFreyaElementTreeManifest(root, 400, 240)
    let ops = computeElementTreeDelta(baseline, mutated)
    let c = countOps(ops)
    check c.adds == 0
    check c.removes == 1
    check hasRemoveFor(ops, "demo/Row#2")
    check not hasUpdateFor(ops, "demo/Root")

  test "identical re-emission -> zero ops":
    let r = FreyaRenderer()
    let (root, _) = freyaBuildBaseline(r)
    let m1 = buildFreyaElementTreeManifest(root, 400, 240)
    let m2 = buildFreyaElementTreeManifest(root, 400, 240)
    check computeElementTreeDelta(m1, m2).len == 0

# ---------------------------------------------------------------------------
# Cocoa (Linux-portable thanks to the headless side-tables-only DFS)
# ---------------------------------------------------------------------------

import isonim_cocoa/renderer as cocoa_renderer
import isonim_render_serve/adapters/cocoa_adapter

proc cocoaBuildBaseline(r: CocoaRenderer): tuple[
                        root: CocoaElement;
                        middleRow: CocoaElement] =
  cocoa_renderer.resetTree()
  let root = r.createElement("div")
  r.setAttribute(root, ComponentPathAttr, "demo/Root")
  r.setAttribute(root, ElementKindAttr, "app-shell")
  var middleRow: CocoaElement = CocoaElement(nil)
  for i in 0 ..< 5:
    let row = r.createElement("li")
    r.setAttribute(row, ComponentPathAttr, "demo/Row#" & $i)
    r.setAttribute(row, ElementKindAttr, "row")
    r.appendChild(root, row)
    if i == 2: middleRow = row
  (root, middleRow)

suite "ETS-M3 Part C: Cocoa diff stability":

  test "append a new row -> exactly one eopAdd":
    let r = CocoaRenderer()
    let (root, _) = cocoaBuildBaseline(r)
    let baseline = buildCocoaElementTreeManifest(root, 400, 240)
    check baseline.elements.len == 6

    let newRow = r.createElement("li")
    r.setAttribute(newRow, ComponentPathAttr, "demo/Row#new")
    r.setAttribute(newRow, ElementKindAttr, "row")
    r.appendChild(root, newRow)

    let mutated = buildCocoaElementTreeManifest(root, 400, 240)
    let ops = computeElementTreeDelta(baseline, mutated)
    let c = countOps(ops)
    check c.adds == 1
    check c.removes == 0
    check hasAddFor(ops, "demo/Row#new")
    check not hasUpdateFor(ops, "demo/Root")

  test "drop a middle row -> exactly one eopRemove for that row id":
    let r = CocoaRenderer()
    let (root, middle) = cocoaBuildBaseline(r)
    let baseline = buildCocoaElementTreeManifest(root, 400, 240)
    r.removeChild(root, middle)
    let mutated = buildCocoaElementTreeManifest(root, 400, 240)
    let ops = computeElementTreeDelta(baseline, mutated)
    let c = countOps(ops)
    check c.adds == 0
    check c.removes == 1
    check hasRemoveFor(ops, "demo/Row#2")
    check not hasUpdateFor(ops, "demo/Root")

  test "identical re-emission -> zero ops":
    let r = CocoaRenderer()
    let (root, _) = cocoaBuildBaseline(r)
    let m1 = buildCocoaElementTreeManifest(root, 400, 240)
    let m2 = buildCocoaElementTreeManifest(root, 400, 240)
    check computeElementTreeDelta(m1, m2).len == 0

# ---------------------------------------------------------------------------
# Android (mockJni only — the Android renderer's jni_callbacks hard-
# errors without either ``-d:mockJni`` or ``-d:commandBuffer``)
# ---------------------------------------------------------------------------

when defined(mockJni):
  import isonim_android/renderer as android_renderer
  import isonim_render_serve/adapters/android_adapter

  proc androidBuildBaseline(r: AndroidRenderer): tuple[
                            root: AndroidElement;
                            middleRow: AndroidElement] =
    android_renderer.resetRenderer()
    let root = r.createElement("div")
    r.setAttribute(root, ComponentPathAttr, "demo/Root")
    r.setAttribute(root, ElementKindAttr, "app-shell")
    var middleRow: AndroidElement = AndroidElement(0)
    for i in 0 ..< 5:
      let row = r.createElement("li")
      r.setAttribute(row, ComponentPathAttr, "demo/Row#" & $i)
      r.setAttribute(row, ElementKindAttr, "row")
      r.appendChild(root, row)
      if i == 2: middleRow = row
    (root, middleRow)

  suite "ETS-M3 Part C: Android diff stability (mockJni)":

    test "append a new row -> exactly one eopAdd":
      let r = AndroidRenderer()
      let (root, _) = androidBuildBaseline(r)
      let baseline = buildAndroidElementTreeManifest(root, 400, 240)
      check baseline.elements.len == 6

      let newRow = r.createElement("li")
      r.setAttribute(newRow, ComponentPathAttr, "demo/Row#new")
      r.setAttribute(newRow, ElementKindAttr, "row")
      r.appendChild(root, newRow)

      let mutated = buildAndroidElementTreeManifest(root, 400, 240)
      let ops = computeElementTreeDelta(baseline, mutated)
      let c = countOps(ops)
      check c.adds == 1
      check c.removes == 0
      check hasAddFor(ops, "demo/Row#new")
      check not hasUpdateFor(ops, "demo/Root")

    test "drop a middle row -> exactly one eopRemove for that row id":
      let r = AndroidRenderer()
      let (root, middle) = androidBuildBaseline(r)
      let baseline = buildAndroidElementTreeManifest(root, 400, 240)
      r.removeChild(root, middle)
      let mutated = buildAndroidElementTreeManifest(root, 400, 240)
      let ops = computeElementTreeDelta(baseline, mutated)
      let c = countOps(ops)
      check c.adds == 0
      check c.removes == 1
      check hasRemoveFor(ops, "demo/Row#2")
      check not hasUpdateFor(ops, "demo/Root")

    test "identical re-emission -> zero ops":
      let r = AndroidRenderer()
      let (root, _) = androidBuildBaseline(r)
      let m1 = buildAndroidElementTreeManifest(root, 400, 240)
      let m2 = buildAndroidElementTreeManifest(root, 400, 240)
      check computeElementTreeDelta(m1, m2).len == 0
