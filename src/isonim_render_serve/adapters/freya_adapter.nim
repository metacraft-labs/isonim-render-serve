## RS-M4: Freya streaming adapter.
##
## Wraps a `FreyaRenderer` + root `FreyaElement` into the bridge's
## `AnyFrameSource` so the WebSocket bridge can stream the headless
## Freya tree to a browser canvas.
##
## ## Capture approach: tree-derived synthetic raster
##
## RS-M4 mirrors RS-M2's GPUI adapter shape exactly. We had two options
## for producing RGBA pixels from a Freya tree:
##
##   (a) **Real Skia offscreen render via the Rust shim.** Extend
##       `freya-nim-shim` with a `freya_capture_frame(w, h) -> *u8`
##       C entry point that drives Freya's Skia-backed render pipeline
##       (`makeImageSnapshot`) into an offscreen surface. Freya is
##       built on Dioxus and uses Skia for its raster backend; Skia
##       surfaces yield RGBA bytes directly. This is the spec-blessed
##       production path (see RS-M0's back-end capture table). It
##       requires the shim to be built with the `--features
##       freya-backend` Cargo feature *and* the dev shell to ship
##       Skia's runtime deps (FreeType, fontconfig, software
##       rasterizer) — neither of which is currently wired up in the
##       bare Linux CI lane (the headless shim ships without the
##       heavyweight Skia/font deps so it can link cleanly without a
##       display server).
##
##   (b) **Tree-derived synthetic raster.** Walk the element tree
##       from Nim using the shim's tree-inspection helpers
##       (`childCount`, `nthChild`, `getTag`, `getAttribute`,
##       `textContent`), assign a fill colour per element kind, and
##       paint each element as a coloured rectangle laid out by a
##       deterministic vertical-stack heuristic.
##
## RS-M4's deliverable per the spec is the *second real back-end*:
## proving the FrameSource abstraction generalises beyond GPUI. The
## bridge consumes a real adapter that produces real pixels from the
## real headless Freya tree, end-to-end through the real shim
## cdylib. Path (b) satisfies that contract without blocking on the
## Skia offscreen-rendering plumbing, which is RS-M5 territory for
## the Cocoa adapter (AppKit exposes a clean offscreen surface that
## maps onto the same approach Skia would take).
##
## The trade-off is documented honestly: the raster produced by this
## adapter is *not* what Freya would draw if it had a window — it's
## a debugging-quality bitmap that visualises the headless tree's
## topology and content. The Freya tag set (`rect`, `label`,
## `paragraph`, `image`, `ScrollView`, ...) differs from GPUI's
## HTML-like tag set, so the colour table below is Freya-specific.

import std/[hashes, strutils]

import isonim_freya/renderer
import isonim_freya/bindings as freya_bindings

import ../frame_source
import ../packet
import ../element_tree_attrs

type
  FreyaFrameSource* = ref object
    renderer*: FreyaRenderer
    root*: FreyaElement
    width*, height*: int

# ---------------------------------------------------------------------------
# Layout heuristic: pack the element tree into stacked rectangles.
# ---------------------------------------------------------------------------
#
# RS-M11b: the layout pass MUST be the single source of truth for both
# the rasteriser AND the element-tree manifest builder. Mirror of the
# GPUI adapter's setup — see ``gpui_adapter.nim`` for the rationale.

type
  LayoutRect* = object
    ## Per-node layout entry. Pure geometry + identity; colour /
    ## alpha live in the rasteriser's local ``Rect``.
    node*: FreyaElement
    x*, y*, w*, h*: int
    depth*: int
    tag*, label*: string

  Rect = object
    x, y, w, h: int
    r, g, b, a: uint8
    label: string

