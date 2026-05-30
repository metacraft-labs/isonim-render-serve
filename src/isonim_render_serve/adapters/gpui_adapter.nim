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
import isonim_gpui/bindings as gpui_bindings

import ../frame_source
import ../packet
import ../element_tree_attrs

# EMC-M2 Option B: ``newSeqUninit[byte]`` skips the zero-init pass that
# dominates the EMC-M1-audited 2.0-2.7 ms ``newSeq[byte]`` cost on the
# headless readback path. The shim's ``copyMem`` fills the whole buffer
# immediately afterwards, so zero-init is wasted work. ``stew/shims``
# provides the compat shim for Nim versions that ship the proc under a
# different name.
import stew/shims/sequninit

type
  GpuiFrameSource* = ref object
    renderer*: GpuiRenderer
    root*: GpuiElement
    width*, height*: int

# ---------------------------------------------------------------------------
# Layout heuristic: pack the element tree into stacked rectangles.
# ---------------------------------------------------------------------------
#
# RS-M11b: the layout pass MUST be the single source of truth for both
# the rasteriser AND the element-tree manifest builder. If we computed
# bounds twice (once for pixels, once for hit-test rects), the F-packet
# pixels and the M-packet rectangles could drift apart. ``LayoutRect``
# carries the per-node (tree, geometry, label) tuple; ``renderFrame``
# derives a ``Rect`` with colour fields from each ``LayoutRect`` on the
# fly, and ``buildGpuiElementTreeManifest`` filters the same list for
# nodes that carry a ``data-component-path`` annotation.

type
  LayoutRect* = object
    ## Per-node layout entry. Pure geometry + identity; colour /
    ## alpha live in the rasteriser's local ``Rect``.
    node*: GpuiElement
    x*, y*, w*, h*: int
    depth*: int
    tag*, label*: string
    ariaPressed*: bool
    toggleOn*: bool
    isToggle*: bool

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

proc walkLayout(node: GpuiElement; x, y, w, h: int;
                rects: var seq[LayoutRect]; depth = 0; maxDepth = 8) =
  ## DFS that produces one ``LayoutRect`` per visited element. The
  ## traversal order matches the F-packet rasteriser's drawing order
  ## so the manifest's per-node bounds are byte-stable across re-emits.
  if node == nil or w <= 0 or h <= 0: return
  if depth > maxDepth: return
  let tag = getTag(node)
  let txt = textContent(node)
  let cls = getAttribute(node, "class")
  let label = txt & "|" & cls
  # Wave U-4: lift the leaf-set "active" hint into the synthetic
  # rasteriser so the GPUI placeholder paints the same indigo accent
  # the leaves request via ``background: #7c7aed``. The synthetic
  # adapter cannot read CSS-style backgrounds (the shim's tree API
  # has no ``getStyle``), but every leaf that paints the indigo
  # accent ALSO writes ``aria-pressed="true"`` (settings group rail,
  # filter chips) or ``data-active="true"`` (segmented controls) or
  # ``checked="checked"`` (toggle pill), so reading those attributes
  # is a cheap content-based signal that survives RPC across the
  # GPUI binding without a new C entry point.
  let ariaPressed =
    getAttribute(node, "aria-pressed") == "true" or
    getAttribute(node, "data-active") == "true"
  let toggleAttr = getAttribute(node, "data-toggle")
  let isToggle = toggleAttr == "true"
  let toggleOn = isToggle and getAttribute(node, "data-value") == "true"
  rects.add LayoutRect(node: node, x: x, y: y, w: w, h: h,
                       depth: depth, tag: tag, label: label,
                       ariaPressed: ariaPressed,
                       isToggle: isToggle, toggleOn: toggleOn)
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
    walkLayout(child, x + 4, cy, w - 8, ch, rects, depth + 1, maxDepth)
    cy += ch

proc buildLayoutRects*(root: GpuiElement; width, height: int):
                      seq[LayoutRect] =
  ## Public layout pass. Same depth heuristic ``renderFrame`` uses, so
  ## the rasteriser and the manifest builder share a single source of
  ## truth for per-node geometry.
  result = @[]
  if root == nil or width <= 0 or height <= 0: return
  walkLayout(root, 0, 0, width, height, result)

