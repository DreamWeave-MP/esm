--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
Minimal typed write-back (jess-omwaddon's `writeback`): re-encode only what an edit changed.

Encoding normalizes bytes vanilla data spells differently (strings without a NUL, padding, empty
subrecords, reference order), so writing a whole re-encoded record would rewrite all of that on
every edit. Instead the old and new values are both encoded and compared: subrecords whose
encoding didn't change keep their original bytes, and only changed ones take the new encoding.
CELL references are matched by their FRMR index, so unchanged references keep their bytes and
order. The result is checked: unless it decodes to what the new encoding does, with no NaN in
either (which never compares equal in the Rust check), the whole new encoding is used.
]]

local Decode = require './decode'
local Tags = require './tags'

type Value = Decode.Value

--- One subrecord: its tag and its whole bytes, header included.
type Sub = { tag: number, bytes: string }

local Nam0Tag = Tags.code 'NAM0'
local MvrfTag = Tags.code 'MVRF'
local FrmrTag = Tags.code 'FRMR'
local CellTag = Tags.code 'CELL'

local function u32(text: string, at: number): number
  return (string.unpack('<I4', text, at)) :: number
end

local function split(payload: string): { Sub }?
  local out: { Sub } = {}
  local position, length = 1, #payload
  while position <= length do
    if position + 7 > length then return nil end

    local tag, size = u32(payload, position), u32(payload, position + 4)
    local finish = position + 8 + size
    if finish - 1 > length then return nil end

    table.insert(out, { tag = tag, bytes = string.sub(payload, position, finish - 1) })
    position = finish
  end

  return out
end

--- For each element of `left`, the index of the `right` element it's paired with, by the
--- highest-scoring order-preserving alignment (0 for none); `score` is nil for pairs that can't
--- match.
local function align(left: { Sub }, right: { Sub }, score: (Sub, Sub) -> number?): { number }
  local rows, columns = #left, #right
  local width = columns + 1
  local scores: { number } = table.create((rows + 1) * width, 0)
  local function at(row: number, column: number): number return row * width + column + 1 end

  for row = rows - 1, 0, -1 do
    for column = columns - 1, 0, -1 do
      local skip = math.max(scores[at(row + 1, column)], scores[at(row, column + 1)])
      local pairScore = score(left[row + 1], right[column + 1])
      local take = if pairScore then pairScore + scores[at(row + 1, column + 1)] else 0
      scores[at(row, column)] = math.max(skip, take)
    end
  end

  local pairs: { number } = table.create(rows, 0)
  local row, column = 0, 0
  while row < rows and column < columns do
    local current = scores[at(row, column)]
    local pairScore = score(left[row + 1], right[column + 1])
    if pairScore and current == pairScore + scores[at(row + 1, column + 1)] then
      pairs[row + 1] = column + 1
      row += 1
      column += 1
    elseif current == scores[at(row + 1, column)] then
      row += 1
    else
      column += 1
    end
  end

  return pairs
end