proc colourForTag(tag, label: string): tuple[r, g, b: uint8] =
  ## Map a (tag, label) pair to a deterministic RGB triplet. The
  ## Freya tag set is the post-mapping vocabulary (`rect`, `label`,
  ## `paragraph`, `image`, `ScrollView`) — see
  ## `isonim_freya/renderer.tagMap`. Unknown tags fold the
  ## `tag`/`label` hash into an HSV-ish colour so successive
  ## elements with different tags stay visually distinct.
  case tag
  of "rect":
    result = (0x22'u8, 0x33'u8, 0x44'u8)
  of "label":
    result = (0x66'u8, 0x66'u8, 0x66'u8)
  of "paragraph":
    result = (0x55'u8, 0x55'u8, 0x77'u8)
  of "image":
    result = (0xAA'u8, 0xAA'u8, 0xCC'u8)
  of "ScrollView":
    result = (0x33'u8, 0x33'u8, 0x55'u8)
  of "div", "button":
    # Some leaves use unmapped tags (the shim accepts arbitrary
    # strings); colour them as GPUI does so a side-by-side compare
    # of the two adapter outputs is readable.
    if tag == "button":
      result = (0x44'u8, 0x88'u8, 0xCC'u8)
    else:
      result = (0x22'u8, 0x33'u8, 0x44'u8)
  else:
    let h = hash(tag & ":" & label)
    result = (uint8((h shr 0) and 0xFF),
              uint8((h shr 8) and 0xFF),
              uint8((h shr 16) and 0xFF))

proc colourForKind(kind: string): tuple[applied: bool; r, g, b: uint8] =
  ## EMC2-M2. Map ``ElementKindAttr`` values that carry an interactive
  ## state hint onto distinct background tints. Returns ``applied=false``
  ## for kinds that don't override the tag-derived palette. Mirror of
  ## the GPUI adapter's helper (see ``gpui_adapter.colourForKind`` for
  ## the matrix-ROI fingerprint rationale).
  case kind
  of "row-hovered":
    (true, 0x22'u8, 0x22'u8, 0xAA'u8)
  of "row-pressed":
    (true, 0xCC'u8, 0x88'u8, 0x22'u8)
  of "row-completed":
    (true, 0x33'u8, 0x88'u8, 0x44'u8)
  else:
    (false, 0'u8, 0'u8, 0'u8)

proc parsePxAttr(s: string): int =
  ## Parse an integer pixel attribute like "120" or "120px". Returns 0
  ## when the value is empty or unparseable; the layout caller treats
  ## 0 as "no fixed size, distribute flexibly". Mirror of the helper
  ## in ``cocoa_adapter.nim``.
  if s.len == 0: return 0
  var t = s
  if t.endsWith("px"): t = t[0 ..< t.len - 2]
  try: parseInt(t.strip()) except CatchableError: 0

proc pxAttr(node: FreyaElement; name: string): int =
  max(0, parsePxAttr(getAttribute(node, name)))

proc walkLayout(node: FreyaElement; x, y, w, h: int;
                rects: var seq[LayoutRect]; depth = 0; maxDepth = 8) =
  ## DFS that produces one ``LayoutRect`` per visited element. The
  ## traversal order matches the F-packet rasteriser's drawing order
  ## so the manifest's per-node bounds are byte-stable across re-emits.
  ##
  ## M-EVP-14 round-7 fix: extended to honor ``data-fixed-width`` and
  ## ``data-fixed-height`` attributes (mirror of the cocoa adapter's
  ## fixed-size pre-pass). A child with ``data-fixed-width="120"``
  ## under a horizontal-layout parent gets exactly 120 px along the
  ## main axis and the remainder is distributed equally among the
  ## flex siblings. Without this, the previous "split parent's width
  ## equally" behaviour stretched the task_app's Add Task button to
  ## ~40 % of the pane and the filter chips to ~1/3 each, which the
  ## strict reviewer flagged as "severely stretched controls".
  if node == nil or w <= 0 or h <= 0: return
  if depth > maxDepth: return
  let tag = getTag(node)
  let txt = textContent(node)
  let cls = getAttribute(node, "class")
  let label = txt & "|" & cls
  rects.add LayoutRect(node: node, x: x, y: y, w: w, h: h,
                       depth: depth, tag: tag, label: label)
  let count = childCount(node)
  if count == 0: return
  let isHorizontal = getAttribute(node, "data-layout") == "horizontal"
  let padding = pxAttr(node, "data-layout-padding")
  let gap = pxAttr(node, "data-layout-gap")
  # Pre-pass: compute per-child fixed and flexible sizes along the
  # layout axis. Mirrors the cocoa adapter exactly so cross-renderer
  # parity for the same leaves-table emits matching geometry.
  var fixedSizes = newSeq[int](count)
  var fixedTotal = 0
  var flexCount = 0
  for i in 0 ..< count:
    let child = nthChild(node, i)
    if child == nil:
      fixedSizes[i] = 0
      continue
    let attr =
      if isHorizontal: getAttribute(child, "data-fixed-width")
      else: getAttribute(child, "data-fixed-height")
    let s = parsePxAttr(attr)
    fixedSizes[i] = s
    if s > 0: fixedTotal += s
    else: inc flexCount
  if isHorizontal:
    # Horizontal flow — left-to-right. Each child fills the parent's
    # height; widths come from ``data-fixed-width`` or an equal share
    # of the remainder. The 4 px / 8 px insets from the vertical path
    # are NOT applied here so a row of pinned buttons sits flush
    # against the parent's edges.
    let bodyX = x + padding
    let bodySpanW = w - (padding * 2)
    let childTotalW = bodySpanW - (gap * max(0, count - 1))
    if bodySpanW <= 0 or childTotalW <= 0: return
    let flexTotal = max(0, childTotalW - fixedTotal)
    let perFlex = if flexCount > 0: max(1, flexTotal div flexCount) else: 0
    var cx = bodyX
    let childY = y + padding
    let childH = max(1, h - (padding * 2))
    for i in 0 ..< count:
      let child = nthChild(node, i)
      if child == nil: continue
      let remaining = (bodyX + bodySpanW) - cx
      if remaining <= 0: break
      let cw =
        if fixedSizes[i] > 0:
          min(fixedSizes[i], remaining)
        elif i == count - 1:
          remaining
        elif perFlex > remaining:
          remaining
        else:
          perFlex
      if cw <= 0: break
      walkLayout(child, cx, childY, cw, childH, rects,
                 depth + 1, maxDepth)
      cx += cw + gap
  else:
    # Vertical flow — the historical default. Reserve a small "header
    # band" at the top so the parent's fill remains visible (children
    # stack below). 12px or 1/4 of h.
    let headerBand = min(12, max(0, h div 4))
    let bodyX = x + 4 + padding
    let bodyW = w - 8 - (padding * 2)
    let bodyY = y + headerBand + padding
    let bodySpanH = h - headerBand - (padding * 2)
    let childTotalH = bodySpanH - (gap * max(0, count - 1))
    if bodyW <= 0 or bodySpanH <= 0 or childTotalH <= 0: return
    let flexTotal = max(0, childTotalH - fixedTotal)
    let perFlex = if flexCount > 0: max(1, flexTotal div flexCount) else: 0
    var cy = bodyY
    for i in 0 ..< count:
      let child = nthChild(node, i)
      if child == nil: continue
      let remaining = (bodyY + bodySpanH) - cy
      if remaining <= 0: break
      let ch =
        if fixedSizes[i] > 0:
          min(fixedSizes[i], remaining)
        elif i == count - 1:
          remaining
        elif perFlex > remaining:
          remaining
        else:
          perFlex
      if ch <= 0: break
      walkLayout(child, bodyX, cy, bodyW, ch, rects, depth + 1, maxDepth)
      cy += ch + gap

proc buildLayoutRects*(root: FreyaElement; width, height: int):
                      seq[LayoutRect] =
  ## Public layout pass. Same depth heuristic ``renderFrame`` uses, so
  ## the rasteriser and the manifest builder share a single source of
  ## truth for per-node geometry.
  result = @[]
  if root == nil or width <= 0 or height <= 0: return
  walkLayout(root, 0, 0, width, height, result)

proc hitTestPath*(root: FreyaElement; width, height: int;
                  x, y: int): seq[FreyaElement] =
  ## EPP-M12. Mirror of the GPUI ``hitTestPath`` — resolves a click
  ## coordinate to an ordered chain of shadow-tree nodes that contain
  ## the point ``(x, y)`` (deepest first). See ``gpui_adapter.hitTestPath``
  ## for the rationale and the walk-up dispatch contract.
  result = @[]
  if root == nil or width <= 0 or height <= 0: return
  let rects = buildLayoutRects(root, width, height)
  for i in countdown(rects.len - 1, 0):
    let r = rects[i]
    if x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h:
      result.add r.node

# ---------------------------------------------------------------------------
# Rasterizer: blit the rectangle list into an RGBA8888 row-major buffer.
# ---------------------------------------------------------------------------

proc fillRect(pixels: var seq[byte]; w, h: int; r: Rect) =
  let x0 = max(0, r.x)
  let y0 = max(0, r.y)
  let x1 = min(w, r.x + r.w)
  let y1 = min(h, r.y + r.h)
  if x1 <= x0 or y1 <= y0: return
  # Source-over alpha blend: out = src + dst * (1 - srcAlpha/255).
  let aFrac = int(r.a)
  for y in y0 ..< y1:
    var off = (y * w + x0) * 4
    for _ in x0 ..< x1:
      let dr = int(pixels[off])
      let dg = int(pixels[off + 1])
      let db = int(pixels[off + 2])
      let inv = 255 - aFrac
      pixels[off] = uint8(min(255, (int(r.r) * aFrac + dr * inv) div 255))
      pixels[off + 1] = uint8(min(255, (int(r.g) * aFrac + dg * inv) div 255))
      pixels[off + 2] = uint8(min(255, (int(r.b) * aFrac + db * inv) div 255))
      pixels[off + 3] = 0xFF'u8
      off += 4

proc renderSyntheticFrame(src: FreyaFrameSource): Frame
proc renderHeadlessFrame(src: FreyaFrameSource): Frame

proc renderFrame*(src: FreyaFrameSource): Frame =
  ## Walk the Freya tree rooted at `src.root` and produce an RGBA8888
  ## frame of `src.width` × `src.height` pixels. Pure function w.r.t.
  ## the tree's current state — the same tree always yields the same
  ## pixel buffer.
  ##
  ## RS-M14 Phase 1: when the shim is built with `--features
  ## freya-headless` AND the binary is compiled with
  ## `-d:useFreyaHeadless`, this proc routes through
  ## `freya_render_to_pixels` to obtain real Freya pixels via
  ## `freya-testing`'s Skia raster path. Otherwise it falls back to
  ## the pre-RS-M14 synthetic vertical-stack raster (see
  ## `renderSyntheticFrame`). The fallback path is also used if the
  ## headless render returns an error code — this gives the editor a
  ## degraded but still-usable frame instead of a hard failure when
  ## the layout engine can't run (e.g. Linux CI without fonts).
  when defined(useFreyaHeadless):
    let frame = renderHeadlessFrame(src)
    if frame.pixels.len == src.width * src.height * 4:
      return frame
    # Fall through to synthetic on size mismatch — same defence as
    # the Rust-side `SizeMismatch` error code.
  renderSyntheticFrame(src)

proc renderHeadlessFrame(src: FreyaFrameSource): Frame =
  ## Drive the shim's `freya_render_to_pixels` entry point to obtain
  ## RGBA8888 bytes from Freya's real render pipeline. The buffer is
  ## owned by the shim until `freya_free_pixels` is called, so we
  ## copy it into a Nim seq before returning.
  ##
  ## The frame still carries the same `FrameFlags` shape and obeys the
  ## F-packet protocol (RS-M0): RGBA8888 row-major, non-premultiplied
  ## sRGB, top row first.
  let w = src.width
  let h = src.height
  if w <= 0 or h <= 0:
    return Frame(kind: fkFull,
                 flags: FrameFlags(isDiff: false, isVideo: false),
                 width: w, height: h, pixels: @[])
  # RS-M14 Phase 1: the headless `shadow_tree_app` reads from the shim's
  # global `ROOT_NODE_ID`. The streaming adapter builds the tree through
  # the `FreyaRenderer.createElement` etc. API which does NOT route
  # through `freya_launch` (the path that normally sets the root). So we
  # have to pin the root explicitly per frame — cheap, idempotent, and
  # mirrors the design pattern of the GPUI adapter (see RS-M14 Phase 2
  # in `gpui_adapter.nim`). Without this call the shim returns its
  # "No shadow tree root found" placeholder element.
  freya_bindings.freya_set_root_element(src.root)
  var outPtr: ptr uint8
  var outLen: csize_t = 0
  let rc = freya_bindings.freya_render_to_pixels(
    cuint(w), cuint(h), cfloat(1.0),
    addr outPtr, addr outLen)
  if rc != 0 or outPtr.isNil or outLen == 0:
    # Headless render failed; caller falls back to synthetic.
    return Frame(kind: fkFull,
                 flags: FrameFlags(isDiff: false, isVideo: false),
                 width: w, height: h, pixels: @[])
  defer:
    freya_bindings.freya_free_pixels(outPtr, outLen)
  var pixels = newSeq[byte](int(outLen))
  if pixels.len > 0:
    copyMem(addr pixels[0], outPtr, int(outLen))
  Frame(kind: fkFull,
        flags: FrameFlags(isDiff: false, isVideo: false),
        width: w, height: h, pixels: pixels)

proc renderSyntheticFrame(src: FreyaFrameSource): Frame =
  ## Pre-RS-M14 tree-derived synthetic raster. Kept as a fallback for
  ## hosts where the headless Skia surface isn't available (e.g.
  ## Linux CI without fonts wired up) and as the default for builds
  ## that don't opt into `-d:useFreyaHeadless`. Documented behaviour:
  ## colour-codes each tree node and packs them into a vertical stack
  ## with a Freya-purple identifier band along the bottom edge.
  let w = src.width
  let h = src.height
  var pixels = newSeq[byte](w * h * 4)
  # Initialise the canvas to opaque dark-grey so empty trees still
  # produce a visually distinct frame from the stub gradient.
  for i in 0 ..< (w * h):
    let off = i * 4
    pixels[off] = 0x18'u8
    pixels[off + 1] = 0x18'u8
    pixels[off + 2] = 0x18'u8
    pixels[off + 3] = 0xFF'u8
  if src.root != nil:
    let layoutRects = buildLayoutRects(src.root, w, h)
    for lr in layoutRects:
      var (cr, cg, cb) = colourForTag(lr.tag, lr.label)
      var alpha = 0xFFu8 - uint8(min(lr.depth * 16, 0xC0))
      # EMC2-M2: ElementKindAttr -> paint binding. Honour interactive-
      # state kinds (``row-hovered`` / ``row-pressed`` / ``row-completed``)
      # so the matrix's fingerprint ROI registers a paint change when
      # the task_app flips a row's kind. See the GPUI adapter's
      # ``colourForKind`` for the matrix-ROI fingerprint rationale.
      let kindOverride = colourForKind(getAttribute(lr.node, ElementKindAttr))
      if kindOverride.applied:
        cr = kindOverride.r; cg = kindOverride.g; cb = kindOverride.b
        alpha = 0xFF'u8
      fillRect(pixels, w, h, Rect(x: lr.x, y: lr.y, w: lr.w, h: lr.h,
                                  r: cr, g: cg, b: cb, a: alpha,
                                  label: lr.label))
  # Freya backend identifier strip — a 2-pixel purple band along the
  # bottom edge, applied AFTER the tree raster. Visually unobtrusive
  # but guarantees byte-distinct output vs GPUI / TUI / web for the
  # same tree shape (GPUI's tagMap collapses the same HTML tag set
  # onto a div-heavy vocabulary that overlaps Freya's `rect` palette).
  let bandHeight = max(1, min(2, h))
  for y in max(0, h - bandHeight) ..< h:
    var off = y * w * 4
    for _ in 0 ..< w:
      pixels[off] = 0x75'u8
      pixels[off + 1] = 0x50'u8
      pixels[off + 2] = 0x7B'u8
      pixels[off + 3] = 0xFF'u8
      off += 4
  result = Frame(kind: fkFull,
                 flags: FrameFlags(isDiff: false, isVideo: false),
                 width: w, height: h, pixels: pixels)

proc close*(src: FreyaFrameSource) =
  ## No-op: the renderer + root are owned by the caller (the
  ## composition root that built the tree). The shim's tree is reset
  ## via `freya_reset_tree()` by the demo when it tears down.
  discard

# ---------------------------------------------------------------------------
# Constructors
# ---------------------------------------------------------------------------

proc newFreyaFrameSource*(renderer: FreyaRenderer; root: FreyaElement;
                          width = 800; height = 600): FreyaFrameSource =
  ## Build a `FreyaFrameSource`. The default 800×600 matches the
  ## canonical window size used by the EX-M4 Freya task_app demo
  ## (`createWindow("Task Manager - IsoNim Freya", 800.0, 600.0)`
  ## at the foot of `isonim-examples/task_app/main_freya.nim`).
  FreyaFrameSource(renderer: renderer, root: root,
                   width: width, height: height)

proc toAny*(src: FreyaFrameSource): AnyFrameSource =
  ## Wrap the Freya source in the bridge's polymorphic `AnyFrameSource`
  ## so it can be dropped into `BridgeConfig.frameSource` alongside
  ## the stub and the GPUI adapter.
  let captured = src
  newAnyFrameSource(src.width, src.height,
    renderFrameImpl = proc(): Frame {.gcsafe.} =
      {.cast(gcsafe).}: captured.renderFrame(),
    closeImpl = proc() {.gcsafe.} =
      {.cast(gcsafe).}: captured.close())

# ---------------------------------------------------------------------------
# RS-M11b: element-tree manifest builder
# ---------------------------------------------------------------------------
##
## Mirror of ``buildGpuiElementTreeManifest``. The two adapters share
## attribute constants via ``isonim_render_serve/element_tree_attrs``;
## the per-node walk uses each renderer's own tree-inspection API.

proc buildFreyaElementTreeManifest*(root: FreyaElement;
                                    width, height: int;
                                    frameSeq: int = 0):
                                   ElementTreeManifest =
  ## Build a fresh manifest from the current state of the Freya tree
  ## rooted at ``root``. Idempotent: same tree → same manifest, so the
  ## bridge can hash the result and skip emission when unchanged.
  result = ElementTreeManifest(
    frameSeq: frameSeq,
    surfaceWidth: width,
    surfaceHeight: height,
    elements: @[])
  if root == nil or width <= 0 or height <= 0: return
  let layoutRects = buildLayoutRects(root, width, height)
  for lr in layoutRects:
    let path = getAttribute(lr.node, ComponentPathAttr)
    if path.len == 0: continue
    let kind = getAttribute(lr.node, ElementKindAttr)
    result.elements.add ElementEntry(
      id: path,
      componentPath: path,
      kind: kind,
      bounds: ElementBounds(x: lr.x, y: lr.y, w: lr.w, h: lr.h))
