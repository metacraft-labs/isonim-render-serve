## RS-M11b — direct unit test of the Freya adapter's
## ``buildFreyaElementTreeManifest`` entry point against a real
## ``FreyaRenderer`` + a small headless tree built through the actual
## shim cdylib (no mocks).
##
## Mirror of ``test_gpui_adapter_element_tree.nim`` against the Freya
## renderer's element-tree surface.

import std/[strutils, unittest]

import isonim_freya/renderer
import isonim_freya/bindings

import isonim_render_serve/adapters/freya_adapter
import isonim_render_serve/element_tree_attrs
import isonim_render_serve/packet

suite "RS-M11b: buildFreyaElementTreeManifest (direct)":

  test "surface dimensions and frameSeq mirror the call args":
    freya_reset_tree()
    let r = FreyaRenderer()
    let root = r.createElement("div")
    let manifest = buildFreyaElementTreeManifest(root, 320, 240,
                                                 frameSeq = 7)
    check manifest.surfaceWidth == 320
    check manifest.surfaceHeight == 240
    check manifest.frameSeq == 7

  test "nil root yields an empty manifest with valid surface":
    let manifest = buildFreyaElementTreeManifest(nil, 100, 80,
                                                 frameSeq = 0)
    check manifest.surfaceWidth == 100
    check manifest.surfaceHeight == 80
    check manifest.elements.len == 0

  test "only annotated nodes surface in the manifest":
    freya_reset_tree()
    let r = FreyaRenderer()
    let root = r.createElement("div")
    r.setAttribute(root, "class", "app")
    r.setAttribute(root, ComponentPathAttr, "demo/views/Root")
    r.setAttribute(root, ElementKindAttr, "app-shell")

    let middle = r.createElement("section")
    r.setAttribute(middle, "class", "middle")
    r.appendChild(root, middle)

    let leaf = r.createElement("li")
    r.setAttribute(leaf, ComponentPathAttr, "demo/views/Row#42")
    r.setAttribute(leaf, ElementKindAttr, "row")
    r.appendChild(middle, leaf)

    let unannotatedLeaf = r.createElement("p")
    r.setAttribute(unannotatedLeaf, "class", "blurb")
    r.appendChild(middle, unannotatedLeaf)

    let manifest = buildFreyaElementTreeManifest(root, 200, 200)
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
    freya_reset_tree()
    let r = FreyaRenderer()
    let root = r.createElement("div")
    r.setAttribute(root, ComponentPathAttr, "demo/views/HeaderOnly")
    let manifest = buildFreyaElementTreeManifest(root, 64, 64)
    check manifest.elements.len == 1
    check manifest.elements[0].componentPath == "demo/views/HeaderOnly"
    check manifest.elements[0].kind == ""

  test "every entry's bounds fits inside the surface":
    freya_reset_tree()
    let r = FreyaRenderer()
    let root = r.createElement("div")
    r.setAttribute(root, ComponentPathAttr, "x/Root")
    for i in 0 ..< 5:
      let row = r.createElement("li")
      r.setAttribute(row, ComponentPathAttr,
        "x/Row#" & $i)
      r.setAttribute(row, ElementKindAttr, "row")
      r.appendChild(root, row)
    let manifest = buildFreyaElementTreeManifest(root, 400, 300)
    check manifest.elements.len == 6
    for e in manifest.elements:
      check e.bounds.x >= 0
      check e.bounds.y >= 0
      check e.bounds.x + e.bounds.w <= manifest.surfaceWidth
      check e.bounds.y + e.bounds.h <= manifest.surfaceHeight

  test "row component paths follow the ^x/Row#[0-9]+$ shape":
    freya_reset_tree()
    let r = FreyaRenderer()
    let root = r.createElement("div")
    r.setAttribute(root, ComponentPathAttr, "x/Root")
    for i in 0 ..< 3:
      let row = r.createElement("li")
      r.setAttribute(row, ComponentPathAttr, "x/Row#" & $i)
      r.appendChild(root, row)
    let manifest = buildFreyaElementTreeManifest(root, 320, 240)
    var rowCount = 0
    for e in manifest.elements:
      if e.componentPath.startsWith("x/Row#"):
        inc rowCount
        let suffix = e.componentPath.substr(len("x/Row#"))
        for ch in suffix:
          check ch in {'0' .. '9'}
    check rowCount == 3

  test "horizontal layout honors explicit padding and gaps":
    freya_reset_tree()
    let r = FreyaRenderer()
    let row = r.createElement("li")
    r.setAttribute(row, "data-layout", "horizontal")
    r.setAttribute(row, "data-layout-padding", "16")
    r.setAttribute(row, "data-layout-gap", "8")

    let toggle = r.createElement("button")
    r.setAttribute(toggle, "class", "toggle")
    r.setTextContent(toggle, "toggle")
    r.setAttribute(toggle, "data-fixed-width", "20")
    r.appendChild(row, toggle)

    let label = r.createElement("span")
    r.setAttribute(label, "class", "label")
    r.setTextContent(label, "label")
    r.appendChild(row, label)

    let remove = r.createElement("button")
    r.setAttribute(remove, "class", "remove")
    r.setTextContent(remove, "remove")
    r.setAttribute(remove, "data-fixed-width", "20")
    r.appendChild(row, remove)

    let rects = buildLayoutRects(row, 800, 52)
    var toggleRect, labelRect, removeRect: LayoutRect
    var sawToggle, sawLabel, sawRemove = false
    for lr in rects:
      if lr.label == "toggle|toggle":
        toggleRect = lr
        sawToggle = true
      elif lr.label == "label|label":
        labelRect = lr
        sawLabel = true
      elif lr.label == "remove|remove":
        removeRect = lr
        sawRemove = true

    check sawToggle
    check sawLabel
    check sawRemove
    check toggleRect.x == 16
    check toggleRect.w == 20
    check labelRect.x == 44
    check removeRect.x == 764
    check removeRect.w == 20
    check toggleRect.y == 16
    check toggleRect.h == 20
