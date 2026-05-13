## RS-M11c — direct unit test of the Android adapter's
## ``buildAndroidElementTreeManifest`` entry point against a real
## ``AndroidRenderer`` + a small headless tree built through the actual
## renderer (no mocks).
##
## Mirror of ``test_gpui_adapter_element_tree.nim`` /
## ``test_freya_adapter_element_tree.nim`` against the Android
## renderer's element-tree surface. Compiles only under ``-d:mockJni``
## (host-side shim) because ``isonim_android/renderer`` transitively
## imports ``jni_callbacks``, which hard-errors without either
## ``-d:mockJni`` or ``-d:commandBuffer``.
##
## Build: ``nim c --define:mockJni -r tests/test_android_adapter_element_tree.nim``.

import std/[strutils, unittest]

when defined(mockJni):
  import isonim_android/renderer

  import isonim_render_serve/adapters/android_adapter
  import isonim_render_serve/element_tree_attrs
  import isonim_render_serve/packet

  suite "RS-M11c: buildAndroidElementTreeManifest (direct)":

    test "surface dimensions and frameSeq mirror the call args":
      resetRenderer()
      let r = AndroidRenderer()
      let root = r.createElement("div")
      let manifest = buildAndroidElementTreeManifest(root, 320, 240,
                                                    frameSeq = 7)
      check manifest.surfaceWidth == 320
      check manifest.surfaceHeight == 240
      check manifest.frameSeq == 7

    test "zero (nil) root yields an empty manifest with valid surface":
      let manifest = buildAndroidElementTreeManifest(
        AndroidElement(0), 100, 80, frameSeq = 0)
      check manifest.surfaceWidth == 100
      check manifest.surfaceHeight == 80
      check manifest.elements.len == 0

    test "only annotated nodes surface in the manifest":
      resetRenderer()
      let r = AndroidRenderer()
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

      let manifest = buildAndroidElementTreeManifest(root, 200, 200)
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
      resetRenderer()
      let r = AndroidRenderer()
      let root = r.createElement("div")
      r.setAttribute(root, ComponentPathAttr, "demo/views/HeaderOnly")
      let manifest = buildAndroidElementTreeManifest(root, 64, 64)
      check manifest.elements.len == 1
      check manifest.elements[0].componentPath == "demo/views/HeaderOnly"
      check manifest.elements[0].kind == ""

    test "every entry's bounds fits inside the surface":
      resetRenderer()
      let r = AndroidRenderer()
      let root = r.createElement("div")
      r.setAttribute(root, ComponentPathAttr, "x/Root")
      for i in 0 ..< 5:
        let row = r.createElement("li")
        r.setAttribute(row, ComponentPathAttr,
          "x/Row#" & $i)
        r.setAttribute(row, ElementKindAttr, "row")
        r.appendChild(root, row)
      let manifest = buildAndroidElementTreeManifest(root, 400, 300)
      check manifest.elements.len == 6
      for e in manifest.elements:
        check e.bounds.x >= 0
        check e.bounds.y >= 0
        check e.bounds.x + e.bounds.w <= manifest.surfaceWidth
        check e.bounds.y + e.bounds.h <= manifest.surfaceHeight

    test "row component paths follow the ^x/Row#[0-9]+$ shape":
      resetRenderer()
      let r = AndroidRenderer()
      let root = r.createElement("div")
      r.setAttribute(root, ComponentPathAttr, "x/Root")
      for i in 0 ..< 3:
        let row = r.createElement("li")
        r.setAttribute(row, ComponentPathAttr, "x/Row#" & $i)
        r.appendChild(root, row)
      let manifest = buildAndroidElementTreeManifest(root, 320, 240)
      var rowCount = 0
      for e in manifest.elements:
        if e.componentPath.startsWith("x/Row#"):
          inc rowCount
          let suffix = e.componentPath.substr(len("x/Row#"))
          for ch in suffix:
            check ch in {'0' .. '9'}
      check rowCount == 3

else:
  suite "RS-M11c: Android adapter element tree (mockJni gate)":
    test "compile with -d:mockJni to exercise the manifest builder":
      check true
