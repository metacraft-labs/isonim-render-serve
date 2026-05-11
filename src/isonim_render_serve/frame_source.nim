## `AnyFrameSource` — closure-based polymorphic wrapper over the
## `FrameSource` concept.
##
## Background. RS-M0 froze the `FrameSource` shape as a static Nim
## concept (see `stub_frame_source.nim`):
##
##   FrameSource = concept fs
##     fs.renderFrame() is Frame
##     fs.close()
##
## RS-M1 shipped the bridge skeleton with `BridgeConfig.frameSource`
## typed as the concrete `StubFrameSource`. RS-M2 introduces the
## first real adapter (GPUI) and needs the bridge to consume either
## the stub or any of the real adapters without code changes inside
## `bridge.nim`.
##
## Concepts are great at the *static* level (compile-time
## dispatch, no boxing) but the bridge holds the source inside a
## `BridgeConfig` *value* that crosses module boundaries — the
## natural fit there is dynamic dispatch with the closure pattern
## (`renderFrame: proc(): Frame`). The trade-off is one indirect
## call per frame, which is negligible at the F-packet cadence
## (typically 20–60 Hz).
##
## Adapter authors construct an `AnyFrameSource` via the
## `wrapFrameSource` helper, which takes a concrete source plus its
## reported `(width, height)` (the bridge ships those in the `hello`
## M packet's `initialSize` field) and produces the closure-backed
## wrapper. The stub source is exposed the same way via
## `stub_frame_source.toAny`.
##
## RS-M3 will add a `lastFrame` snapshot to the wrapper so the
## diff-region pass can compare successive frames without forcing
## every adapter to retain its own copy.

import ./packet

type
  AnyFrameSource* = ref object
    ## Polymorphic handle held by `BridgeConfig.frameSource`. Dispatch
    ## is via the two embedded closures; the rendered dimensions are
    ## cached on the wrapper so the bridge's `hello` builder can read
    ## them without calling `renderFrame` first.
    ##
    ## The closures are tagged `gcsafe` so the bridge's
    ## `--threads:on` build passes `serve`'s gcsafe pragma check.
    ## Concrete adapters must keep their per-source state in
    ## thread-safe form (the bridge dispatcher runs everything on a
    ## single async event loop, so this is a soft constraint in
    ## practice — but the type signature still demands it).
    width*, height*: int
    renderFrameImpl*: proc(): Frame {.closure, gcsafe.}
    closeImpl*: proc() {.closure, gcsafe.}

proc newAnyFrameSource*(width, height: int;
                        renderFrameImpl: proc(): Frame {.closure, gcsafe.};
                        closeImpl: proc() {.closure, gcsafe.}): AnyFrameSource =
  ## Construct a wrapper from raw closures. Adapter modules use the
  ## generic `wrapFrameSource` helper below; this raw entry point is
  ## exported for unit tests that want to fabricate a fake source
  ## without writing a full adapter.
  AnyFrameSource(width: width, height: height,
                 renderFrameImpl: renderFrameImpl,
                 closeImpl: closeImpl)

proc renderFrame*(s: AnyFrameSource): Frame =
  ## Polymorphic dispatch: hand off to the wrapped adapter.
  s.renderFrameImpl()

proc close*(s: AnyFrameSource) =
  if s.closeImpl != nil:
    s.closeImpl()

proc wrapFrameSource*[T](source: T; width, height: int): AnyFrameSource =
  ## Generic wrapper: capture `source` in two closures that satisfy
  ## the `AnyFrameSource` shape. Works against any value that
  ## satisfies the static `FrameSource` concept (i.e. has
  ## `renderFrame()` returning `Frame` and `close()`).
  let captured = source
  AnyFrameSource(
    width: width,
    height: height,
    renderFrameImpl: proc(): Frame {.gcsafe.} =
      {.cast(gcsafe).}: captured.renderFrame(),
    closeImpl: proc() {.gcsafe.} =
      {.cast(gcsafe).}: captured.close())