--- Applies the changes between `old` and `new` (both encodings) to `original`'s subrecords:
--- `old` matched to `original` by tag, preferring identical bytes, and to `new` by identical bytes.
--- Original subrecords the encoding doesn't produce are kept unless a changed subrecord of the
--- same tag replaces them.
local function mergeSubrecords(original: { Sub }, old: { Sub }, new: { Sub }): string
  local oldToOriginal = align(old, original, function(left, right)
    if left.bytes == right.bytes then return 2 end

    return if left.tag == right.tag then 1 else nil
  end)

  local newToOld = align(new, old, function(left, right)
    return if left.bytes == right.bytes then 1 else nil
  end)
  local aligned: { [number]: boolean } = {}
  for _, index in oldToOriginal do
    if index > 0 then aligned[index] = true end
  end

  local out: { string } = {}
  local nextOriginal = 1
  local replaced: { [number]: boolean } = {}
  local function flush(untilIndex: number)
    while nextOriginal < untilIndex do
      if not aligned[nextOriginal] and not replaced[nextOriginal] then
        table.insert(out, original[nextOriginal].bytes)
      end

      nextOriginal += 1
    end
  end

  for index, sub in new do
    local oldIndex = newToOld[index]
    local originalIndex = if oldIndex > 0 then oldToOriginal[oldIndex] else 0
    if originalIndex > 0 then
      flush(originalIndex)
      table.insert(out, original[originalIndex].bytes)
      nextOriginal = originalIndex + 1
    elseif oldIndex > 0 then
    -- An encoding artefact the original never had; unchanged, so still absent.
    else
      -- New or changed: it takes the place of an unproduced original of the same tag.
      local position = nextOriginal
      while position <= #original and not aligned[position] do
        if original[position].tag == sub.tag and not replaced[position] then
          replaced[position] = true
          flush(position)
          break
        end

        position += 1
      end

      table.insert(out, sub.bytes)
    end
  end

  flush(#original + 1)
  return table.concat(out)
end

type Reference = { key: number, temporary: boolean, bytes: string }
type CellParts = { header: { Sub }, references: { Reference }, nam0: Sub? }

local function cellParts(subs: { Sub }): CellParts?
  local headerEnd = #subs + 1
  for ordinal, sub in subs do
    if sub.tag == Nam0Tag or sub.tag == MvrfTag or sub.tag == FrmrTag then
      headerEnd = ordinal
      break
    end
  end

  local parts: CellParts =
    { header = table.move(subs, 1, headerEnd - 1, 1, {}), references = {}, nam0 = nil }
  local temporary = false
  local pending: { string } = {}
  local currentKey: number? = nil
  local current: { string } = {}
  for ordinal = headerEnd, #subs do
    local sub = subs[ordinal]
    if sub.tag == Nam0Tag or sub.tag == MvrfTag or sub.tag == FrmrTag then
      if currentKey then
        table.insert(
          parts.references,
          { key = currentKey, temporary = temporary, bytes = table.concat(current) }
        )
        currentKey = nil
      end

      if sub.tag == Nam0Tag then
        parts.nam0 = sub
        temporary = true
      elseif sub.tag == MvrfTag then
        table.insert(pending, sub.bytes)
      else
        if #sub.bytes ~= 12 then return nil end

        currentKey = u32(sub.bytes, 9)
        current = pending
        table.insert(current, sub.bytes)
        pending = {}
      end
    elseif currentKey then
      table.insert(current, sub.bytes)
    else
      -- CNDT follows its MVRF before the reference's FRMR.
      table.insert(pending, sub.bytes)
    end
  end

  if currentKey then
    table.insert(
      parts.references,
      { key = currentKey, temporary = temporary, bytes = table.concat(current) }
    )
  end

  if #pending > 0 then return nil end

  return parts
end

--- Merges a CELL: the header like any record, and references by identity. Unchanged references
--- keep their bytes and order; changed ones take the new encoding; new ones go at the end of the
--- persistent or temporary references.
local function mergeCell(original: { Sub }, old: { Sub }, new: { Sub }): string?
  local originalParts, oldParts, newParts = cellParts(original), cellParts(old), cellParts(new)
  if not originalParts or not oldParts or not newParts then return nil end

  local oldReferences: { [number]: string } = {}
  for _, ref in oldParts.references do
    oldReferences[ref.key] = ref.bytes
  end

  local newReferences: { [number]: Reference } = {}
  for _, ref in newParts.references do
    newReferences[ref.key] = ref
  end

  local out: { string } =
    { mergeSubrecords(originalParts.header, oldParts.header, newParts.header) }
  local persistent: { string }, temporary: { string } = {}, {}
  local originalKeys: { [number]: boolean } = {}
  local originalTemporary = 0
  for _, ref in originalParts.references do
    originalKeys[ref.key] = true
    if ref.temporary then
      originalTemporary += 1
    end

    local changed = newReferences[ref.key]
    if not changed then continue end

    local oldBytes = oldReferences[ref.key]
    local bytes: string
    if oldBytes == changed.bytes then
      bytes = ref.bytes
    elseif oldBytes then
      -- Within a changed reference, only its changed subrecords take the new encoding.
      local originalSubs, oldSubs, newSubs = split(ref.bytes), split(oldBytes), split(changed.bytes)
      if not originalSubs or not oldSubs or not newSubs then return nil end

      bytes = mergeSubrecords(originalSubs, oldSubs, newSubs)
    else
      bytes = changed.bytes
    end

    table.insert(if changed.temporary then temporary else persistent, bytes)
  end

  for _, ref in newParts.references do
    if not originalKeys[ref.key] then
      table.insert(if ref.temporary then temporary else persistent, ref.bytes)
    end
  end

  for _, bytes in persistent do
    table.insert(out, bytes)
  end

  -- Vanilla counts don't always match the references that follow (expansions keep a master's
  -- NAM0 in cells they only change the header of), so the original count moves by the number of
  -- temporary references added or removed.
  local nam0 = originalParts.nam0
  local originalCount = if nam0 and #nam0.bytes == 12 then u32(nam0.bytes, 9) else nil
  local count = if originalCount then originalCount + #temporary - originalTemporary else #temporary
  if nam0 and originalCount == count then
    table.insert(out, nam0.bytes)
  elseif #temporary > 0 then
    if count < 0 or count > 4294967295 then return nil end

    table.insert(out, string.pack('<I4I4I4', Nam0Tag, 4, count))
  end

  for _, bytes in temporary do
    table.insert(out, bytes)
  end

  return table.concat(out)
