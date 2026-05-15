## RS-M13b: Freya render-tree streaming adapter.
##
## Walks the Freya Nim-side element tree and produces a
## `RenderTreeManifest`. Same shape as the GPUI tree adapter; the
## per-(tag, class, kind) style table differs because Freya's chrome
## targets Material 3 (Roboto, elevation, 12px radius) rather than the
## macOS-native SF stack GPUI mimics.

import std/strutils

import ../packet
import ../element_tree_attrs
import ../bridge

import isonim_freya/renderer

const RendererId* = "freya"

# ---------------------------------------------------------------------------
# Material-styled style derivation tables.
# ---------------------------------------------------------------------------

proc freyaBaseStyle(): RenderTreeStyle =
  result = newRenderTreeStyle()
  result.add("font-family",
    "Roboto, \"Helvetica Neue\", Arial, system-ui, sans-serif")
  result.add("box-sizing", "border-box")

proc freyaStyleFor(tag, class, kind: string): RenderTreeStyle =
  ## Synthesise inline style for one node. Material 3 vocabulary:
  ## elevation shadows on surfaces, 12px radius on cards, ripple-like
  ## tints on interactive elements. The companion CSS bundle
  ## (``isonim/src/isonim/editor/render_styles/freya.css``) layers
  ## hover/focus affordances on top of these.
  result = freyaBaseStyle()
  case kind
  of "app-shell":
    result.add("display", "flex")
    result.add("flex-direction", "column")
    result.add("padding", "16px")
    result.add("background-color", "#1a1c1e")
    result.add("color", "#e2e2e6")
    result.add("border-radius", "12px")
    result.add("box-shadow",
      "0 1px 2px rgba(0,0,0,0.3), 0 1px 3px 1px rgba(0,0,0,0.15)")
  of "input":
    result.add("display", "flex")
    result.add("gap", "8px")
    result.add("padding", "12px 0")
  of "filter-bar":
    result.add("display", "flex")
    result.add("gap", "8px")
    result.add("padding", "8px 0")
  of "row":
    result.add("display", "flex")
    result.add("align-items", "center")
    result.add("gap", "8px")
    result.add("padding", "12px 16px")
    result.add("border-radius", "12px")
    result.add("background-color", "#22252a")
    result.add("margin-bottom", "4px")
  of "list":
    result.add("display", "flex")
    result.add("flex-direction", "column")
    result.add("list-style", "none")
    result.add("padding", "0")
    result.add("margin", "0")
    result.add("gap", "4px")
  of "summary":
    result.add("padding", "8px 16px")
    result.add("font-size", "12px")
    result.add("color", "#c4c7c5")
    result.add("letter-spacing", "0.4px")
  of "vector-symbol":
    result.add("display", "inline-block")
    result.add("width", "18px")
    result.add("height", "18px")
    result.add("color", "#a8c7fa")
  else:
    case tag
    of "button":
      result.add("padding", "10px 16px")
      result.add("border-radius", "20px")
      result.add("border", "none")
      result.add("background-color", "#a8c7fa")
      result.add("color", "#0a2b66")
      result.add("font-weight", "500")
      result.add("text-transform", "none")
      result.add("box-shadow",
        "0 1px 2px rgba(0,0,0,0.3), 0 1px 3px 1px rgba(0,0,0,0.15)")
    of "input":
      result.add("padding", "12px 16px")
      result.add("border-radius", "4px")
      result.add("border", "1px solid #5e636b")
      result.add("background-color", "#22252a")
      result.add("color", "#e2e2e6")
    of "p":
      result.add("color", "#c4c7c5")
      result.add("font-size", "14px")
    of "span", "label", "paragraph":
      result.add("color", "#e2e2e6")
    of "footer":
      result.add("color", "#8e918f")
      result.add("font-size", "12px")
    of "rect":
      result.add("display", "block")
      result.add("background-color", "#22252a")
      result.add("border-radius", "8px")
    else:
      result.add("color", "#e2e2e6")
  if class.contains("completed"):
    result.add("opacity", "0.6")
    result.add("text-decoration", "line-through")
  if class.contains("selected"):
    result.add("background-color", "#7da0d7")
    result.add("color", "#001b3f")

# ---------------------------------------------------------------------------
# Tree walker
# ---------------------------------------------------------------------------

