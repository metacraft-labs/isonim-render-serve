## RS-M13b: GPUI render-tree streaming adapter.
##
## Walks the GPUI Nim-side element tree (the same tree `gpui_adapter.nim`
## used to rasterise into RGBA pixels) and produces a `RenderTreeManifest`
## suitable for emission over the F/M/I bridge's `render-tree` M sub-kind.
##
## Style synthesis: leaves do NOT carry `data-style-*` attributes. They
## carry `class`, `data-component-path` and `data-component-kind`. The
## tree adapter derives a renderer-specific inline-style map from
## ``(tag, class, kind)`` so the editor's CSS bundle (`gpui.css`) can
## decorate the materialised DOM consistently. The style values here
## carry the data the CSS bundle's variables hook into — colour tokens,
## font stack, padding rhythm — and a few presentation-only attributes
## that align the DOM subtree with the renderer's native widget look.

import std/strutils

import ../packet
import ../element_tree_attrs
import ../bridge

import isonim_gpui/renderer

const RendererId* = "gpui"

# ---------------------------------------------------------------------------
# Style derivation tables — pure functions over (tag, class, kind).
# ---------------------------------------------------------------------------

proc gpuiBaseStyle(): RenderTreeStyle =
  ## Styles that apply to every node in a GPUI tree before the per-kind
  ## overrides land on top.
  result = newRenderTreeStyle()
  result.add("font-family",
    "-apple-system, BlinkMacSystemFont, \"SF Pro Display\", " &
    "\"Helvetica Neue\", Helvetica, sans-serif")
  result.add("box-sizing", "border-box")

proc gpuiStyleFor(tag, class, kind: string): RenderTreeStyle =
  ## Synthesise inline style for one node. The CSS bundle
  ## (``isonim/src/isonim/editor/render_styles/gpui.css``) picks up
  ## `data-component-kind`-keyed selectors and adds the bulk of the
  ## decoration; the inline style here covers the bare minimum the
  ## editor's overlay anchoring expects (font stack so the test can
  ## assert it via `getComputedStyle`).
  result = gpuiBaseStyle()
  case kind
  of "app-shell":
    result.add("display", "flex")
    result.add("flex-direction", "column")
    result.add("padding", "12px")
    result.add("background-color", "#0b0d12")
    result.add("color", "#e2e8f0")
    result.add("border", "1px solid rgba(255,255,255,0.08)")
  of "input":
    result.add("display", "flex")
    result.add("gap", "8px")
    result.add("padding", "6px 0")
  of "filter-bar":
    result.add("display", "flex")
    result.add("gap", "6px")
    result.add("padding", "4px 0")
  of "row":
    result.add("display", "flex")
    result.add("align-items", "center")
    result.add("gap", "6px")
    result.add("padding", "4px 8px")
    result.add("border-bottom", "1px solid rgba(255,255,255,0.05)")
  of "list":
    result.add("display", "flex")
    result.add("flex-direction", "column")
    result.add("list-style", "none")
    result.add("padding", "0")
    result.add("margin", "0")
  of "summary":
    result.add("padding", "6px 8px")
    result.add("font-size", "12px")
    result.add("color", "#94a3b8")
  of "vector-symbol":
    result.add("display", "inline-block")
    result.add("width", "16px")
    result.add("height", "16px")
    result.add("color", "#3b82f6")
  else:
    case tag
    of "button":
      result.add("padding", "4px 10px")
      result.add("border-radius", "5px")
      result.add("border", "1px solid rgba(255,255,255,0.12)")
      result.add("background-color", "rgba(255,255,255,0.04)")
      result.add("color", "#e2e8f0")
    of "input":
      result.add("padding", "4px 8px")
      result.add("border-radius", "5px")
      result.add("border", "1px solid rgba(255,255,255,0.12)")
      result.add("background-color", "rgba(255,255,255,0.04)")
      result.add("color", "#e2e8f0")
    of "p":
      result.add("color", "#94a3b8")
      result.add("font-size", "12px")
    of "span":
      result.add("color", "#cbd5e1")
    of "footer":
      result.add("color", "#64748b")
      result.add("font-size", "11px")
    else:
      result.add("color", "#cbd5e1")
  if class.contains("completed"):
    result.add("opacity", "0.55")
    result.add("text-decoration", "line-through")
  if class.contains("selected"):
    result.add("background-color", "#1e293b")
    result.add("color", "#ffffff")

