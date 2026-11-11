## test_hello_frame_source — PSZ-M3 notes 20 and 21.
##
## The `hello` M packet carries `capabilities.frameSource` when a launcher
## declares its frame source, so the editor can label a preview whose frames
## are the synthetic raster. The test locks these:
##
##   * `buildHelloJson` emits `frameSource` exactly when the tag is non-empty
##     and omits it otherwise, so launchers that declare nothing keep the
##     legacy hello bytes.
##   * `frameSourceLabelFor` maps the frame a GPUI source last sent to its
##     label: "real" for a headless GPUI frame, "synthetic" otherwise (the
##     decision the label follows, note 21).
##   * `gpuiFrameSourceLabel` on a real GPUI source labels its frame. With
##     `-d:useGpuiHeadless` on Linux the headless render returns error code 2,
##     so the source falls back to the synthetic raster, and the label must say
##     so: this is the forced headless error that a macOS fallback would hit.
##     It needs the Rust shim built (`libgpui_nim_shim.so` on the loader path).
##
## No mocks: the JSON is built by the real encoder and parsed back with
## `std/json`; the GPUI source renders through the real renderer.

import std/[json, unittest]

import isonim_gpui/renderer
import isonim_gpui/bindings as gpui_bindings

import isonim_render_serve
import isonim_render_serve/adapters/gpui_adapter

suite "PSZ-M3 notes 20-21: hello carries the frame-source label":

  test "a declared synthetic tag is emitted as capabilities.frameSource":
    let hello = parseJson(buildHelloJson("gpui", 800, 600,
                                         frameSourceTag = "synthetic"))
    check hello["type"].getStr() == "hello"
    check hello["capabilities"].hasKey("frameSource")
    check hello["capabilities"]["frameSource"].getStr() == "synthetic"

  test "no tag leaves the hello capability bag unchanged":
    let hello = parseJson(buildHelloJson("gpui", 800, 600))
    check not hello["capabilities"].hasKey("frameSource")

  test "the label is real only for a headless GPUI frame":
    check frameSourceLabelFor(true) == "real"
    check frameSourceLabelFor(false) == "synthetic"

  test "a GPUI source labels the frame it actually sends":
    gpui_bindings.gpui_reset_tree()
    let r = GpuiRenderer()
    let root = r.createElement("div")
    let label = r.createElement("p")
    r.setTextContent(label, "hello")
    r.appendChild(root, label)
    let fs = newGpuiFrameSource(r, root, width = 64, height = 48)
    let frame = fs.renderFrame()
    check frame.pixels.len == 64 * 48 * 4
    let declared = fs.gpuiFrameSourceLabel()
    when defined(useGpuiHeadless) and not defined(macosx):
      # Forced headless error: no Linux headless renderer, so the frame is the
      # synthetic raster and the hello must not claim a headless frame.
      check fs.servedHeadless == false
      check declared == "synthetic"
    else:
      check declared == frameSourceLabelFor(fs.servedHeadless)

suite "PSZ-M3 note 22: the per-tick frame label of a GPUI source":

  test "currentFrameSourceLabelImpl reports the last frame's label without rendering":
    gpui_bindings.gpui_reset_tree()
    let r = GpuiRenderer()
    let root = r.createElement("div")
    let fs = newGpuiFrameSource(r, root, width = 16, height = 12)
    let any = fs.toAny()
    # Nothing is rendered yet, so the source reports the label of its last
    # frame as the fallback default; reading it must not render (the bridge
    # reads it on every tick).
    check any.currentFrameSourceLabelImpl != nil
    check any.currentFrameSourceLabelImpl() == frameSourceLabelFor(fs.servedHeadless)
    check fs.servedHeadless == false
    check any.currentFrameSourceLabelImpl() == "synthetic"
