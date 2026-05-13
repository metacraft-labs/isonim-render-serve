## RS-M11b — direct unit test of the GPUI adapter's
## ``buildGpuiElementTreeManifest`` entry point against a real
## ``GpuiRenderer`` + a small headless tree built through the actual
## shim cdylib (no mocks).
##
## What this exercises:
##   * ``GpuiRenderer.createElement`` / ``setAttribute`` /
##     ``appendChild`` — the real shim FFI loaded via the dev shell's
##     ``LD_LIBRARY_PATH`` extension.
##   * ``element_tree_attrs.ComponentPathAttr`` /
##     ``ElementKindAttr`` — the shared constants the launcher's
##     leaves write into the tree.
##   * ``gpui_adapter.buildGpuiElementTreeManifest`` — the manifest
##     builder; asserts the filter (only annotated nodes surface),
##     the bounds (geometry inside the configured surface), and the
##     manifest shape (id == componentPath, kind from
##     ``data-component-kind``).

import std/[strutils, unittest]

import isonim_gpui/renderer
import isonim_gpui/bindings

import isonim_render_serve/adapters/gpui_adapter
import isonim_render_serve/element_tree_attrs
import isonim_render_serve/packet

suite "RS-M11b: buildGpuiElementTreeManifest (direct)":

  test "surface dimensions and frameSeq mirror the call args":
    gpui_reset_tree()
    let r = GpuiRenderer()
    let root = r.createElement("div")
    let manifest = buildGpuiElementTreeManifest(root, 320, 240,
                                                frameSeq = 7)
    check manifest.surfaceWidth == 320
    check manifest.surfaceHeight == 240
    check manifest.frameSeq == 7

  test "nil root yields an empty manifest with valid surface":
    let manifest = buildGpuiElementTreeManifest(nil, 100, 80,
                                                frameSeq = 0)
    check manifest.surfaceWidth == 100
    check manifest.surfaceHeight == 80
    check manifest.elements.len == 0

  test "only annotated nodes surface in the manifest":
    gpui_reset_tree()
    let r = GpuiRenderer()
    let root = r.createElement("div")
    r.setAttribute(root, "class", "app")
    r.setAttribute(root, ComponentPathAttr, "demo/views/Root")
    r.setAttribute(root, ElementKindAttr, "app-shell")

    let middle = r.createElement("section")
    # No componentPath on this one — must NOT surface in the manifest.
    r.setAttribute(middle, "class", "middle")
    r.appendChild(root, middle)

    let leaf = r.createElement("li")
    r.setAttribute(leaf, ComponentPathAttr, "demo/views/Row#42")
    r.setAttribute(leaf, ElementKindAttr, "row")
    r.appendChild(middle, leaf)

    let unannotatedLeaf = r.createElement("p")
    r.setAttribute(unannotatedLeaf, "class", "blurb")
    r.appendChild(middle, unannotatedLeaf)

    let manifest = buildGpuiElementTreeManifest(root, 200, 200)
    check manifest.elements.len == 2

    var sawRoot = false
    var sawLeaf = false
    for e in manifest.elements:
      case e.componentPath
      of "demo/views/Root":
        sawRoot = true
        check e.id == "demo/views/Root"
        check e.kind == "app-shell"
        check e.bounds.x == 0
        check e.bounds.y == 0
        check e.bounds.w == 200
        check e.bounds.h == 200
      of "demo/views/Row#42":
        sawLeaf = true
        check e.id == "demo/views/Row#42"
        check e.kind == "row"
        # Leaf has its own non-zero bounds, fully inside the surface.
        check e.bounds.w > 0
        check e.bounds.h > 0
        check e.bounds.x >= 0
        check e.bounds.y >= 0
        check e.bounds.x + e.bounds.w <= 200
        check e.bounds.y + e.bounds.h <= 200
      else:
        check false
    check sawRoot
    check sawLeaf

  test "missing data-component-kind yields empty kind, not omitted entry":
    gpui_reset_tree()
    let r = GpuiRenderer()
    let root = r.createElement("div")
    r.setAttribute(root, ComponentPathAttr, "demo/views/HeaderOnly")
    # Deliberately NO ``data-component-kind``.
    let manifest = buildGpuiElementTreeManifest(root, 64, 64)
    check manifest.elements.len == 1
    check manifest.elements[0].componentPath == "demo/views/HeaderOnly"
    check manifest.elements[0].kind == ""

  test "every entry's bounds fits inside the surface":
    gpui_reset_tree()
    let r = GpuiRenderer()
    let root = r.createElement("div")
    r.setAttribute(root, ComponentPathAttr, "x/Root")
    # Build a small subtree with mixed annotations to mirror demo shape.
    for i in 0 ..< 5:
      let row = r.createElement("li")
      r.setAttribute(row, ComponentPathAttr,
        "x/Row#" & $i)
      r.setAttribute(row, ElementKindAttr, "row")
      r.appendChild(root, row)
    let manifest = buildGpuiElementTreeManifest(root, 400, 300)
    check manifest.elements.len == 6  # root + 5 rows
    for e in manifest.elements:
      check e.bounds.x >= 0
      check e.bounds.y >= 0
      check e.bounds.x + e.bounds.w <= manifest.surfaceWidth
      check e.bounds.y + e.bounds.h <= manifest.surfaceHeight

  test "row component paths follow the ^x/Row#[0-9]+$ shape":
    gpui_reset_tree()
    let r = GpuiRenderer()
    let root = r.createElement("div")
    r.setAttribute(root, ComponentPathAttr, "x/Root")
    for i in 0 ..< 3:
      let row = r.createElement("li")
      r.setAttribute(row, ComponentPathAttr, "x/Row#" & $i)
      r.appendChild(root, row)
    let manifest = buildGpuiElementTreeManifest(root, 320, 240)
    var rowCount = 0
    for e in manifest.elements:
      if e.componentPath.startsWith("x/Row#"):
        inc rowCount
        let suffix = e.componentPath.substr(len("x/Row#"))
        # Suffix must be all digits.
        for ch in suffix:
          check ch in {'0' .. '9'}
    check rowCount == 3