# ---------------------------------------------------------------------------
# Tree walker
# ---------------------------------------------------------------------------

proc walkGpui(node: GpuiElement; x, y, w, h: int;
              depth: int; maxDepth: int): RenderTreeNode =
  ## DFS that mirrors `gpui_adapter.walkLayout`'s structure (same
  ## header-band heuristic) so the render-tree's bounds line up with
  ## what the deprecated pixel raster produced. The element-tree
  ## manifest stays the authoritative source for hit-test bounds; this
  ## per-node bounds is a presentation hint only.
  let tag = getTag(node)
  let txt = textContent(node)
  let class = getAttribute(node, "class")
  let kind = getAttribute(node, ElementKindAttr)
  let path = getAttribute(node, ComponentPathAttr)
  let id = if path.len > 0: path else: tag & "#" & $depth
  result = RenderTreeNode(
    id: id, tag: tag, text: txt, componentPath: path,
    style: gpuiStyleFor(tag, class, kind),
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
    result.children.add walkGpui(
      child, x + 4, cy, w - 8, ch, depth + 1, maxDepth)
    cy += ch

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

proc buildGpuiRenderTreeManifest*(root: GpuiElement;
                                   width, height: int;
                                   frameSeq: int = 0):
                                  RenderTreeManifest =
  ## Build a fresh render-tree manifest from the current state of the
  ## GPUI tree rooted at ``root``. Idempotent: same tree → same
  ## manifest, so the bridge can hash and skip emission on idle ticks.
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
    root: walkGpui(root, 0, 0, width, height, 0, 8))

type
  GpuiRenderTreeProviderState* = ref object
    ## RS-M13b: handle the launcher gives to the bridge. Captures the
    ## headless root + the dynamic surface dimensions; the bridge calls
    ## ``buildImpl`` on each cadence tick and dedups via tree-hash.
    root*: GpuiElement
    width*, height*: int
    frameSeq*: int

proc newGpuiRenderTreeProvider*(root: GpuiElement;
                                width, height: int):
                               RenderTreeProvider =
  ## Wrap a GPUI headless root + surface dimensions as a
  ## ``RenderTreeProvider``. The bridge config drops this into its
  ## ``renderTree`` field; cadence + dedup live on the bridge side.
  let state = GpuiRenderTreeProviderState(
    root: root, width: width, height: height, frameSeq: 0)
  RenderTreeProvider(
    buildImpl: proc(): RenderTreeManifest {.gcsafe.} =
      {.cast(gcsafe).}:
        state.frameSeq.inc
        buildGpuiRenderTreeManifest(
          state.root, state.width, state.height, state.frameSeq))

proc newGpuiRenderTreeProvider*(state: GpuiRenderTreeProviderState):
                               RenderTreeProvider =
  ## Overload: caller-owned state cell so dynamic resize / re-rooting
  ## flows through to the next manifest the bridge requests.
  RenderTreeProvider(
    buildImpl: proc(): RenderTreeManifest {.gcsafe.} =
      {.cast(gcsafe).}:
        state.frameSeq.inc
        buildGpuiRenderTreeManifest(
          state.root, state.width, state.height, state.frameSeq))

# ---------------------------------------------------------------------------
# RS-M11b: element-tree manifest builder.
# ---------------------------------------------------------------------------
##
## Mirrors the lifted-out shape RS-M11b introduced in
## ``gpui_adapter.nim`` (which is now `{.deprecated.}` along with the
## pixel rasteriser). The element-tree manifest is layer-1 metadata that
## the editor's overlay positioning treats as authoritative for
## hit-test, regardless of which rendering surface the launcher chose
## (pixels vs. tree).

proc buildGpuiElementTreeManifest*(root: GpuiElement;
                                   width, height: int;
                                   frameSeq: int = 0):
                                  ElementTreeManifest =
  ## Build a fresh element-tree manifest from the current state of the
  ## GPUI tree rooted at ``root``. Filters to nodes carrying a non-empty
  ## ``ComponentPathAttr`` value; the rest of the layout heuristic
  ## mirrors `walkGpui` so the manifest's bounds line up with the
  ## render-tree's bounds for the same node.
  proc walk(node: GpuiElement; x, y, w, h: int;
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
