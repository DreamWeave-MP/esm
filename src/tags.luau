--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
Four-byte record and subrecord types as numbers: a tag's bytes read as a little-endian u32, the
way `buffer.readu32` reads it straight from a file. Comparing two of those is one number compare.
]]

local Scratch = buffer.create(4)

--- The number a four-character tag reads as.
local function code(tag: string): number
  assert(#tag == 4, 'a tag is four bytes')
  buffer.writestring(Scratch, 0, tag)
  return buffer.readu32(Scratch, 0)
end

--- The string each tag number has read as. A file's tags are a few dozen, read over and over, but
--- they're whatever its bytes are, so only so many are kept.
local Names: { [number]: string } = {}
local NamesLimit = 4096
local namesKept = 0

--- A tag number's four bytes as a string.
local function name(tag: number): string
  local known = Names[tag]
  if known then return known end

  buffer.writeu32(Scratch, 0, tag)
  local text = buffer.readstring(Scratch, 0, 4)
  if namesKept < NamesLimit then
    namesKept += 1
    Names[tag] = text
  end

  return text
end

--- A tag as jess displays one: printable ASCII as is, every other byte as `\xNN`.
local function display(tag: number): string
  local out = ''
  for index = 0, 3 do
    local byte = bit32.extract(tag, index * 8, 8)
    if byte >= 0x20 and byte <= 0x7e then
      out ..= string.char(byte)
    else
      out ..= string.format('\\x%02X', byte)
    end
  end

  return out
end

--- Whether every byte of the tag is printable ASCII or a space.
local function isText(tag: number): boolean
  for index = 0, 3 do
    local byte = bit32.extract(tag, index * 8, 8)
    if byte < 0x20 or byte > 0x7e then return false end
  end

  return true
end

--- A tag's bytes as Rust's `to_str_lossy` shows them: invalid UTF-8 as U+FFFD.
local function lossy(tag: number): string
  local text = name(tag)
  if utf8.len(text) then return text end

  local out = ''
  for index = 1, 4 do
    local byte = string.byte(text, index)
    out ..= if byte < 0x80 then string.char(byte) else '\u{FFFD}'
  end

  return out
end

return table.freeze {
  code = code,
  display = display,
  isText = isText,
  lossy = lossy,
  name = name,
}
