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

local function reserve(writer: Writer, extra: number)
  local need = writer.length + extra
  local size = buffer.len(writer.bytes)
  if need <= size then return end

  while size < need do
    size *= 2
  end

  local grown = buffer.create(size)
  buffer.copy(grown, 0, writer.bytes, 0, writer.length)
  writer.bytes = grown
end

local function u8(writer: Writer, value: number)
  reserve(writer, 1)
  buffer.writeu8(writer.bytes, writer.length, value)
  writer.length += 1
end

local function u16(writer: Writer, value: number)
  reserve(writer, 2)
  buffer.writeu16(writer.bytes, writer.length, value)
  writer.length += 2
end

local function u32(writer: Writer, value: number)
  reserve(writer, 4)
  buffer.writeu32(writer.bytes, writer.length, value)
  writer.length += 4
end

local function i32(writer: Writer, value: number)
  reserve(writer, 4)
  buffer.writei32(writer.bytes, writer.length, value)
  writer.length += 4
end

local function f32(writer: Writer, value: number)
  reserve(writer, 4)
  buffer.writef32(writer.bytes, writer.length, value)
  writer.length += 4
end

local function f64(writer: Writer, value: number)
  reserve(writer, 8)
  buffer.writef64(writer.bytes, writer.length, value)
  writer.length += 8
end

--- A u64 held exactly in a number (up to 2^53).
local function u64(writer: Writer, value: number)
  reserve(writer, 8)
  buffer.writeu32(writer.bytes, writer.length, value % 4294967296)
  buffer.writeu32(writer.bytes, writer.length + 4, value // 4294967296)
  writer.length += 8
end

local function stringBytes(writer: Writer, value: string)
  local length = #value
  reserve(writer, length)
  buffer.writestring(writer.bytes, writer.length, value)
  writer.length += length
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
  u64 = u64,
  u8 = u8,
  zeros = zeros,
}
