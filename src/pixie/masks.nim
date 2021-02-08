import common, vmath

type
  Mask* = ref object
    ## Mask object that holds mask opacity data.
    width*, height*: int
    data*: seq[uint8]

when defined(release):
  {.push checks: off.}

proc newMask*(width, height: int): Mask =
  ## Creates a new mask with the parameter dimensions.
  if width <= 0 or height <= 0:
    raise newException(PixieError, "Mask width and height must be > 0")

  result = Mask()
  result.width = width
  result.height = height
  result.data = newSeq[uint8](width * height)

proc wh*(mask: Mask): Vec2 {.inline.} =
  ## Return with and height as a size vector.
  vec2(mask.width.float32, mask.height.float32)

proc copy*(mask: Mask): Mask =
  ## Copies the image data into a new image.
  result = newMask(mask.width, mask.height)
  result.data = mask.data

proc `$`*(mask: Mask): string =
  ## Prints the mask size.
  "<Mask " & $mask.width & "x" & $mask.height & ">"

proc inside*(mask: Mask, x, y: int): bool {.inline.} =
  ## Returns true if (x, y) is inside the mask.
  x >= 0 and x < mask.width and y >= 0 and y < mask.height

proc dataIndex*(mask: Mask, x, y: int): int {.inline.} =
  mask.width * y + x

proc getValueUnsafe*(mask: Mask, x, y: int): uint8 {.inline.} =
  ## Gets a color from (x, y) coordinates.
  ## * No bounds checking *
  ## Make sure that x, y are in bounds.
  ## Failure in the assumptions will case unsafe memory reads.
  result = mask.data[mask.width * y + x]

proc `[]`*(mask: Mask, x, y: int): uint8 {.inline.} =
  ## Gets a pixel at (x, y) or returns transparent black if outside of bounds.
  if mask.inside(x, y):
    return mask.getValueUnsafe(x, y)

proc setValueUnsafe*(mask: Mask, x, y: int, value: uint8) {.inline.} =
  ## Sets a value from (x, y) coordinates.
  ## * No bounds checking *
  ## Make sure that x, y are in bounds.
  ## Failure in the assumptions will case unsafe memory writes.
  mask.data[mask.dataIndex(x, y)] = value

proc `[]=`*(mask: Mask, x, y: int, value: uint8) {.inline.} =
  ## Sets a pixel at (x, y) or does nothing if outside of bounds.
  if mask.inside(x, y):
    mask.setValueUnsafe(x, y, value)

proc minifyBy2*(mask: Mask, power = 1): Mask =
  ## Scales the mask down by an integer scale.
  if power < 0:
    raise newException(PixieError, "Cannot minifyBy2 with negative power")
  if power == 0:
    return mask.copy()

  for i in 1 .. power:
    result = newMask(mask.width div 2, mask.height div 2)
    for y in 0 ..< result.height:
      for x in 0 ..< result.width:
        let value =
          mask.getValueUnsafe(x * 2 + 0, y * 2 + 0).uint32 +
          mask.getValueUnsafe(x * 2 + 1, y * 2 + 0) +
          mask.getValueUnsafe(x * 2 + 1, y * 2 + 1) +
          mask.getValueUnsafe(x * 2 + 0, y * 2 + 1)
        result.setValueUnsafe(x, y, (value div 4).uint8)

when defined(release):
  {.pop.}
