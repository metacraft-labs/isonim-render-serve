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

import std/[hashes, os]

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
    # EMC2-M1 async pipeline state. The headless renderer is moved
    # off the bridge's ``frameLoop`` thread onto a dedicated worker
    # thread inside the shim; the bridge submits frame N+1 on tick
    # N and tries to take frame N-1 from the worker on the same
    # tick. If frame N-1 isn't ready, the bridge re-emits the
    # previous frame (smoother than blocking ~41 ms inside the FFI
    # body). On the very first tick the bridge has to wait for the
    # first token to complete so the client gets a real initial
    # frame; subsequent ticks are non-blocking.
    pendingToken*: cuint      ## In-flight token, or 0 when none.
    lastFramePixels*: seq[byte]  ## Cached last full RGBA so we
                                 ## can re-emit when a poll says
                                 ## Pending.
    asyncPrimed*: bool        ## ``true`` after the first
                              ## ``renderHeadlessFrame`` call
                              ## successfully submitted a token.
    asyncDisabled*: bool      ## Latches when the async path
                              ## reports an unrecoverable error
                              ## (e.g. RendererUnavailable on
                              ## Linux); subsequent calls fall
                              ## through to the synchronous
                              ## ``gpui_render_to_pixels`` path
                              ## without re-trying the worker.

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
proc renderHeadlessFrameSync(src: GpuiFrameSource): Frame
proc copyShimBufferToFrame(src: GpuiFrameSource;
                           outPtr: ptr uint8; outLen: csize_t): Frame
proc lastFrameOrSynthetic(src: GpuiFrameSource): Frame

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

proc copyShimBufferToFrame(src: GpuiFrameSource;
                           outPtr: ptr uint8; outLen: csize_t): Frame =
  ## Shared helper: copy a shim-owned RGBA buffer into a Nim seq and
  ## wrap it as a Frame. Caches the bytes on ``src.lastFramePixels``
  ## so a future Pending poll can re-emit them.
  var pixels = newSeqUninit[byte](int(outLen))
  if pixels.len > 0:
    copyMem(addr pixels[0], outPtr, int(outLen))
  src.lastFramePixels = pixels
  Frame(kind: fkFull,
        flags: FrameFlags(isDiff: false, isVideo: false),
        width: src.width, height: src.height, pixels: pixels)

proc lastFrameOrSynthetic(src: GpuiFrameSource): Frame =
  ## When an async poll says Pending and we have no prior frame to
  ## re-emit, fall back to a zero-length Frame so ``renderFrame``'s
  ## "size mismatch → synthetic raster" defence kicks in. This
  ## happens only on the very first tick (where the worker has not
  ## finished its first render yet); subsequent ticks have a cached
  ## ``lastFramePixels`` to re-emit.
  if src.lastFramePixels.len == src.width * src.height * 4:
    Frame(kind: fkFull,
          flags: FrameFlags(isDiff: false, isVideo: false),
          width: src.width, height: src.height,
          pixels: src.lastFramePixels)
  else:
    Frame(kind: fkFull,
          flags: FrameFlags(isDiff: false, isVideo: false),
          width: src.width, height: src.height, pixels: @[])

proc renderHeadlessFrameSync(src: GpuiFrameSource): Frame =
  ## Synchronous fallback path. Drives the pre-EMC2-M1
  ## ``gpui_render_to_pixels`` entry point on the calling thread.
  ## Used as a one-shot recovery when the async worker reports an
  ## unrecoverable error (e.g. RendererUnavailable on Linux) and
  ## also by the test suite that wants deterministic, blocking
  ## semantics.
  let w = src.width
  let h = src.height
  if w <= 0 or h <= 0:
    return Frame(kind: fkFull,
                 flags: FrameFlags(isDiff: false, isVideo: false),
                 width: w, height: h, pixels: @[])
  gpui_bindings.gpui_set_root_element(src.root)
  var outPtr: ptr uint8
  var outLen: csize_t = 0
  let rc = gpui_bindings.gpui_render_to_pixels(
    cuint(w), cuint(h), cfloat(1.0),
    addr outPtr, addr outLen)
  if rc != 0 or outPtr.isNil or outLen == 0:
    return Frame(kind: fkFull,
                 flags: FrameFlags(isDiff: false, isVideo: false),
                 width: w, height: h, pixels: @[])
  defer:
    gpui_bindings.gpui_free_pixels(outPtr, outLen)
  copyShimBufferToFrame(src, outPtr, outLen)

