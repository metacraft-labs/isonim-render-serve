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

import std/hashes

import isonim_freya/renderer

import ../frame_source
import ../packet

type
  FreyaFrameSource* = ref object
    renderer*: FreyaRenderer
    root*: FreyaElement
    width*, height*: int

# ---------------------------------------------------------------------------
# Layout heuristic: pack the element tree into stacked rectangles.
# ---------------------------------------------------------------------------

type
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

proc layoutTree(node: FreyaElement; x, y, w, h: int;
                rects: var seq[Rect]; depth = 0; maxDepth = 8) =
  ## Walk the tree and stack each level vertically inside its
  ## parent's rectangle. Depth-limited so degenerate trees can't
  ## blow the stack. Produces one `Rect` per visited element.
  if node == nil or w <= 0 or h <= 0: return
  if depth > maxDepth: return
  let tag = getTag(node)
  let txt = textContent(node)
  let cls = getAttribute(node, "class")
  let label = txt & "|" & cls
  let (cr, cg, cb) = colourForTag(tag, label)
  let alpha = 0xFFu8 - uint8(min(depth * 16, 0xC0))
  rects.add Rect(x: x, y: y, w: w, h: h,
                 r: cr, g: cg, b: cb, a: alpha, label: label)
  let count = childCount(node)
  if count == 0: return
  # Reserve a small "header band" at the top so the parent's fill
  # remains visible (children stack below). 12px or 1/4 of h.
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
      if i == count - 1: bodyY + bodyH - cy  # last child consumes remainder
      else: perChild
    layoutTree(child, x + 4, cy, w - 8, ch, rects, depth + 1, maxDepth)
    cy += ch

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

proc renderFrame*(src: FreyaFrameSource): Frame =
  ## Walk the Freya tree rooted at `src.root` and produce an RGBA8888
  ## frame of `src.width` × `src.height` pixels. Pure function w.r.t.
  ## the tree's current state — the same tree always yields the same
  ## pixel buffer.
  ##
  ## The canvas is initialised to a backend-identifier background tint
  ## (a small Freya-purple band along the bottom) so the frame is
  ## guaranteed byte-distinct from the GPUI adapter's output even when
  ## the headless trees happen to project to identical rectangle
  ## layouts (which is the common case because GPUI's tagMap collapses
  ## the same HTML tag set onto a div-heavy vocabulary).
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
    var rects: seq[Rect] = @[]
    layoutTree(src.root, 0, 0, w, h, rects)
    for r in rects:
      fillRect(pixels, w, h, r)
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