proc hitTestPath*(root: GpuiElement; width, height: int;
                  x, y: int): seq[GpuiElement] =
  ## EPP-M12. Resolve a click coordinate into an ordered chain of
  ## shadow-tree nodes that contain the point ``(x, y)`` — deepest
  ## leaf first, then each enclosing ancestor up to the root. The
  ## caller (the per-launcher ``GpuiInputSink``) fires ``"click"`` on
  ## every node in the chain so that whichever ancestor has the
  ## registered Nim closure handles the click. ``fireEvent`` is a
  ## no-op when the node has no listener for the dispatched event,
  ## so the walk-up is safe to apply unconditionally.
  ##
  ## The hit-test reuses ``buildLayoutRects`` — the same rectangle
  ## list the synthetic rasteriser paints from — so the rect that
  ## "owns" a pixel in the rendered frame is the rect that receives
  ## the click. This keeps the click target visibly tied to the
  ## pixel the user clicked on, independent of changes to the
  ## per-depth colour heuristic.
  result = @[]
  if root == nil or width <= 0 or height <= 0: return
  let rects = buildLayoutRects(root, width, height)
  # buildLayoutRects emits rectangles in DFS pre-order; iterating
  # back-to-front yields deepest-first hits.
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

proc renderSyntheticFrame(src: GpuiFrameSource): Frame
proc renderHeadlessFrame(src: GpuiFrameSource): Frame

proc renderFrame*(src: GpuiFrameSource): Frame =
  ## Walk the GPUI tree rooted at `src.root` and produce an RGBA8888
  ## frame of `src.width` × `src.height` pixels. Pure function w.r.t.
  ## the tree's current state — the same tree always yields the same
  ## pixel buffer (modulo a constant-time per-call advance: none).
  ##
  ## RS-M14 Phase 2: when the shim is built with `--features
  ## gpui-headless` AND the binary is compiled with
  ## `-d:useGpuiHeadless`, this proc routes through
  ## `gpui_render_to_pixels` to obtain real GPUI pixels via Zed's
  ## `HeadlessAppContext` + `Window::render_to_image`. Otherwise it
  ## falls back to the pre-RS-M14 synthetic vertical-stack raster (see
  ## `renderSyntheticFrame`). The fallback path is also used if the
  ## headless render returns an error code — this gives the editor a
  ## degraded but still-usable frame instead of a hard failure when
  ## the renderer can't run (e.g. Linux: the pinned Zed revision's
  ## `current_headless_renderer()` returns `None` on non-macOS, so
  ## the headless path bails out with error code 2 and we fall
  ## through to the synthetic stripes — RS-M14b owns the real Linux
  ## headless story).
  when defined(useGpuiHeadless):
    let frame = renderHeadlessFrame(src)
    if frame.pixels.len == src.width * src.height * 4:
      return frame
    # Fall through to synthetic on size mismatch / capture failure /
    # platform without a headless renderer — same defence as the
    # Rust-side `SizeMismatch` / `RendererUnavailable` error codes.
  renderSyntheticFrame(src)

