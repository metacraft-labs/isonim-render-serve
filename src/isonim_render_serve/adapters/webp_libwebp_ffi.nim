## FUH-M5 — libwebp FFI binding for in-process WebP-lossless encoding.
##
## Mirrors the EPP-M5 ``capture_videotoolbox.nim`` shape: opaque
## handle (here, a stack-allocated config + heap-allocated picture),
## RGBA-in / bytes-out, host-capability probe, transparent fallback
## via the caller when the dynlib lookup fails. Replaces the ~133 ms
## ffmpeg subprocess spawn (FUH-M4 audit § 5) with a direct API call
## landing under the 16 ms 60 FPS budget at 1280×800 cl=3.
##
## Symbol surface lifted directly from
## ``/nix/store/.../libwebp-1.6.0/include/webp/encode.h`` per the
## FUH-M4 audit § 1.5. The encoder ABI version is 0x0210, shared
## between libwebp 1.5.0 and 1.6.0 (and any subsequent ABI-stable
## release); the ``WebPConfigInitInternal`` / ``WebPPictureInitInternal``
## entry points refuse the call with return value 0 on mismatch
## (audit § 6.3) so a future ABI bump fails closed rather than
## silently corrupting bytes.
##
## Backend selection at the encoder facade is the caller's job —
## this module's responsibility is the FFI + a probe that says
## "this host can or cannot load libwebp.dylib". When the dynlib is
## missing at runtime the probe returns false and the facade should
## fall back to the subprocess path; the launcher binary never
## crashes from a missing dynlib because Nim's ``{.dynlib.}``
## resolution is lazy (deferred to first call), and we wrap that
## first call in the probe below.

import std/[dynlib, strutils]

const
  WEBP_ENCODER_ABI_VERSION* = 0x0210'i32
    ## Matches libwebp 1.5.0 / 1.6.0; passed to the *Internal init
    ## entry points.
  WEBP_PRESET_DEFAULT* = 0'i32
    ## ``WebPPreset`` value used by the inline ``WebPConfigInit``.
  WEBP_MAX_DIMENSION* = 16383
    ## Per the encode.h ``WEBP_MAX_DIMENSION`` macro; callers that
    ## attempt to encode beyond this raise upstream rather than
    ## silently producing a corrupt RIFF.

# ---------------------------------------------------------------------------
# Dynlib path discovery
# ---------------------------------------------------------------------------
#
# macOS's SIP strips ``DYLD_*`` environment variables from child
# processes, so the dev-shell's ``DYLD_FALLBACK_LIBRARY_PATH`` does
# NOT reach ``nim c -r``-launched test binaries. We therefore resolve
# the libwebp path at compile time via ``pkg-config`` (the dev shell
# provides ``PKG_CONFIG_PATH`` pointing at the libwebp.pc file) and
# bake the absolute Nix-store path into the ``{.dynlib.}`` pragma.
# On a host without pkg-config we fall back to the bare SONAME which
# works on Linux (LD_LIBRARY_PATH is honored) and on macOS hosts that
# install libwebp via Homebrew (its ``/opt/homebrew/lib`` lands on the
# default dyld search path).

const
  pkgConfigLibDir =
    when defined(macosx) or defined(linux):
      staticExec("pkg-config --variable=libdir libwebp 2>/dev/null").strip()
    else:
      ""

  defaultDynlibName =
    when defined(macosx): "libwebp.dylib"
    elif defined(linux): "libwebp.so.7"
    else: "libwebp"

  libwebpName =
    when pkgConfigLibDir.len > 0:
      pkgConfigLibDir & "/" & defaultDynlibName
    else:
      defaultDynlibName

# ---------------------------------------------------------------------------
# Struct layouts
# ---------------------------------------------------------------------------
#
# WebPConfig and WebPPicture are USER-ALLOCATED in the libwebp API —
# the caller passes a pointer to a stack/heap struct the library
# fills in. We must therefore match the C layout exactly.
#
# The structs are reproduced verbatim from
# ``include/webp/encode.h`` (libwebp 1.6.0). C ``int`` and ``float``
# are 32-bit on every platform Nim supports; ``size_t`` and pointers
# are word-sized; ``uint32_t`` arrays are inlined.

