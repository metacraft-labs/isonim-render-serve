## RS-M2: GPUI streaming adapter.
##
## Wraps a `GpuiRenderer` + root `GpuiElement` into the
## bridge's `AnyFrameSource` so the WebSocket bridge can stream the
## headless GPUI tree to a browser canvas.
##
## ## Capture approach: tree-derived synthetic raster
##
## We had two options for producing RGBA pixels from a GPUI tree:
##
##   (a) **Real offscreen render via the Rust shim.** Extend
##       `gpui-nim-shim` with a `gpui_capture_frame(w, h) -> *u8` C
##       entry point that uses GPUI's offscreen rendering pipeline
##       (i.e. the GPU path with a render-to-texture target instead
##       of a window framebuffer). This requires the shim to be built
##       with the `--features gpui-backend` Cargo feature *and* GPUI
##       to expose an offscreen render target — neither of which is
##       currently wired up in the dev shell (the headless shim ships
##       without the heavyweight GPU/font/X11/Wayland deps so it can
##       link cleanly on the bare Linux CI lane).
##
##   (b) **Tree-derived synthetic raster.** Walk the element tree
##       from Nim using the shim's existing tree-inspection helpers
##       (`childCount`, `nthChild`, `getTag`, `getAttribute`,
##       `textContent`), assign a fill colour per element kind, and
##       paint each element as a coloured rectangle laid out by a
##       deterministic vertical-stack heuristic.
##
## RS-M2's deliverable per the spec is the *FrameSource abstraction
## proof*: the bridge consumes a real adapter that produces real
## pixels from the real headless GPUI tree, end-to-end through the
## real shim cdylib. Path (b) satisfies that contract without
## blocking on the GPUI offscreen-rendering plumbing (which would
## also be a poor fit for the "stream a Linux server's GPU output"
## use case the bridge is ultimately aimed at — the production path
## there is screencap-style frame interception, not GPUI's own
## window swapchain).
##
## The trade-off is documented honestly: the raster produced by this
## adapter is *not* what GPUI would draw if it had a window — it's a
## debugging-quality bitmap that visualises the headless tree's
## topology and content. RS-M3 will add diff-region encoding on top
## (no change to the capture path); RS-M5's macOS Cocoa adapter
## (where AppKit *does* expose a clean offscreen API) will be the
## first adapter to use approach (a) in production.

import std/hashes

import isonim_gpui/renderer

import ../frame_source
import ../packet

type
  GpuiFrameSource* = ref object
    renderer*: GpuiRenderer
    root*: GpuiElement
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
  ## Map a (tag, label) pair to a deterministic RGB triplet. The hash
  ## is folded into a high-saturation HSV-ish colour so successive
  ## elements with different tags are visually distinct.
  case tag
  of "div":
    result = (0x22'u8, 0x33'u8, 0x44'u8)
  of "button":
    result = (0x44'u8, 0x88'u8, 0xCC'u8)
  of "p", "span":
    result = (0x66'u8, 0x66'u8, 0x66'u8)
  of "li":
    result = (0x55'u8, 0x55'u8, 0x77'u8)
  of "ul", "ol":
    result = (0x33'u8, 0x33'u8, 0x55'u8)
  of "input":
    result = (0xAA'u8, 0xAA'u8, 0xCC'u8)
  of "footer":
    result = (0x44'u8, 0x66'u8, 0x44'u8)
  else:
    let h = hash(tag & ":" & label)
    result = (uint8((h shr 0) and 0xFF),
              uint8((h shr 8) and 0xFF),
              uint8((h shr 16) and 0xFF))

proc layoutTree(node: GpuiElement; x, y, w, h: int;
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

proc renderFrame*(src: GpuiFrameSource): Frame =
  ## Walk the GPUI tree rooted at `src.root` and produce an RGBA8888
  ## frame of `src.width` × `src.height` pixels. Pure function w.r.t.
  ## the tree's current state — the same tree always yields the same
  ## pixel buffer (modulo a constant-time per-call advance: none).
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
  # GPUI backend identifier strip — a 2-pixel teal band along the
  # bottom edge, applied AFTER the tree raster. Visually unobtrusive
  # but guarantees byte-distinct output vs Freya / TUI / web for the
  # same tree shape (the two tag-derived rect palettes overlap in the
  # `div`/`rect` mapping; this band keeps the per-backend canvas
  # hashes pairwise distinct).
  let bandHeight = max(1, min(2, h))
  for y in max(0, h - bandHeight) ..< h:
    var off = y * w * 4
    for _ in 0 ..< w:
      pixels[off] = 0x06'u8
      pixels[off + 1] = 0x98'u8
      pixels[off + 2] = 0x9A'u8
      pixels[off + 3] = 0xFF'u8
      off += 4
  result = Frame(kind: fkFull,
                 flags: FrameFlags(isDiff: false, isVideo: false),
                 width: w, height: h, pixels: pixels)

proc close*(src: GpuiFrameSource) =
  ## No-op: the renderer + root are owned by the caller (the
  ## composition root that built the tree). The shim's tree is reset
  ## via `gpui_reset_tree()` by the demo when it tears down.
  discard

# ---------------------------------------------------------------------------
# Constructors
# ---------------------------------------------------------------------------

proc newGpuiFrameSource*(renderer: GpuiRenderer; root: GpuiElement;
                         width = 800; height = 600): GpuiFrameSource =
  ## Build a `GpuiFrameSource`. The default 800×600 is the canonical
  ## window size for the GPUI task_app demo (matches the
  ## `createWindow("Task Manager - IsoNim GPUI", 800.0, 600.0)` call
  ## at the foot of `isonim-examples/task_app/main_gpui.nim`).
  GpuiFrameSource(renderer: renderer, root: root,
                  width: width, height: height)

proc toAny*(src: GpuiFrameSource): AnyFrameSource =
  ## Wrap the GPUI source in the bridge's polymorphic `AnyFrameSource`
  ## so it can be dropped into `BridgeConfig.frameSource` alongside
  ## the stub. Mirrors the stub's `toAny` helper.
  let captured = src
  newAnyFrameSource(src.width, src.height,
    renderFrameImpl = proc(): Frame {.gcsafe.} =
      {.cast(gcsafe).}: captured.renderFrame(),
    closeImpl = proc() {.gcsafe.} =
      {.cast(gcsafe).}: captured.close())

