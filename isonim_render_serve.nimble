# Package
version       = "0.1.0"
author        = "Metacraft Labs"
description   = "WebSocket bridge for the IsoNim render-stream protocol — host a FrameSource and stream F/M/I packets to a browser canvas"
license       = "MIT"
srcDir        = "src"
bin           = @["isonim_render_serve"]

# Dependencies
requires "nim >= 2.0.0"
