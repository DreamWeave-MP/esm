--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
Record identity and small record queries tools share (jess-omwaddon's `records`), read straight
from the identifying subrecord without decoding the record.
]]

local Plugin = require './plugin'
local Save = require './save'
local Tags = require './tags'
local Text = require './text'

type Plugin = Plugin.Plugin

-- A record's header, and a subrecord's: a tag and a size, and for a record eight bytes more.
local RecordHeaderLength = 16
local SubrecordHeaderLength = 8

local Tes3Tag = Tags.code 'TES3'
local ScptTag = Tags.code 'SCPT'
local SchdTag = Tags.code 'SCHD'
local InfoTag = Tags.code 'INFO'
local InamTag = Tags.code 'INAM'
local NameTag = Tags.code 'NAME'
local CellTag = Tags.code 'CELL'
local DialTag = Tags.code 'DIAL'
local DataTag = Tags.code 'DATA'
local AmbiTag = Tags.code 'AMBI'
local SctxTag = Tags.code 'SCTX'

--- A record's id: INAM for dialogue responses, the SCHD name for scripts, NAME otherwise; nil for
--- the TES3 header, a CELL opened without its header, and a record without its id subrecord.
local function id(plugin: Plugin, index: number): string?
  local code = plugin:code(index)
  if code == Tes3Tag then return nil end

  if code == CellTag then
    local parts = plugin:keptParts(index)
    if parts and not parts.header then return nil end
  end

  if code == ScptTag then
    local source, at, size = plugin:findSubrecord(index, SchdTag)
    if not source or size < 32 then return nil end

    return Text.decode(source, at, 32, plugin.encoding)
  end

  local source, at, size = plugin:findSubrecord(index, if code == InfoTag then InamTag else NameTag)
  if not source then return nil end

  -- In an OpenMW save, typed RefIds read as OpenMW spells them (`#-2 -9` for an exterior cell).
  if plugin.profile == 'omwsave' then
    local refId = Save.decodeRefId(source, at, size)
    if refId then return Save.refIdText(refId) end
  end

  return Text.decode(source, at, size, plugin.encoding)
end

--- Where record `index`'s id is in its bytes, cut where `id` cuts its text (a final NUL dropped,
--- then at the first NUL): the buffer, the offset, and the length, or nil for a record without
--- one. The bytes are in the plugin's code page, so a script can intern or compare ids without
--- decoding them; for content files, not saves, whose ids are typed.
local function idSpan(plugin: Plugin, index: number): (buffer?, number, number)
  local code = plugin:code(index)
  if code == Tes3Tag then return nil, 0, 0 end

  if code == CellTag then
    local parts = plugin:keptParts(index)
    if parts and not parts.header then return nil, 0, 0 end
  end

  local source, at, size
  if code == ScptTag then
    source, at, size = plugin:findSubrecord(index, SchdTag)
    if not source or size < 32 then return nil, 0, 0 end

    size = 32
  else
    source, at, size = plugin:findSubrecord(index, if code == InfoTag then InamTag else NameTag)
    if not source then return nil, 0, 0 end
  end

  local bytes = source :: buffer
  local finish = at + size
  if size > 0 and buffer.readu8(bytes, finish - 1) == 0 then
    finish -= 1
  end

  for position = at, finish - 1 do
    if buffer.readu8(bytes, position) == 0 then return bytes, at, position - at end
  end

  return bytes, at, finish - at
end

export type Key = { type: string, id: string }

--- Every identified record's `{ type, id }`, sorted by type then id, each once.
local function objectKeys(plugin: Plugin): { Key }
  local keys: { [string]: Key } = {}
  local texts: { string } = {}
  for index = 0, plugin:count() - 1 do
    local recordId = id(plugin, index)
    if not recordId then continue end

    local tag = Tags.display(plugin:code(index))
    local text = tag .. '\0' .. recordId
    if keys[text] then continue end

    keys[text] = { type = tag, id = recordId }
    table.insert(texts, text)
  end

  -- A type as displayed has no NUL in it, and nothing sorts before one: a type, a NUL, and an id
  -- sort as the type and then the id do, and as strings, with no comparator to call.
  table.sort(texts)
  return [for text in texts => keys[text]]
end

--- The first record of type `tag` whose id is `recordId`, as a 0-based index, or nil.
local function find(plugin: Plugin, tag: string, recordId: string): number?
  local code = Tags.code(tag)
  for index = 0, plugin:count() - 1 do
    if plugin:code(index) == code and id(plugin, index) == recordId then return index end
  end

  return nil
end

--- Every DIAL topic's id, in plugin order.
local function dialogueTopics(plugin: Plugin): { string }
  local topics = {}
  for index = 0, plugin:count() - 1 do
    if plugin:code(index) ~= DialTag then continue end

    local topic = id(plugin, index)
    if topic then table.insert(topics, topic) end
  end

  return topics
end

--- A record header's flags: the value as the file has it, and each bit the format names.
export type HeaderFlags = {
  value: number,
  deleted: boolean,
  persistent: boolean,
  ignored: boolean,
  blocked: boolean,
}

--- Record `index`'s header flags, read from its header: a decoded record's own `flags` field
--- spells the same bits as names.
local function headerFlags(plugin: Plugin, index: number): HeaderFlags
  local value = plugin:flags(index)
  return {
    value = value,
    deleted = bit32.btest(value, 0x20),
    persistent = bit32.btest(value, 0x400),
    ignored = bit32.btest(value, 0x1000),
    blocked = bit32.btest(value, 0x2000),
  }
end

--- Whether a CELL is an interior (its DATA flag bit 0); false for other records.
local function cellIsInterior(plugin: Plugin, index: number): boolean
  if plugin:code(index) ~= CellTag then return false end

  local source, at, size = plugin:findSubrecord(index, DataTag)
  return source ~= nil and size >= 4 and bit32.btest(buffer.readu32(source, at), 1)