type
  WebPConfig* {.bycopy.} = object
    ## Compression knobs. The caller calls ``WebPConfigInit`` (or the
    ## lossless preset) immediately after stack-allocating this; the
    ## library writes the defaults into every field.
    lossless: cint            ## 1 = VP8L (we always set 1)
    quality: cfloat           ## lossless: effort 0..100
    `method`: cint            ## 0..6 — speed/size tradeoff
    image_hint: cint          ## WebPImageHint enum
    target_size: cint
    target_PSNR: cfloat
    segments: cint
    sns_strength: cint
    filter_strength: cint
    filter_sharpness: cint
    filter_type: cint
    autofilter: cint
    alpha_compression: cint
    alpha_filtering: cint
    alpha_quality: cint
    pass: cint
    show_compressed: cint
    preprocessing: cint
    partitions: cint
    partition_limit: cint
    emulate_jpeg_size: cint
    thread_level: cint
    low_memory: cint
    near_lossless: cint
    exact: cint               ## 1 = preserve transparent RGB
    use_delta_palette: cint
    use_sharp_yuv: cint
    qmin: cint
    qmax: cint

  WebPMemoryWriter* {.bycopy.} = object
    ## Output buffer the library appends bytes to. ``mem`` owned by
    ## the library; ``WebPMemoryWriterClear`` frees it.
    mem: ptr UncheckedArray[byte]
    size: csize_t
    max_size: csize_t
    pad: array[1, uint32]

  WebPPicture* {.bycopy.} = object
    ## Main input/output struct. We only touch ``use_argb``, ``width``,
    ## ``height``, ``writer`` and ``custom_ptr``; everything else is
    ## opaque padding kept here so the layout matches the C definition
    ## byte-for-byte. Order MUST stay in lockstep with encode.h.
    # INPUT — selector
    use_argb: cint
    # INPUT — YUV (unused; lossless takes ARGB)
    colorspace: cint
    width: cint
    height: cint
    y, u, v: pointer
    y_stride, uv_stride: cint
    a: pointer
    a_stride: cint
    pad1: array[2, uint32]
    # INPUT — ARGB (lossless path)
    argb: pointer
    argb_stride: cint
    pad2: array[3, uint32]
    # OUTPUT
    writer: pointer            ## WebPWriterFunction
    custom_ptr: pointer
    # OUTPUT — extra info (unused for lossless)
    extra_info_type: cint
    extra_info: pointer
    # STATS
    stats: pointer
    error_code: cint
    progress_hook: pointer
    user_data: pointer
    pad3: array[3, uint32]
    pad4, pad5: pointer
    pad6: array[8, uint32]
    # PRIVATE — match the C ``memory_`` / ``memory_argb_`` trailing
    # underscores. Nim disallows trailing underscores in identifiers,
    # so we drop them on the Nim side; the layout is positional so
    # the names are only for human reference.
    memoryRaw: pointer       ## C: ``memory_``
    memoryArgbRaw: pointer   ## C: ``memory_argb_``
    pad7: array[2, pointer]

# ---------------------------------------------------------------------------
# FFI declarations
# ---------------------------------------------------------------------------

{.push importc, cdecl, dynlib: libwebpName.}

proc WebPGetEncoderVersion*(): cint
  ## Returns e.g. 0x010600 for libwebp 1.6.0. Cheap probe — the
  ## runtime-availability check below loads the dynlib by calling
  ## this; if the dynlib is missing the dynlib pragma raises an
  ## ``OSError`` / ``LibraryError`` that the probe catches.

proc WebPConfigInitInternal(config: ptr WebPConfig; preset: cint;
                             quality: cfloat; abiVersion: cint): cint

proc WebPConfigLosslessPreset*(config: ptr WebPConfig; level: cint): cint

proc WebPValidateConfig*(config: ptr WebPConfig): cint

proc WebPPictureInitInternal(pic: ptr WebPPicture; abiVersion: cint): cint

proc WebPPictureFree*(pic: ptr WebPPicture)

proc WebPPictureImportRGBA*(pic: ptr WebPPicture;
                             rgba: ptr UncheckedArray[byte];
                             stride: cint): cint

proc WebPMemoryWriterInit*(writer: ptr WebPMemoryWriter)

proc WebPMemoryWriterClear*(writer: ptr WebPMemoryWriter)

proc WebPMemoryWrite*(data: ptr UncheckedArray[byte]; size: csize_t;
                       pic: ptr WebPPicture): cint