proc renderHeadlessFrame(src: GpuiFrameSource): Frame =
  ## Drive the shim's `gpui_render_to_pixels` entry point to obtain
  ## RGBA8888 bytes from GPUI's real render pipeline (via Zed's
  ## `HeadlessAppContext::with_platform` + `Window::render_to_image`).
  ## The buffer is owned by the shim until `gpui_free_pixels` is
  ## called, so we copy it into a Nim seq before returning.
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
  # RS-M14 Phase 2: the headless `NimRootView` reads from the shim's
  # global `ROOT_NODE_ID`. The streaming adapter builds the tree through
  # the `GpuiRenderer.createElement` etc. API which does NOT route
  # through `gpui_launch` (the path that normally sets the root). So we
  # have to pin the root explicitly per frame — cheap, idempotent, and
  # mirrors the design pattern of the windowed launch path.
  gpui_bindings.gpui_set_root_element(src.root)
  var outPtr: ptr uint8
  var outLen: csize_t = 0
  let rc = gpui_bindings.gpui_render_to_pixels(
    cuint(w), cuint(h), cfloat(1.0),
    addr outPtr, addr outLen)
  if rc != 0 or outPtr.isNil or outLen == 0:
    # Headless render failed; caller falls back to synthetic.
    return Frame(kind: fkFull,
                 flags: FrameFlags(isDiff: false, isVideo: false),
                 width: w, height: h, pixels: @[])
  defer:
    gpui_bindings.gpui_free_pixels(outPtr, outLen)
  # EMC-M2 Option B (per ``Editor-Matrix-Closer.milestones.org``):
  # ``newSeqUninit[byte]`` skips the zero-init pass that the EMC-M1
  # audit measured at ~2.0-2.7 ms median (the bulk of the per-frame
  # "Nim alloc + copy" cost). The shim's ``copyMem`` writes every
  # byte immediately after, so the zero-init was always dead work.
  # The copy itself stays — the shim owns the returned buffer until
  # ``gpui_free_pixels`` runs, and the frame consumer caches the
  # full RGBA seq for the next-tick diff so we cannot hand the
  # shim pointer out directly.
  var pixels = newSeqUninit[byte](int(outLen))
  if pixels.len > 0:
    copyMem(addr pixels[0], outPtr, int(outLen))
  Frame(kind: fkFull,
        flags: FrameFlags(isDiff: false, isVideo: false),
        width: w, height: h, pixels: pixels)

proc renderSyntheticFrame(src: GpuiFrameSource): Frame =
  ## Pre-RS-M14 tree-derived synthetic raster. Kept as a fallback for
  ## hosts where the headless GPUI surface isn't available (e.g.
  ## Linux: the pinned Zed revision's headless renderer factory
  ## returns `None` on non-macOS) and as the default for builds that
  ## don't opt into `-d:useGpuiHeadless`. Documented behaviour:
  ## colour-codes each tree node and packs them into a vertical stack
  ## with a teal GPUI identifier band along the bottom edge.
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
      # Wave U-4: paint the brand indigo on nodes the leaves marked
      # active. Mirrors the leaf-set ``background: #7c7aed`` that the
      # synthetic adapter cannot otherwise observe (no ``getStyle``
      # on the shim's tree API). For toggle pills we additionally
      # paint the ON state in indigo and the OFF state in a darker
      # neutral so the toggle widget is visibly readable at preview
      # scale (the 36x20 pill from the round-10 polish was invisible
      # because the bare ``<div>`` tag colour matched the row
      # surface).
      if lr.ariaPressed:
        cr = 0x7C'u8; cg = 0x7A'u8; cb = 0xED'u8
        alpha = 0xFF'u8
      elif lr.isToggle:
        if lr.toggleOn:
          cr = 0x7C'u8; cg = 0x7A'u8; cb = 0xED'u8
        else:
          cr = 0x2A'u8; cg = 0x2A'u8; cb = 0x3A'u8
        alpha = 0xFF'u8
      fillRect(pixels, w, h, Rect(x: lr.x, y: lr.y, w: lr.w, h: lr.h,
                                  r: cr, g: cg, b: cb, a: alpha,
                                  label: lr.label))
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

# ---------------------------------------------------------------------------
# RS-M11b: element-tree manifest builder
# ---------------------------------------------------------------------------
##
## ``buildGpuiElementTreeManifest`` walks the same ``buildLayoutRects``
## pass the rasteriser uses, filters to nodes that carry a non-empty
## ``ComponentPathAttr`` value, and lifts each layout rect into an
## ``ElementEntry``. The ``id`` field mirrors ``componentPath`` (the
## TUI adapter pattern); the ``kind`` field reads ``ElementKindAttr``,
## falling back to the empty string when the leaf does not set one.
##
## Manifest bounds come from the same ``LayoutRect`` that drove the
## F-packet pixels — by construction the M-packet rectangles cannot
## drift from the visible content. ``surfaceWidth`` / ``surfaceHeight``
## mirror the configured ``(width, height)``.

proc buildGpuiElementTreeManifest*(root: GpuiElement;
                                   width, height: int;
                                   frameSeq: int = 0):
                                  ElementTreeManifest =
  ## Build a fresh manifest from the current state of the GPUI tree
  ## rooted at ``root``. Idempotent: same tree → same manifest, so
  ## the bridge can hash the result and skip emission when unchanged.
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

