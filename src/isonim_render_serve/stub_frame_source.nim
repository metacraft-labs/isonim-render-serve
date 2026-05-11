## Stub `FrameSource` — an animated gradient generator that proves
## the streaming protocol end-to-end. Implements the same shape as
## the per-back-end adapters that ship at RS-M2..M6, but with zero
## external dependencies.
##
## The gradient is a function of `(x, y, tick)`:
##
##   R = (x + tick) mod 256
##   G = (y + tick) mod 256
##   B = (x + y + tick * 2) mod 256
##   A = 0xFF
##
## At RS-M0 the per-back-end capture-path table picks "in-process
## pixel pull (animated gradient)" for the stub. RS-M1 ships this
## generator behind the `FrameSource` concept so the bridge can
## point at a real renderer (RS-M2's GPUI adapter) without touching
## the bridge code.

import ./packet
import ./frame_source

type
  StubFrameSource* = ref object
    width*, height*: int
    tick*: int

proc newStubFrameSource*(width = 256; height = 256): StubFrameSource =
  ## Construct a stub source with the canonical 256x256 size used by
  ## the RS-M1 deliverable.
  StubFrameSource(width: width, height: height, tick: 0)

proc renderFrame*(s: StubFrameSource): Frame =
  ## Generate the current frame and bump the internal tick counter
  ## so the next call yields the next animation step. Returns a full
  ## (non-diff) `Frame` per RS-M1's "in-process pixel pull" path.
  let w = s.width
  let h = s.height
  let tick = s.tick
  var pixels = newSeq[byte](w * h * 4)
  for y in 0 ..< h:
    for x in 0 ..< w:
      let off = (y * w + x) * 4
      pixels[off] = byte((x + tick) and 0xFF)
      pixels[off + 1] = byte((y + tick) and 0xFF)
      pixels[off + 2] = byte((x + y + tick * 2) and 0xFF)
      pixels[off + 3] = 0xFF'u8
  s.tick += 1
  result = Frame(kind: fkFull,
                 flags: FrameFlags(isDiff: false, isVideo: false),
                 width: w, height: h, pixels: pixels)

proc close*(s: StubFrameSource) =
  ## No-op for the in-process stub; satisfies the `FrameSource.close`
  ## requirement so adapters can be swapped without bridge changes.
  discard

# ---------------------------------------------------------------------------
# Static `FrameSource` concept check
# ---------------------------------------------------------------------------

type
  FrameSource* = concept fs
    fs.renderFrame() is Frame
    fs.close()

# ---------------------------------------------------------------------------
# Polymorphic wrapper
# ---------------------------------------------------------------------------

proc toAny*(s: StubFrameSource): AnyFrameSource =
  ## Wrap the stub in a closure-backed `AnyFrameSource` so it can be
  ## dropped into `BridgeConfig.frameSource` alongside real adapters
  ## (e.g. RS-M2's GPUI source). The wrapper carries the stub's
  ## current `(width, height)` so the bridge's `hello` builder can
  ## read the initial size without calling `renderFrame`.
  let captured = s
  newAnyFrameSource(s.width, s.height,
    renderFrameImpl = proc(): Frame {.gcsafe.} =
      {.cast(gcsafe).}: captured.renderFrame(),
    closeImpl = proc() {.gcsafe.} =
      {.cast(gcsafe).}: captured.close())