proc WebPEncode*(config: ptr WebPConfig; pic: ptr WebPPicture): cint

proc WebPFree*(p: pointer)

# Decoder (used by the parity / lifecycle tests so the launcher
# doesn't need a separate ffmpeg call to verify lossless contract).
proc WebPDecodeRGBA*(data: ptr UncheckedArray[byte]; dataSize: csize_t;
                      width, height: ptr cint): ptr UncheckedArray[byte]

{.pop.}

# ---------------------------------------------------------------------------
# Inline helpers (mirror the C ``static inline`` wrappers)
# ---------------------------------------------------------------------------

proc webPConfigInit*(config: ptr WebPConfig): cint =
  ## Initialise a ``WebPConfig`` with the library defaults. Matches
  ## the C header's ``static inline WebPConfigInit`` which is the
  ## canonical entry point but isn't exported as a real symbol.
  WebPConfigInitInternal(config, WEBP_PRESET_DEFAULT, 75.0'f32,
                         WEBP_ENCODER_ABI_VERSION)

proc webPPictureInit*(pic: ptr WebPPicture): cint =
  ## Mirror of the C header's ``static inline WebPPictureInit``.
  WebPPictureInitInternal(pic, WEBP_ENCODER_ABI_VERSION)

# ---------------------------------------------------------------------------
# Runtime availability probe
# ---------------------------------------------------------------------------

var
  probedAvail = false       ## becomes true after the first probe call
  probedAvailResult = false ## cached "is libwebp loadable + working"

proc isLibwebpAvailable*(): bool =
  ## Probe whether libwebp's encoder is reachable at runtime. Calls
  ## ``WebPGetEncoderVersion`` once and caches the result. A missing
  ## dynlib raises (Nim's ``{.dynlib.}`` resolution is lazy — the
  ## raise happens on first symbol use, not at module load) and we
  ## swallow the exception so the caller can fall back to the
  ## subprocess path.
  ##
  ## Returns ``true`` when:
  ##
  ## * ``libwebp.dylib`` (macOS) / ``libwebp.so.7`` (Linux) resolves
  ##   at the compile-time-baked path, OR a search-path fallback
  ##   succeeds (Homebrew / system / ``LD_LIBRARY_PATH``).
  ## * ``WebPGetEncoderVersion`` returns a non-zero version word.
  if probedAvail:
    return probedAvailResult
  probedAvail = true
  # Belt-and-suspenders: try a manual ``loadLib`` first so the failure
  # mode is well-typed (boolean) even on platforms where Nim's
  # ``{.dynlib.}`` lazy-load raises a less-catchable error variant.
  # Walk a list of candidates so the launcher binary stays portable
  # across (Nix dev shell / Homebrew / system / arbitrary deploy)
  # configurations.
  var lib: LibHandle = nil
  let candidates = [
    libwebpName,                  # compile-time-resolved (pkg-config Nix path)
    defaultDynlibName,            # bare SONAME (LD_LIBRARY_PATH / Homebrew)
    "/opt/homebrew/lib/libwebp.dylib",
    "/usr/local/lib/libwebp.dylib",
    "/usr/lib/x86_64-linux-gnu/libwebp.so.7",
    "/usr/lib64/libwebp.so.7",
  ]
  for cand in candidates:
    if cand.len == 0: continue
    lib = loadLib(cand)
    if lib != nil:
      break
  if lib == nil:
    probedAvailResult = false
    return false
  unloadLib(lib)
  # Now try the actual symbol. If the dynlib resolves but the symbol
  # is missing (e.g. a stripped-down build), we fall back.
  try:
    let v = WebPGetEncoderVersion()
    probedAvailResult = v > 0
  except Exception:
    probedAvailResult = false
  probedAvailResult

# ---------------------------------------------------------------------------
# High-level helper — the only entry point most callers need
# ---------------------------------------------------------------------------

type
  LibwebpEncodeError* = object of CatchableError
    ## Raised when the in-process encode path fails (config invalid,
    ## picture init refused, encode returned 0). The encoder facade
    ## treats this as "fall back to subprocess".

