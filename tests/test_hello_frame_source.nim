## test_hello_frame_source — PSZ-M3 note 20.
##
## The `hello` M packet carries `capabilities.frameSource` when a launcher
## declares its frame source, so the editor can label a preview whose frames
## are the synthetic raster. The test locks two things:
##
##   * `buildHelloJson` emits `frameSource` exactly when the tag is non-empty
##     and omits it otherwise, so launchers that declare nothing keep the
##     legacy hello bytes.
##   * `gpuiFrameSourceTag` declares "synthetic" on every build that cannot
##     produce a headless GPUI frame (everything but macOS with
##     `-d:useGpuiHeadless`). The compile-time branch is the code under test,
##     so the test asserts the tag this build's defines select.
##
## No mocks: the JSON is built by the real encoder and parsed back with
## `std/json`.

import std/[json, unittest]

import isonim_render_serve
import isonim_render_serve/adapters/gpui_adapter

suite "PSZ-M3 note 20: hello carries the frame-source label":

  test "a declared synthetic tag is emitted as capabilities.frameSource":
    let hello = parseJson(buildHelloJson("gpui", 800, 600,
                                         frameSourceTag = "synthetic"))
    check hello["type"].getStr() == "hello"
    check hello["capabilities"].hasKey("frameSource")
    check hello["capabilities"]["frameSource"].getStr() == "synthetic"

  test "no tag leaves the hello capability bag unchanged":
    let hello = parseJson(buildHelloJson("gpui", 800, 600))
    check not hello["capabilities"].hasKey("frameSource")

  test "the GPUI adapter declares synthetic unless it is a macOS headless build":
    when defined(useGpuiHeadless) and defined(macosx):
      check gpuiFrameSourceTag() == ""
    else:
      check gpuiFrameSourceTag() == "synthetic"