end

local function merge(original: string, oldEncoded: string, newEncoded: string): string?
  local originalSubs, oldSubs, newSubs =
    split(string.sub(original, 17)),
    split(string.sub(oldEncoded, 17)),
    split(string.sub(newEncoded, 17))
  if not originalSubs or not oldSubs or not newSubs then return nil end

  local payload: string?
  if u32(original, 1) == CellTag then
    payload = mergeCell(originalSubs, oldSubs, newSubs)
  else
    payload = mergeSubrecords(originalSubs, oldSubs, newSubs)
  end

  if not payload then return nil end

  local head = string.sub(original, 1, 8)
  local flags = string.sub(original, 9, 16)
  if string.sub(oldEncoded, 9, 16) ~= string.sub(newEncoded, 9, 16) then
    flags = string.sub(newEncoded, 9, 16)
  end

  return string.sub(head, 1, 4) .. string.pack('<I4', #payload) .. flags .. payload
end

--- Whether two values are equal the way Rust's `PartialEq` compares records: NaN never equals.
local function equal(first: unknown, second: unknown): boolean
  if type(first) ~= type(second) then return false end

  if type(first) ~= 'table' then return first == second end

  local left, right = first :: { [unknown]: unknown }, second :: { [unknown]: unknown }
  for key, value in left do
    if not equal(value, right[key]) then return false end
  end

  for key in right do
    if left[key] == nil then return false end
  end

  return true
end

local function decodes(bytes: string, encoding: string): Value?
  local source = buffer.fromstring(bytes)
  local ok, value = pcall(Decode.decode, source, 0, buffer.len(source), encoding)
  return if ok then value else nil
end

--- The bytes to write for a record whose current bytes are `original` (decoding to the value
--- `oldEncoded` was encoded from), given the new value's encoding; nil when nothing changed.
local function minimal(
  original: string,
  oldEncoded: string,
  newEncoded: string,
  encoding: string
): string?
  if oldEncoded == newEncoded then return nil end

  local merged = merge(original, oldEncoded, newEncoded)
  if not merged then return newEncoded end

  local expected = decodes(newEncoded, encoding)
  local got = decodes(merged, encoding)
  if expected and got and equal(got, expected) then return merged end

  return newEncoded
end

return table.freeze { equal = equal, minimal = minimal }