proc renderHeadlessFrame(src: GpuiFrameSource): Frame =
  ## EMC2-M1: pipelined async path.
  ##
  ## On each tick the bridge thread does at most three FFI calls:
  ##   1. ``gpui_set_root_element`` (cheap; pin the root for the
  ##      worker's next render-cycle).
  ##   2. ``gpui_render_try_take(pendingToken, ...)`` — non-blocking
  ##      poll for the bytes the worker computed since the prior
  ##      tick.
  ##   3. ``gpui_render_submit_async(...)`` — enqueue the next
  ##      render request; returns a new token immediately.
  ##
  ## The result of step 2 is what we emit on this tick. The result
  ## of step 3 is what we'll emit on the NEXT tick. By the time the
  ## bridge re-enters this proc, the worker has been computing for
  ## one full tick (~20-50 ms depending on cadence), so the next
  ## try-take is typically Ready.
  ##
  ## Bootstrapping: on the very first call we have no pending token
  ## to take from, so we submit + block until the first frame is
  ## ready, then submit the second frame and return the first one's
  ## bytes. This pays the 41 ms cost ONCE on connection setup
  ## instead of every frame.
  ##
  ## Fallback: if the worker reports an unrecoverable error
  ## (RendererUnavailable, Panic) we latch ``asyncDisabled`` and
  ## route the rest of the connection through the synchronous
  ## ``gpui_render_to_pixels`` path. This preserves the EMC-M5
  ## degradation story on Linux where the worker can't run.
  let w = src.width
  let h = src.height
  if w <= 0 or h <= 0:
    return Frame(kind: fkFull,
                 flags: FrameFlags(isDiff: false, isVideo: false),
                 width: w, height: h, pixels: @[])
  if src.asyncDisabled:
    return renderHeadlessFrameSync(src)

  # The headless ``NimRootView`` reads from the shim's global
  # ``ROOT_NODE_ID``. Pinning per tick is idempotent and cheap;
  # the worker thread observes the global at the start of each
  # render cycle.
  gpui_bindings.gpui_set_root_element(src.root)

  # --- Step 1: take the previous tick's render (if any) ---
  var emitFrame: Frame
  var haveFrameToEmit = false
  if src.pendingToken != 0'u32:
    var outPtr: ptr uint8
    var outLen: csize_t = 0
    let rc = gpui_bindings.gpui_render_try_take(
      src.pendingToken, addr outPtr, addr outLen)
    if rc == gpui_bindings.GpuiRenderTakeReady:
      defer:
        gpui_bindings.gpui_free_pixels(outPtr, outLen)
      if not outPtr.isNil and outLen > 0:
        emitFrame = copyShimBufferToFrame(src, outPtr, outLen)
        haveFrameToEmit = true
      src.pendingToken = 0'u32
    elif rc == gpui_bindings.GpuiRenderTakePending:
      # Worker hasn't finished the previous request yet — re-emit
      # the last cached frame this tick. The token stays alive;
      # the next tick polls it again.
      emitFrame = lastFrameOrSynthetic(src)
      haveFrameToEmit = true
    elif rc == gpui_bindings.GpuiRenderTakeUnknownToken:
      # Worker forgot the token (shouldn't happen, but be defensive).
      src.pendingToken = 0'u32
    else:
      # Negative error code: -1..-6 (negation of ErrorCode). On
      # RendererUnavailable (-2) the worker can never recover, so
      # latch the fallback. Other errors might be transient
      # (CaptureFailed under GPU pressure); we still latch to
      # avoid livelock — the sync path either succeeds or the
      # outer ``renderFrame`` falls through to synthetic.
      src.pendingToken = 0'u32
      src.asyncDisabled = true
      return renderHeadlessFrameSync(src)

  # --- Step 2: submit the next render ---
  let newToken = gpui_bindings.gpui_render_submit_async(
    cuint(w), cuint(h), cfloat(1.0))
  if newToken == 0'u32:
    # Worker thread is down (extremely rare). Fall back to sync
    # for this tick and latch so we stop trying.
    src.asyncDisabled = true
    if haveFrameToEmit:
      return emitFrame
    return renderHeadlessFrameSync(src)
  src.pendingToken = newToken

  # --- Step 3: bootstrap or return ---
  if haveFrameToEmit:
    return emitFrame

  # First-call bootstrap: block until the just-submitted token
  # completes so we emit a real first frame instead of an empty
  # one. The block happens ONCE per connection, not per frame.
  # We poll instead of blocking on a condvar because that gives
  # the bridge's other in-flight asyncdispatch tasks a chance to
  # run (sleepAsync yields back to the event loop).
  if not src.asyncPrimed:
    src.asyncPrimed = true
    # Bound the bootstrap wait at ~2 s so a stuck worker doesn't
    # hang the connection forever; that's well above the
    # measured 41 ms first-render cost and within the bridge's
    # hello-handshake timeout.
    const maxBootstrapPollsMs = 2000
    const pollIntervalMs = 5
    var elapsed = 0
    while elapsed < maxBootstrapPollsMs:
      var outPtr: ptr uint8
      var outLen: csize_t = 0
      let rc = gpui_bindings.gpui_render_try_take(
        src.pendingToken, addr outPtr, addr outLen)
      if rc == gpui_bindings.GpuiRenderTakeReady:
        defer:
          gpui_bindings.gpui_free_pixels(outPtr, outLen)
        src.pendingToken = 0'u32
        if not outPtr.isNil and outLen > 0:
          let f = copyShimBufferToFrame(src, outPtr, outLen)
          # Submit ahead for the next tick so the pipeline is
          # primed when the bridge's frameLoop comes back around.
          let nt = gpui_bindings.gpui_render_submit_async(
            cuint(w), cuint(h), cfloat(1.0))
          src.pendingToken = nt
          return f
        break
      elif rc == gpui_bindings.GpuiRenderTakePending:
        # Busy-wait a few ms; this is the bootstrap path only.
        sleep(pollIntervalMs)
        elapsed += pollIntervalMs
        continue
      else:
        # Worker failure during bootstrap → fall back.
        src.pendingToken = 0'u32
        src.asyncDisabled = true
        return renderHeadlessFrameSync(src)
    # Bootstrap timed out — fall through to synthetic for this
    # tick (caller sees empty-pixels Frame and uses the
    # synthetic raster) without disabling the async path
    # forever (timeout might be transient).

  # We have nothing to emit yet — caller falls through to synthetic.
  Frame(kind: fkFull,
        flags: FrameFlags(isDiff: false, isVideo: false),
        width: w, height: h, pixels: @[])

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