end

--- Whether a CELL is an exterior; false for other records.
local function cellIsExterior(plugin: Plugin, index: number): boolean
  return plugin:code(index) == CellTag and not cellIsInterior(plugin, index)
end

--- A cell's AMBI fog density, if present.
local function cellAmbientFogDensity(plugin: Plugin, index: number): number?
  local source, at, size = plugin:findSubrecord(index, AmbiTag)
  if not source or size < 16 then return nil end

  return buffer.readf32(source, at + 12)
end

--- The legacy fog density in a cell's DATA, if present.
local function cellDataFogDensity(plugin: Plugin, index: number): number?
  local source, at, size = plugin:findSubrecord(index, DataTag)
  if not source or size < 8 then return nil end

  return buffer.readf32(source, at + 4)
end

--[[ String fields ]]

local RgnnTag, PnamTag, NnamTag = Tags.code 'RGNN', Tags.code 'PNAM', Tags.code 'NNAM'

--- The typed string field names subrecords carry in any record (jess-omwaddon's
--- `string_field_name`), by subrecord tag.
local FieldNamesByTag: { [string]: string } = {
  NAME = 'id',
  MODL = 'mesh',
  FNAM = 'name',
  ITEX = 'icon',
  SCRI = 'script',
  TEXT = 'text',
  SCTX = 'script-text',
  DESC = 'description',
  BNAM = 'body',
  CNAM = 'class',
  ANAM = 'animation',
  SNAM = 'sound',
  TNAM = 'topic',
  RNAM = 'race',
  ONAM = 'object',
  DNAM = 'data-name',
}

local FieldNames: { [number]: string } = {}
for tag, field in FieldNamesByTag do
  FieldNames[Tags.code(tag)] = field
end

--- The string field a subrecord of a record of tag `record` is, by name, or nil.
local function fieldName(record: number, sub: number): string?
  if record == CellTag and sub == RgnnTag then return 'region' end

  if record == InfoTag then
    if sub == PnamTag then return 'previous' end

    if sub == NnamTag then return 'next' end

    if sub == InamTag then return 'info-id' end

    if sub == NameTag then return 'text' end
  end

  return FieldNames[sub]
end

export type StringField = {
  name: string,
  value: string,
  --- The subrecord's tag and its position in the record (0-based).
  tag: string,
  subrecord: number,
  start: number,
  finish: number,
}

--- Record `index`'s typed string fields, in subrecord order.
local function stringFields(plugin: Plugin, index: number): { StringField }
  local code = plugin:code(index)
  local source, start, finish = plugin:span(index)
  local out: { StringField } = {}
  -- Read where the subrecords are: most aren't strings, and listing them all first was most of
  -- the work.
  local position, ordinal = start + RecordHeaderLength, 0
  while position < finish do
    local sub = buffer.readu32(source, position)
    local size = buffer.readu32(source, position + 4)
    local payload = position + SubrecordHeaderLength
    local name = fieldName(code, sub)
    if name then
      table.insert(out, {
        name = name,
        value = Text.decode(source, payload, size, plugin.encoding),
        tag = Tags.name(sub),
        subrecord = ordinal,
        start = position,
        finish = payload + size,
      })
    end

    position, ordinal = payload + size, ordinal + 1
  end

  return out
end

--- What a record view names a record by (jess-omwaddon's `RecordView::id`): its first `id` or
--- `info-id` string field (so a SCPT without SCHD has its NAME), a save record's typed id, and
--- nil for a CELL read without its header.
local function fieldId(plugin: Plugin, index: number): string?
  if plugin.profile == 'omwsave' then return id(plugin, index) end

  local code = plugin:code(index)
  if code == CellTag then
    local parts = plugin:keptParts(index)
    if parts and not parts.header then return nil end
  end

  local source, start, finish = plugin:span(index)
  local position = start + RecordHeaderLength
  while position < finish do
    local size = buffer.readu32(source, position + 4)
    local payload = position + SubrecordHeaderLength
    local name = fieldName(code, buffer.readu32(source, position))
    if name == 'id' or name == 'info-id' then
      return Text.decode(source, payload, size, plugin.encoding)
    end

    position = payload + size
  end

  return nil
end

--- The text selectors match a subrecord against: `name: value` for a typed string field, else
--- its tag and its payload decoded in the plugin's code page.
local function subrecordText(plugin: Plugin, index: number, sub: Plugin.Subrecord): string
  local source = plugin:span(index)
  local name = fieldName(plugin:code(index), sub.code)
  if name then return `{name}: {Text.decode(source, sub.payload, sub.size, plugin.encoding)}` end

  return `{Tags.display(sub.code)}: {Text.decodeExact(
    source,
    sub.payload,
    sub.size,
    plugin.encoding
  )}`
end

--- A script record's source text (SCTX), if present.
local function scriptText(plugin: Plugin, index: number): string?
  local source, at, size = plugin:findSubrecord(index, SctxTag)
  if not source then return nil end

  return Text.decode(source, at, size, plugin.encoding)
end

return table.freeze {
  cellAmbientFogDensity = cellAmbientFogDensity,
  cellDataFogDensity = cellDataFogDensity,
  cellIsExterior = cellIsExterior,
  cellIsInterior = cellIsInterior,
  dialogueTopics = dialogueTopics,
  fieldId = fieldId,
  fieldName = fieldName,
  find = find,
  headerFlags = headerFlags,
  id = id,
  idSpan = idSpan,
  objectKeys = objectKeys,
  scriptText = scriptText,
  stringFields = stringFields,
  subrecordText = subrecordText,
}