proc encodeWebPLossless*(rgba: openArray[byte];
                          width, height, compressionLevel: int): seq[byte] =
  ## RGBA → VP8L lossless RIFF, all in-process. Allocates a fresh
  ## ``WebPConfig`` + ``WebPPicture`` per call (libwebp is stateless;
  ## no across-call carry per the FUH-M4 audit § 3.2) and returns the
  ## encoded bytes ready for the W packet payload.
  ##
  ## * ``rgba`` MUST be exactly ``width*height*4`` bytes (RGBA8888,
  ##   row-major).
  ## * ``compressionLevel`` is the libwebp ``method`` knob (0..6).
  ##   Clamped to [0, 6]. ELT-M7's recommendation is 3.
  ##
  ## Raises ``LibwebpEncodeError`` on any libwebp failure (bad config,
  ## allocation, encode). Raises ``IOError`` when ``rgba`` is the wrong
  ## size. The facade catches both and falls back to the subprocess
  ## path so the launcher never crashes.
  if width <= 0 or width > WEBP_MAX_DIMENSION:
    raise newException(LibwebpEncodeError,
      "encodeWebPLossless: width " & $width & " out of range")
  if height <= 0 or height > WEBP_MAX_DIMENSION:
    raise newException(LibwebpEncodeError,
      "encodeWebPLossless: height " & $height & " out of range")
  let expected = width * height * 4
  if rgba.len != expected:
    raise newException(IOError,
      "encodeWebPLossless: rgba length " & $rgba.len &
      " != width*height*4 = " & $expected)

  var cl = compressionLevel
  if cl < 0: cl = 0
  if cl > 6: cl = 6

  # Stack-allocate; zero-init so any field we don't touch is left at
  # the pad zeros libwebp expects.
  var config: WebPConfig
  var pic: WebPPicture
  var mw: WebPMemoryWriter

  if webPConfigInit(addr config) == 0:
    raise newException(LibwebpEncodeError,
      "WebPConfigInit failed (ABI version mismatch?)")
  # Lossless preset writes ``lossless=1``, ``method=cl``, ``quality``,
  # and a couple of other lossless-specific knobs. Per the header
  # docstring the preset OVERWRITES method+quality even if we set them
  # before — so call it before any custom field tweaks.
  if WebPConfigLosslessPreset(addr config, cint(cl)) == 0:
    raise newException(LibwebpEncodeError,
      "WebPConfigLosslessPreset failed for level " & $cl)
  # Bit-exact lossless contract: preserve RGB under transparent
  # pixels (ELT-M8 § "What we cap" / FUH-M4 audit § 3.4).
  config.exact = 1
  # Single-threaded encode for predictable latency (FUH-M4 audit
  # § 1.5 quoting ELT-M7).
  config.thread_level = 0

  if WebPValidateConfig(addr config) == 0:
    raise newException(LibwebpEncodeError,
      "WebPValidateConfig refused the config (level=" & $cl & ")")

  if webPPictureInit(addr pic) == 0:
    raise newException(LibwebpEncodeError,
      "WebPPictureInit failed (ABI version mismatch?)")
  pic.use_argb = 1
  pic.width = cint(width)
  pic.height = cint(height)

  # Hand the raw RGBA in — libwebp copies into its own argb plane.
  let rgbaPtr =
    if rgba.len > 0:
      cast[ptr UncheckedArray[byte]](unsafeAddr rgba[0])
    else:
      nil
  let stride = cint(width * 4)
  if WebPPictureImportRGBA(addr pic, rgbaPtr, stride) == 0:
    WebPPictureFree(addr pic)
    raise newException(LibwebpEncodeError,
      "WebPPictureImportRGBA failed (alloc?)")

  # Wire the memory writer.
  WebPMemoryWriterInit(addr mw)
  pic.writer = cast[pointer](WebPMemoryWrite)
  pic.custom_ptr = cast[pointer](addr mw)

  let ok = WebPEncode(addr config, addr pic)
  # WebPPictureFree releases the argb plane the import allocated;
  # safe to call regardless of encode success.
  WebPPictureFree(addr pic)

  if ok == 0:
    # Free the memory writer's buffer before raising.
    WebPMemoryWriterClear(addr mw)
    raise newException(LibwebpEncodeError,
      "WebPEncode returned 0 (error_code=" & $int(pic.error_code) & ")")

  # Copy out into a Nim seq, then free the library-owned buffer.
  let n = int(mw.size)
  var output = newSeq[byte](n)
  if n > 0 and mw.mem != nil:
    copyMem(addr output[0], mw.mem, n)
  WebPMemoryWriterClear(addr mw)
  output
