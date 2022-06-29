import bumpy, chroma, common, system/memory, vmath

const allowSimd* = not defined(pixieNoSimd) and not defined(tcc)

when allowSimd:
  import simd

  when defined(amd64):
    import nimsimd/sse2

template currentExceptionAsPixieError*(): untyped =
  ## Gets the current exception and returns it as a PixieError with stack trace.
  let e = getCurrentException()
  newException(PixieError, e.getStackTrace & e.msg, e)

template failUnsupportedBlendMode*(blendMode: BlendMode) =
  raise newException(
    PixieError,
    "Blend mode " & $blendMode & " not supported here"
  )

when defined(release):
  {.push checks: off.}

proc gaussianKernel*(radius: int): seq[uint16] {.raises: [].} =
  ## Compute lookup table for 1d Gaussian kernel.
  ## Values are [0, 255] * 256.
  result.setLen(radius * 2 + 1)

  var
    floats = newSeq[float32](result.len)
    total = 0.0
  for step in -radius .. radius:
    let
      s = radius.float32 / 2.2 # 2.2 matches Figma.
      a = 1 / sqrt(2 * PI * s^2) * exp(-1 * step.float32^2 / (2 * s^2))
    floats[step + radius] = a
    total += a
  for step in -radius .. radius:
    floats[step + radius] = floats[step + radius] / total
  for i, f in floats:
    result[i] = round(f * 255 * 256).uint16

proc `*`*(color: ColorRGBX, opacity: float32): ColorRGBX {.raises: [].} =
  if opacity == 0:
    rgbx(0, 0, 0, 0)
  else:
    let
      x = round(opacity * 255).uint32
      r = ((color.r * x) div 255).uint8
      g = ((color.g * x) div 255).uint8
      b = ((color.b * x) div 255).uint8
      a = ((color.a * x) div 255).uint8
    rgbx(r, g, b, a)

proc intersectsInside*(a, b: Segment, at: var Vec2): bool {.inline.} =
  ## Checks if the a segment intersects b segment (excluding endpoints).
  ## If it returns true, at will have point of intersection
  let
    s1 = a.to - a.at
    s2 = b.to - b.at
    denominator = (-s2.x * s1.y + s1.x * s2.y)
    s = (-s1.y * (a.at.x - b.at.x) + s1.x * (a.at.y - b.at.y)) / denominator
    t = (s2.x * (a.at.y - b.at.y) - s2.y * (a.at.x - b.at.x)) / denominator

  if s > 0 and s < 1 and t > 0 and t < 1:
    at = a.at + (t * s1)
    return true

proc fillUnsafe*(
  data: var seq[uint8], value: uint8, start, len: int
) {.inline, raises: [].} =
  ## Fills the mask data with the value starting at index start and
  ## continuing for len indices.
  nimSetMem(data[start].addr, value.cint, len)

proc fillUnsafe*(
  data: var seq[ColorRGBX], color: SomeColor, start, len: int
) {.raises: [].} =
  ## Fills the image data with the color starting at index start and
  ## continuing for len indices.
  let rgbx = color.asRgbx()

  when allowSimd and compiles(fillUnsafeSimd):
    fillUnsafeSimd(
      cast[ptr UncheckedArray[ColorRGBX]](data[start].addr),
      len,
      rgbx
    )
    return

  # Use memset when every byte has the same value
  if rgbx.r == rgbx.g and rgbx.r == rgbx.b and rgbx.r == rgbx.a:
    nimSetMem(data[start].addr, rgbx.r.cint, len * 4)
  else:
    for color in data.mitems:
      color = rgbx

const straightAlphaTable = block:
  var table: array[256, array[256, uint8]]
  for a in 0 ..< 256:
    let multiplier = if a > 0: (255 / a.float32) else: 0
    for c in 0 ..< 256:
      table[a][c] = min(round((c.float32 * multiplier)), 255).uint8
  table

proc toStraightAlpha*(data: var seq[ColorRGBA | ColorRGBX]) {.raises: [].} =
  ## Converts an image from premultiplied alpha to straight alpha.
  ## This is expensive for large images.
  for i in 0 ..< data.len:
    var c = data[i]
    c.r = straightAlphaTable[c.a][c.r]
    c.g = straightAlphaTable[c.a][c.g]
    c.b = straightAlphaTable[c.a][c.b]
    data[i] = c

proc toPremultipliedAlpha*(data: var seq[ColorRGBA | ColorRGBX]) {.raises: [].} =
  ## Converts an image to premultiplied alpha from straight alpha.
  when allowSimd and compiles(toPremultipliedAlphaSimd):
    toPremultipliedAlphaSimd(
      cast[ptr UncheckedArray[uint32]](data[0].addr),
      data.len
    )
    return

  for i in 0 ..< data.len:
    var c = data[i]
    if c.a != 255:
      c.r = ((c.r.uint32 * c.a) div 255).uint8
      c.g = ((c.g.uint32 * c.a) div 255).uint8
      c.b = ((c.b.uint32 * c.a) div 255).uint8
      data[i] = c

proc isOpaque*(data: var seq[ColorRGBX], start, len: int): bool =
  when allowSimd and compiles(isOpaqueSimd):
    return isOpaqueSimd(
      cast[ptr UncheckedArray[ColorRGBX]](data[start].addr),
      len
    )

  result = true

  for i in start ..< start + len:
    if data[i].a != 255:
      return false

when defined(amd64) and allowSimd:
  proc applyOpacity*(color: M128, opacity: float32): ColorRGBX {.inline.} =
    let opacityVec = mm_set1_ps(opacity)
    var finalColor = mm_cvtps_epi32(mm_mul_ps(color, opacityVec))
    finalColor = mm_packus_epi16(finalColor, mm_setzero_si128())
    finalColor = mm_packus_epi16(finalColor, mm_setzero_si128())
    cast[ColorRGBX](mm_cvtsi128_si32(finalColor))

  proc packAlphaValues(v: M128i): M128i {.inline, raises: [].} =
    ## Shuffle the alpha values for these 4 colors to the first 4 bytes
    result = mm_srli_epi32(v, 24)
    result = mm_packus_epi16(result, mm_setzero_si128())
    result = mm_packus_epi16(result, mm_setzero_si128())

  proc pack4xAlphaValues*(i, j, k, l: M128i): M128i {.inline, raises: [].} =
    let
      i = packAlphaValues(i)
      j = mm_slli_si128(packAlphaValues(j), 4)
      k = mm_slli_si128(packAlphaValues(k), 8)
      l = mm_slli_si128(packAlphaValues(l), 12)
    mm_or_si128(mm_or_si128(i, j), mm_or_si128(k, l))

  proc unpackAlphaValues*(v: M128i): M128i {.inline, raises: [].} =
    ## Unpack the first 32 bits into 4 rgba(0, 0, 0, value)
    result = mm_unpacklo_epi8(mm_setzero_si128(), v)
    result = mm_unpacklo_epi8(mm_setzero_si128(), result)

when defined(release):
  {.pop.}
