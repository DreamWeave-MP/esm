--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
A growable byte buffer: what encoding a record and rebuilding one write into. `length` is how much
is written; `finish` copies exactly that many bytes out.
]]

export type Writer = { bytes: buffer, length: number }

local function new(capacity: number?): Writer
  return { bytes = buffer.create(math.max(capacity or 256, 16)), length = 0 }
end

--- Room for `need` bytes in all: the writer's buffer, grown to hold them.
local function grow(writer: Writer, need: number): buffer
  local size = buffer.len(writer.bytes)
  while size < need do
    size *= 2
  end

  local grown = buffer.create(size)
  buffer.copy(grown, 0, writer.bytes, 0, writer.length)
  writer.bytes = grown
  return grown
end

local function reserve(writer: Writer, extra: number)
  local need = writer.length + extra
  if need > buffer.len(writer.bytes) then grow(writer, need) end
end

-- Each write asks for its own room: most find it there, and a call to `reserve` to learn so was
-- as much work as the write.

local function u8(writer: Writer, value: number)
  local {bytes, length} = writer
  if length + 1 > buffer.len(bytes) then bytes = grow(writer, length + 1) end

  buffer.writeu8(bytes, length, value)
  writer.length = length + 1
end

local function u16(writer: Writer, value: number)
  local {bytes, length} = writer
  if length + 2 > buffer.len(bytes) then bytes = grow(writer, length + 2) end

  buffer.writeu16(bytes, length, value)
  writer.length = length + 2
end

local function u32(writer: Writer, value: number)
  local {bytes, length} = writer
  if length + 4 > buffer.len(bytes) then bytes = grow(writer, length + 4) end

  buffer.writeu32(bytes, length, value)
  writer.length = length + 4
end

--- Two u32s, as a subrecord's tag and size are.
local function u32Pair(writer: Writer, first: number, second: number)
  local {bytes, length} = writer
  if length + 8 > buffer.len(bytes) then bytes = grow(writer, length + 8) end

  buffer.writeu32(bytes, length, first)
  buffer.writeu32(bytes, length + 4, second)
  writer.length = length + 8
end

local function i32(writer: Writer, value: number)
  local {bytes, length} = writer
  if length + 4 > buffer.len(bytes) then bytes = grow(writer, length + 4) end

  buffer.writei32(bytes, length, value)
  writer.length = length + 4
end

local function f32(writer: Writer, value: number)
  local {bytes, length} = writer
  if length + 4 > buffer.len(bytes) then bytes = grow(writer, length + 4) end

  buffer.writef32(bytes, length, value)
  writer.length = length + 4
end

local function f64(writer: Writer, value: number)
  local {bytes, length} = writer
  if length + 8 > buffer.len(bytes) then bytes = grow(writer, length + 8) end

  buffer.writef64(bytes, length, value)
  writer.length = length + 8
end

--- A u64 held exactly in a number (up to 2^53).
local function u64(writer: Writer, value: number)
  local {bytes, length} = writer
  if length + 8 > buffer.len(bytes) then bytes = grow(writer, length + 8) end

  buffer.writeu32(bytes, length, value % 4294967296)
  buffer.writeu32(bytes, length + 4, value // 4294967296)
  writer.length = length + 8
end

local function stringBytes(writer: Writer, value: string)
  local {bytes, length} = writer
  local finish = length + #value
  if finish > buffer.len(bytes) then bytes = grow(writer, finish) end

  buffer.writestring(bytes, length, value)
  writer.length = finish
end

local function zeros(writer: Writer, count: number)
  reserve(writer, count)
  buffer.fill(writer.bytes, writer.length, 0, count)
  writer.length += count
end

--- `length` bytes of `source` from `offset`.
local function copy(writer: Writer, source: buffer, offset: number, length: number)
  reserve(writer, length)
  buffer.copy(writer.bytes, writer.length, source, offset, length)
  writer.length += length
end

--- The bytes written, as a buffer of exactly their length.
local function finish(writer: Writer): buffer
  local out = buffer.create(writer.length)
  buffer.copy(out, 0, writer.bytes, 0, writer.length)
  return out
end

return table.freeze {
  copy = copy,
  f32 = f32,
  f64 = f64,
  finish = finish,
  i32 = i32,
  new = new,
  reserve = reserve,
  string = stringBytes,
  u16 = u16,
  u32 = u32,
  u32Pair = u32Pair,
  u64 = u64,
  u8 = u8,
  zeros = zeros,
}
