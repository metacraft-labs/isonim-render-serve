# isonim-render-serve

WebSocket bridge for the IsoNim *render-stream* protocol. Hosts a
`FrameSource` and streams `F` / `M` / `I` packets to a browser-side
`<canvas>` client.

## What this library does

- Hand-rolled RFC 6455 WebSocket framing
  (`src/isonim_render_serve/ws_frame.nim`).
- Self-contained packet codec
  (`src/isonim_render_serve/packet.nim`) implementing the exact
  wire format locked at RS-M0:
  - `F` (Frame) = `'F' | u8 flags | u32 LE width | u32 LE height |
    u32 LE length | payload`. Full-frame payload is `width*height*4`
    bytes of RGBA8888 row-major; diff payload is
    `u32 count + count × { u32 x, u32 y, u32 w, u32 h, u32 length,
    RGBA bytes }`.
  - `M` (Meta) = `'M' | u32 LE length | UTF-8 JSON`. Types: `hello`,
    `resize`, `screenshot-request`, `screenshot-response`,
    `hot-reload`.
  - `I` (Input) = `'I' | u32 LE length | UTF-8 JSON`. Types: `key`,
    `mouse`, `scroll`, `resize`, `focus`.
- One-process bridge: launch a `FrameSource` (in-process stub or
  child adapter), send an initial `hello` `M`, then push frames as
  `F` packets and route incoming `I` packets to the `InputSink`.
- Reference HTML/JS in `static/` that connects via WebSocket,
  renders received frames via `canvas.putImageData`, and forwards
  DOM events as `I` packets.

## Status (RS-M1)

This repo lands at the RS-M1 milestone of the
`isonim-render-stream.status.org` series in the `codetracer-specs`
repo. The wire protocol is *locked* at RS-M0; RS-M1 ships the
bridge skeleton plus a stub `FrameSource` (animated gradient) that
proves the protocol end-to-end. The first real-back-end adapter
(GPUI) lands at RS-M2; Freya at RS-M4; diff-region encoding at
RS-M3.

The WebSocket framing is vendored from `isonim-tui-serve` per the
RS-M0 decision ("vendor first; promote to a shared core library
iff a third consumer appears"); the packet codec is brand-new
because the wire shape (F/M/I) differs from the TUI bridge's
D/M/P shape.

## Commands

```sh
just build           # compile the bridge + every test as a smoke check
just test            # run the integration suite
just lint            # nim check + nixfmt --check
just format          # nimpretty + nixfmt
```

## Project structure

```text
src/
  isonim_render_serve.nim                # public top-level (CLI + facade)
  isonim_render_serve/ws_frame.nim       # RFC 6455 frame codec (vendored)
  isonim_render_serve/packet.nim         # F/M/I packet codec
  isonim_render_serve/stub_frame_source.nim  # animated gradient source
  isonim_render_serve/bridge.nim         # WS server + hello/F/M/I loop
  isonim_render_serve/event_dispatch.nim # InputEvent + I JSON decode
tests/
  test_packet_codec_roundtrip.nim        # F/M/I codec round-trip
  test_ws_frame_codec.nim                # RFC 6455 codec round-trip
  test_bridge_hello_first.nim            # first M is hello
  test_bridge_stub_frame_source.nim      # stub gradient delivers frames
  test_bridge_input_roundtrip.nim        # client I -> server InputSink
  test_protocol_violation_close.nim      # WS code 1002 on violation
static/
  index.html                             # canvas client + input forwarding
.github/workflows/ci.yml                 # lint + test
flake.nix                                # nix devShell
Justfile                                 # build/test/lint/format
isonim_render_serve.nimble               # single-source-of-truth version
```

## Specs

The authoritative spec for this library is the RS-M0 / RS-M1
entries in
`Front-Ends/IsoNim/isonim-render-stream.status.org` in the
`codetracer-specs` repo, specifically the § *Architecture sketch —
render streaming* section (byte-exact wire protocol, `FrameSource`
/ `InputSink` concept signatures, capability bag schema). Repo-
level conformance is governed by
`metacraft-specs/policies/repo-requirements.md`.

## Running locally

```sh
# 1. Build the bridge.
nim c -d:release -o:isonim-render-serve src/isonim_render_serve.nim

# 2. Start the bridge with the stub gradient frame source.
./isonim-render-serve --port 8765 --static static

# 3. Open http://localhost:8765/ in a browser.
```