proc walkFreya(node: FreyaElement; x, y, w, h: int;
               depth: int; maxDepth: int): RenderTreeNode =
  let tag = getTag(node)
  let txt = textContent(node)
  let class = getAttribute(node, "class")
  let kind = getAttribute(node, ElementKindAttr)
  let path = getAttribute(node, ComponentPathAttr)
  let id = if path.len > 0: path else: tag & "#" & $depth
  result = RenderTreeNode(
    id: id, tag: tag, text: txt, componentPath: path,
    style: freyaStyleFor(tag, class, kind),
    bounds: ElementBounds(x: x, y: y, w: w, h: h),
    children: @[])
  if depth >= maxDepth: return
  let count = childCount(node)
  if count == 0: return
  let headerBand = min(12, max(0, h div 4))
  let bodyY = y + headerBand
  let bodyH = h - headerBand
  if bodyH <= 0: return
  let perChild = max(1, bodyH div count)
  var cy = bodyY
  for i in 0 ..< count:
    let child = nthChild(node, i)
    if child == nil: continue
    let ch =
      if i == count - 1: bodyY + bodyH - cy
      else: perChild
    result.children.add walkFreya(
      child, x + 4, cy, w - 8, ch, depth + 1, maxDepth)
    cy += ch

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

proc buildFreyaRenderTreeManifest*(root: FreyaElement;
                                    width, height: int;
                                    frameSeq: int = 0):
                                   RenderTreeManifest =
  if root == nil or width <= 0 or height <= 0:
    return RenderTreeManifest(
      frameSeq: frameSeq, rendererId: RendererId,
      root: RenderTreeNode(id: "empty", tag: "div", text: "",
                           componentPath: "",
                           style: newRenderTreeStyle(),
                           bounds: ElementBounds(),
                           children: @[]))
  result = RenderTreeManifest(
    frameSeq: frameSeq, rendererId: RendererId,
    root: walkFreya(root, 0, 0, width, height, 0, 8))

type
  FreyaRenderTreeProviderState* = ref object
    root*: FreyaElement
    width*, height*: int
    frameSeq*: int

proc newFreyaRenderTreeProvider*(root: FreyaElement;
                                 width, height: int):
                                RenderTreeProvider =
  let state = FreyaRenderTreeProviderState(
    root: root, width: width, height: height, frameSeq: 0)
  RenderTreeProvider(
    buildImpl: proc(): RenderTreeManifest {.gcsafe.} =
      {.cast(gcsafe).}:
        state.frameSeq.inc
        buildFreyaRenderTreeManifest(
          state.root, state.width, state.height, state.frameSeq))

proc newFreyaRenderTreeProvider*(state: FreyaRenderTreeProviderState):
                                RenderTreeProvider =
  RenderTreeProvider(
    buildImpl: proc(): RenderTreeManifest {.gcsafe.} =
      {.cast(gcsafe).}:
        state.frameSeq.inc
        buildFreyaRenderTreeManifest(
          state.root, state.width, state.height, state.frameSeq))

# ---------------------------------------------------------------------------
# RS-M11b: element-tree manifest builder.
# ---------------------------------------------------------------------------

proc buildFreyaElementTreeManifest*(root: FreyaElement;
                                    width, height: int;
                                    frameSeq: int = 0):
                                   ElementTreeManifest =
  ## Build a fresh element-tree manifest from the current state of the
  ## Freya tree rooted at ``root``. Mirror of ``buildGpuiElementTreeManifest``.
  proc walk(node: FreyaElement; x, y, w, h: int;
            depth: int; maxDepth: int;
            entries: var seq[ElementEntry]) =
    if node == nil or w <= 0 or h <= 0: return
    if depth > maxDepth: return
    let path = getAttribute(node, ComponentPathAttr)
    if path.len > 0:
      let kind = getAttribute(node, ElementKindAttr)
      entries.add ElementEntry(
        id: path, componentPath: path, kind: kind,
        bounds: ElementBounds(x: x, y: y, w: w, h: h))
    let count = childCount(node)
    if count == 0: return
    let headerBand = min(12, max(0, h div 4))
    let bodyY = y + headerBand
    let bodyH = h - headerBand
    if bodyH <= 0: return
    let perChild = max(1, bodyH div count)
    var cy = bodyY
    for i in 0 ..< count:
      let child = nthChild(node, i)
      if child == nil: continue
      let ch =
        if i == count - 1: bodyY + bodyH - cy
        else: perChild
      walk(child, x + 4, cy, w - 8, ch, depth + 1, maxDepth, entries)
      cy += ch

  result = ElementTreeManifest(
    frameSeq: frameSeq, surfaceWidth: width, surfaceHeight: height,
    elements: @[])
  if root == nil or width <= 0 or height <= 0: return
  walk(root, 0, 0, width, height, 0, 8, result.elements)
