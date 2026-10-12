--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
Typed record encoding: a value in jess-omwaddon's shape (as `decode` gives) written as record
bytes, the way jess-omwaddon's `Save` writes them: the subrecords in its order, optional ones only
when set, strings NUL-terminated, the header's second word zero. Missing fields take the record
type's defaults, nested structs included; a list replaces the default list whole.

Encoding normalizes what vanilla data spells differently (unterminated strings, padding, reference
order), so a decoded record doesn't always encode to its own bytes; `writeback.luau` keeps the
original subrecords an edit didn't change.
]]

local Decode = require './decode'
local References = require './references'
local Schema = require './schema'
local Tags = require './tags'
local Text = require './text'
local Writer = require './writer'

local Enums = Schema.Enums
local Flags = Schema.Flags

type Value = Decode.Value
type Writer = Writer.Writer

local function fail(message: string): never error(message, 0) end

local function isList(value: unknown): boolean
  if type(value) ~= 'table' then return false end

  local members = value :: { [unknown]: unknown }
  return next(members) == nil or members[1] ~= nil
end

--- `value` laid over `default`: missing fields take the default's, structs merge field by field.
local function merge(default: unknown, value: unknown): unknown
  if value == nil then return default end

  if type(default) ~= 'table' or type(value) ~= 'table' or isList(default) or isList(value) then
    return value
  end

  local out: Value = {}
  local defaultFields = default :: Value
  local valueFields = value :: Value
  for key, fallback in defaultFields do
    out[key] = merge(fallback, valueFields[key])
  end

  for key, field in valueFields do
    if defaultFields[key] == nil then out[key] = field end
  end

  return out
end

--[[ Field access, checked ]]

local function field(from: Value, key: string, path: string): unknown return from[key] end

local function numberOf(from: Value, key: string, path: string): number
  local value = field(from, key, path)
  if type(value) ~= 'number' then
    return fail(`{path}.{key}: expected number, got {type(value)}`)
  end

  return value
end

local function stringOf(from: Value, key: string, path: string): string
  local value = field(from, key, path)
  if type(value) ~= 'string' then
    return fail(`{path}.{key}: expected string, got {type(value)}`)
  end

  return value
end

local function tableOf(from: Value, key: string, path: string): Value
  local value = field(from, key, path)
  if type(value) ~= 'table' then fail(`{path}.{key}: expected table, got {type(value)}`) end

  return value :: Value
end

local function listOf(from: Value, key: string, path: string): { unknown }
  local value = field(from, key, path)
  if type(value) ~= 'table' then fail(`{path}.{key}: expected list, got {type(value)}`) end

  return value :: { unknown }
end

local function numberAt(items: { unknown }, index: number, path: string): number
  local value = items[index]
  if type(value) ~= 'number' then
    return fail(`{path}[{index}]: expected number, got {type(value)}`)
  end

  return value
end

local function enum(enumeration: Schema.Enum, from: Value, key: string, path: string): number
  return Schema.valueOf(enumeration, from[key], `{path}.{key}`)
end

local function flags(set: Schema.Flags, from: Value, key: string, path: string): number
  return Schema.flagBits(set, from[key], `{path}.{key}`)
end

--[[ Writing ]]

local function tag(writer: Writer, name: string) Writer.u32(writer, Tags.code(name)) end

--- Text in the code page, cut at its first NUL (`Writer::encode`).
local function encodeText(value: string, encoding: string): string
  local encoded = Text.encode(value, encoding) or fail(`encode error: {value}`)

  local nul = string.find(encoded, '\0', 1, true)
  if nul then return string.sub(encoded, 1, nul - 1) end

  return encoded
end

--- A length-prefixed, NUL-terminated string (`save_string`).
local function writeString(writer: Writer, value: string, encoding: string)
  if value == '' then
    Writer.u32(writer, 1)
    Writer.u8(writer, 0)
    return
  end

  local encoded = Text.encode(value, encoding) or fail(`encode error: {value}`)

  local nul = string.find(encoded, '\0', 1, true)
  if nul then
    Writer.u32(writer, nul - 1)
    Writer.string(writer, string.sub(encoded, 1, nul - 1))
    return
  end

  Writer.u32(writer, #encoded + 1)
  Writer.string(writer, encoded)
  Writer.u8(writer, 0)
end

--- A length-prefixed string with every byte kept (`save_exact_string`).
local function writeExact(writer: Writer, value: string, encoding: string)
  local encoded = Text.encode(value, encoding) or fail(`encode error: {value}`)

  Writer.u32(writer, #encoded)
  Writer.string(writer, encoded)
end

--- A NUL-padded string of exactly `length` bytes (`FixedString<N>`).
local function writeFixed(writer: Writer, value: string, length: number, encoding: string)
  local encoded = encodeText(value, encoding)
  if #encoded > length then fail(`Invalid string length ({#value} != {length}): {value}`) end

  Writer.string(writer, encoded)
  Writer.zeros(writer, length - #encoded)
end

--- A string subrecord: its tag, then the string.
local function sub(writer: Writer, name: string, value: string, encoding: string)
  tag(writer, name)
  writeString(writer, value, encoding)
end

--- A string subrecord written only when the string isn't empty.
local function opt(writer: Writer, name: string, value: string, encoding: string)
  if value ~= '' then sub(writer, name, value, encoding) end
end

local function header(writer: Writer, name: string, size: number)
  tag(writer, name)
  Writer.u32(writer, size)
end

local function dele(writer: Writer, bits: number)
  if not bit32.btest(bits, 0x20) then return end

  header(writer, 'DELE', 4)
  Writer.u32(writer, 0)
end

local function f32s(writer: Writer, items: { unknown }, count: number, path: string)
  for index = 1, count do
    Writer.f32(writer, numberAt(items, index, path))
  end
end

local function i32s(writer: Writer, items: { unknown }, count: number, path: string)
  for index = 1, count do
    Writer.i32(writer, numberAt(items, index, path))
  end
end

local function u8s(writer: Writer, items: { unknown }, count: number, path: string)
  for index = 1, count do
    Writer.u8(writer, numberAt(items, index, path))
  end
end

--- The blob base64 `text` holds, written as is.
local function blob(writer: Writer, text: string, path: string)
  local data = Schema.unbase64(text, path)
  Writer.copy(writer, data, 0, buffer.len(data))
end

--- A base64 blob written with its own length prefix (a `Vec<u8>` jess-omwaddon saves whole), its
--- length checked against `width`-byte elements.
local function blobWithLength(writer: Writer, text: string, path: string)
  blob(writer, text, path)
end

--[[ Structs ]]

local function effect(writer: Writer, value: Value, path: string)
  Writer.u16(
    writer,
    Schema.valueOf(Enums.EffectId, value.magicEffect, `{path}.magicEffect`) % 65536
  )
  Writer.u8(writer, Schema.valueOf(Enums.SkillId, value.skill, `{path}.skill`) % 256)
  Writer.u8(writer, Schema.valueOf(Enums.AttributeId, value.attribute, `{path}.attribute`) % 256)
  Writer.u32(writer, enum(Enums.EffectRange, value, 'range', path))
  Writer.u32(writer, numberOf(value, 'area', path))
  Writer.u32(writer, numberOf(value, 'duration', path))
  Writer.u32(writer, numberOf(value, 'minMagnitude', path))
  Writer.u32(writer, numberOf(value, 'maxMagnitude', path))
end

local function effects(writer: Writer, record: Value)
  for index, item in listOf(record, 'effects', 'value') do
    header(writer, 'ENAM', 24)
    effect(writer, item :: Value, `effects[{index}]`)
  end
end

local function inventory(writer: Writer, record: Value, encoding: string)
  for index, item in listOf(record, 'inventory', 'value') do
    local pair = item :: { unknown }
    header(writer, 'NPCO', 36)
    Writer.i32(writer, numberAt(pair, 1, `inventory[{index}]`))
    writeFixed(writer, pair[2] :: string, 32, encoding)
  end
end

local function spells(writer: Writer, record: Value, encoding: string)
  for _, item in listOf(record, 'spells', 'value') do
    header(writer, 'NPCS', 32)
    writeFixed(writer, item :: string, 32, encoding)
  end
end

local function aiData(writer: Writer, record: Value)
  local data = tableOf(record, 'aiData', 'value')
  header(writer, 'AIDT', 12)
  Writer.u16(writer, numberOf(data, 'hello', 'aiData') % 65536)
  Writer.u8(writer, numberOf(data, 'fight', 'aiData') % 256)
  Writer.u8(writer, numberOf(data, 'flee', 'aiData') % 256)
  Writer.u8(writer, numberOf(data, 'alarm', 'aiData') % 256)
  Writer.zeros(writer, 3)
  Writer.u32(writer, flags(Flags.ServiceFlags, data, 'services', 'aiData'))
end

local function travel(writer: Writer, record: Value, encoding: string)
  for index, item in listOf(record, 'travelDestinations', 'value') do
    local destination = item :: Value
    local path = `travelDestinations[{index}]`
    header(writer, 'DODT', 24)
    f32s(writer, listOf(destination, 'translation', path), 3, `{path}.translation`)
    f32s(writer, listOf(destination, 'rotation', path), 3, `{path}.rotation`)
    opt(writer, 'DNAM', stringOf(destination, 'cell', path), encoding)
  end
end

local function packages(writer: Writer, record: Value, encoding: string)
  for index, item in listOf(record, 'aiPackages', 'value') do
    local package = item :: Value
    local path = `aiPackages[{index}]`
    local kind = package.type
    if kind == 'Travel' then
      header(writer, 'AI_T', 16)
      f32s(writer, listOf(package, 'location', path), 3, path)
      Writer.u8(writer, numberOf(package, 'reset', path))
      Writer.zeros(writer, 3)
    elseif kind == 'Wander' then
      header(writer, 'AI_W', 14)
      Writer.u16(writer, numberOf(package, 'distance', path))
      Writer.u16(writer, numberOf(package, 'duration', path))
      Writer.u8(writer, numberOf(package, 'gameHour', path))
      for idleIndex = 2, 9 do
        Writer.u8(writer, numberOf(package, `idle{idleIndex}`, path))
      end

      Writer.u8(writer, numberOf(package, 'reset', path) % 256)
    elseif kind == 'Escort' or kind == 'Follow' then
      header(writer, if kind == 'Escort' then 'AI_E' else 'AI_F', 48)
      f32s(writer, listOf(package, 'location', path), 3, path)
      Writer.u16(writer, numberOf(package, 'duration', path))
      writeFixed(writer, stringOf(package, 'target', path), 32, encoding)
      Writer.u8(writer, numberOf(package, 'reset', path))
      Writer.zeros(writer, 1)
      opt(writer, 'CNDT', (package.cell :: string?) or '', encoding)
    elseif kind == 'Activate' then
      header(writer, 'AI_A', 33)
      writeFixed(writer, stringOf(package, 'target', path), 32, encoding)
      Writer.u8(writer, numberOf(package, 'reset', path))
    else
      fail(
        `{path}.type: unknown variant '{tostring(kind)}', expected one of Activate, Escort, Follow, Travel, Wander`
      )
    end
  end
end

local function bipedObjects(writer: Writer, record: Value, encoding: string)
  for index, item in listOf(record, 'bipedObjects', 'value') do
    local object = item :: Value
    local path = `bipedObjects[{index}]`
    header(writer, 'INDX', 1)
    Writer.u8(writer, enum(Enums.BipedObjectType, object, 'bipedObjectType', path))
    opt(writer, 'BNAM', stringOf(object, 'maleBodypart', path), encoding)
    opt(writer, 'CNAM', stringOf(object, 'femaleBodypart', path), encoding)
  end
end

--- `value` clamped to `0.5..2.0`, and whether that's 1 (the default scale, which goes unwritten).
local function clampScale(value: number): (number, boolean)
  local scale = math.clamp(value, 0.5, 2)
  if value ~= value then scale = value end

  return scale, math.abs(scale - 1) < 1e-6
end

--[[ Record types ]]

type Encoder = (writer: Writer, record: Value, encoding: string, bits: number) -> ()

local Encoders: { [string]: Encoder } = {}

--- `MODL`, `FNAM`, data, `SCRI`, `ITEX`: the shape most items save in.
local function itemHead(writer: Writer, record: Value, encoding: string)
  sub(writer, 'NAME', stringOf(record, 'id', 'value'), encoding)
  opt(writer, 'MODL', stringOf(record, 'mesh', 'value'), encoding)
  opt(writer, 'FNAM', stringOf(record, 'name', 'value'), encoding)
end

local function itemTail(writer: Writer, record: Value, encoding: string)
  opt(writer, 'SCRI', stringOf(record, 'script', 'value'), encoding)
  opt(writer, 'ITEX', stringOf(record, 'icon', 'value'), encoding)
end

Encoders.Header = function(writer, record, encoding)
  header(writer, 'HEDR', 300)
  Writer.f32(writer, numberOf(record, 'version', 'value'))
  Writer.u32(writer, enum(Enums.FileType, record, 'fileType', 'value'))
  writeFixed(writer, stringOf(record, 'author', 'value'), 32, encoding)
  writeFixed(writer, stringOf(record, 'description', 'value'), 256, encoding)
  Writer.u32(writer, numberOf(record, 'numObjects', 'value'))
  for index, item in listOf(record, 'masters', 'value') do
    local pair = item :: { unknown }
    sub(writer, 'MAST', pair[1] :: string, encoding)
    header(writer, 'DATA', 8)
    Writer.u64(writer, numberAt(pair, 2, `masters[{index}]`))
  end
end

Encoders.GameSetting = function(writer, record, encoding)
  sub(writer, 'NAME', stringOf(record, 'id', 'value'), encoding)
  local value = tableOf(record, 'value', 'value')
  local kind = value.type
  if kind == 'String' then
    tag(writer, 'STRV')
    writeExact(writer, stringOf(value, 'data', 'value'), encoding)
  elseif kind == 'Float' then
    header(writer, 'FLTV', 4)
    Writer.f32(writer, numberOf(value, 'data', 'value'))
  elseif kind == 'Integer' then
    header(writer, 'INTV', 4)
    Writer.i32(writer, numberOf(value, 'data', 'value'))
  else
    fail(
      `value.value.type: unknown variant '{tostring(kind)}', expected one of Float, Integer, String`
    )
  end
end

local GlobalTypes = { Float = 102, Long = 108, Short = 115 }

Encoders.GlobalVariable = function(writer, record, encoding, bits)
  local id = stringOf(record, 'id', 'value')
  sub(writer, 'NAME', id, encoding)
  local value = tableOf(record, 'value', 'value')
  local kind = value.type :: string
  local code = GlobalTypes[kind]
  if not code then
    fail(`value.value.type: unknown variant '{tostring(kind)}', expected one of Float, Long, Short`)
  end

  local data = numberOf(value, 'data', 'value')
  header(writer, 'FNAM', 1)
  Writer.u8(writer, code)
  header(writer, 'FLTV', 4)
  Writer.f32(writer, data)
  dele(writer, bits)
  -- Disallow values with known precision errors.
  if kind ~= 'Float' then
    local scratch = buffer.create(4)
    buffer.writef32(scratch, 0, data)
    if buffer.readf32(scratch, 0) ~= data then fail(`GlobalVariable precision error: {id}`) end
  end
end

Encoders.Class = function(writer, record, encoding, bits)
  sub(writer, 'NAME', stringOf(record, 'id', 'value'), encoding)
  opt(writer, 'FNAM', stringOf(record, 'name', 'value'), encoding)
  local data = tableOf(record, 'data', 'value')
  header(writer, 'CLDT', 60)
  Writer.i32(writer, enum(Enums.AttributeId, data, 'attribute1', 'data'))
  Writer.i32(writer, enum(Enums.AttributeId, data, 'attribute2', 'data'))
  Writer.i32(writer, enum(Enums.Specialization, data, 'specialization', 'data'))
  for index = 1, 5 do
    Writer.i32(writer, enum(Enums.SkillId, data, `minor{index}`, 'data'))
    Writer.i32(writer, enum(Enums.SkillId, data, `major{index}`, 'data'))
  end

  Writer.u32(writer, flags(Flags.ClassFlags, data, 'flags', 'data'))
  Writer.u32(writer, flags(Flags.ServiceFlags, data, 'services', 'data'))
  local description = stringOf(record, 'description', 'value')
  if description ~= '' then
    tag(writer, 'DESC')
    writeExact(writer, description, encoding)
  end

  dele(writer, bits)
end

Encoders.Faction = function(writer, record, encoding, bits)
  sub(writer, 'NAME', stringOf(record, 'id', 'value'), encoding)
  opt(writer, 'FNAM', stringOf(record, 'name', 'value'), encoding)
  for _, name in listOf(record, 'rankNames', 'value') do
    header(writer, 'RNAM', 32)
    writeFixed(writer, name :: string, 32, encoding)
  end

  local data = tableOf(record, 'data', 'value')
  header(writer, 'FADT', 240)
  for _, attribute in listOf(data, 'favoredAttributes', 'data') do
    Writer.i32(writer, Schema.valueOf(Enums.AttributeId, attribute, 'data.favoredAttributes'))
  end

  for index, item in listOf(data, 'requirements', 'data') do
    local requirement = item :: Value
    local path = `data.requirements[{index}]`
    i32s(writer, listOf(requirement, 'attributes', path), 2, path)
    Writer.i32(writer, numberOf(requirement, 'primarySkill', path))
    Writer.i32(writer, numberOf(requirement, 'favoredSkill', path))
    Writer.i32(writer, numberOf(requirement, 'reputation', path))
  end

  for _, skill in listOf(data, 'favoredSkills', 'data') do
    Writer.i32(writer, Schema.valueOf(Enums.SkillId, skill, 'data.favoredSkills'))
  end

  Writer.u32(writer, flags(Flags.FactionFlags, data, 'flags', 'data'))
  for index, item in listOf(record, 'reactions', 'value') do
    local reaction = item :: Value
    sub(writer, 'ANAM', stringOf(reaction, 'faction', `reactions[{index}]`), encoding)
    header(writer, 'INTV', 4)
    Writer.i32(writer, numberOf(reaction, 'reaction', `reactions[{index}]`))
  end

  dele(writer, bits)
end

Encoders.Race = function(writer, record, encoding, bits)
  sub(writer, 'NAME', stringOf(record, 'id', 'value'), encoding)
  opt(writer, 'FNAM', stringOf(record, 'name', 'value'), encoding)
  local data = tableOf(record, 'data', 'value')
  header(writer, 'RADT', 140)
  local bonuses = tableOf(data, 'skillBonuses', 'data')
  for index = 0, 6 do
    Writer.i32(writer, enum(Enums.SkillId, bonuses, `skill_{index}`, 'data.skillBonuses'))
    Writer.i32(writer, numberOf(bonuses, `bonus_{index}`, 'data.skillBonuses'))
  end

  for _, key in
    {
      'strength',
      'intelligence',
      'willpower',
      'agility',
      'speed',
      'endurance',
      'personality',
      'luck',
    }

  do
    i32s(writer, listOf(data, key, 'data'), 2, `data.{key}`)
  end

  f32s(writer, listOf(data, 'height', 'data'), 2, 'data.height')
  f32s(writer, listOf(data, 'weight', 'data'), 2, 'data.weight')
  Writer.u32(writer, flags(Flags.RaceFlags, data, 'flags', 'data'))
  spells(writer, record, encoding)
  local description = stringOf(record, 'description', 'value')
  if description ~= '' then
    tag(writer, 'DESC')
    writeExact(writer, description, encoding)
  end

  dele(writer, bits)
end

Encoders.Sound = function(writer, record, encoding, bits)
  sub(writer, 'NAME', stringOf(record, 'id', 'value'), encoding)
  opt(writer, 'FNAM', stringOf(record, 'soundPath', 'value'), encoding)
  local data = tableOf(record, 'data', 'value')
  header(writer, 'DATA', 3)
  Writer.u8(writer, numberOf(data, 'volume', 'data'))
  u8s(writer, listOf(data, 'range', 'data'), 2, 'data.range')
  dele(writer, bits)
end

Encoders.SoundGen = function(writer, record, encoding, bits)
  sub(writer, 'NAME', stringOf(record, 'id', 'value'), encoding)
  header(writer, 'DATA', 4)
  Writer.u32(writer, enum(Enums.SoundGenType, record, 'soundGenType', 'value'))
  opt(writer, 'CNAM', stringOf(record, 'creature', 'value'), encoding)
  opt(writer, 'SNAM', stringOf(record, 'sound', 'value'), encoding)
  dele(writer, bits)
end

Encoders.Skill = function(writer, record, encoding, bits)
  header(writer, 'INDX', 4)
  Writer.i32(writer, enum(Enums.SkillId, record, 'skillId', 'value'))
  local data = tableOf(record, 'data', 'value')
  header(writer, 'SKDT', 24)
  Writer.i32(writer, numberOf(data, 'governingAttribute', 'data'))
  Writer.i32(writer, numberOf(data, 'specialization', 'data'))
  f32s(writer, listOf(data, 'actions', 'data'), 4, 'data.actions')
  local description = stringOf(record, 'description', 'value')
  if description ~= '' then
    tag(writer, 'DESC')
    writeExact(writer, description, encoding)
  end

  dele(writer, bits)
end

Encoders.MagicEffect = function(writer, record, encoding, bits)
  header(writer, 'INDX', 4)
  Writer.i32(writer, enum(Enums.EffectId, record, 'effectId', 'value'))
  local data = tableOf(record, 'data', 'value')
  header(writer, 'MEDT', 36)
  Writer.u32(writer, enum(Enums.EffectSchool, data, 'school', 'data'))
  Writer.f32(writer, numberOf(data, 'baseCost', 'data'))
  Writer.u32(writer, flags(Flags.MagicEffectFlags, data, 'flags', 'data'))
  i32s(writer, listOf(data, 'color', 'data'), 3, 'data.color')
  Writer.f32(writer, numberOf(data, 'speed', 'data'))
  Writer.f32(writer, numberOf(data, 'size', 'data'))
  Writer.f32(writer, numberOf(data, 'sizeCap', 'data'))
  for _, pair in
    {
      { 'ITEX', 'icon' },
      { 'PTEX', 'texture' },
      { 'BSND', 'boltSound' },
      { 'CSND', 'castSound' },
      { 'HSND', 'hitSound' },
      { 'ASND', 'areaSound' },
      { 'CVFX', 'castVisual' },
      { 'BVFX', 'boltVisual' },
      { 'HVFX', 'hitVisual' },
      { 'AVFX', 'areaVisual' },
    }

  do
    opt(writer, pair[1], stringOf(record, pair[2], 'value'), encoding)
  end

  local description = stringOf(record, 'description', 'value')
  if description ~= '' then
    tag(writer, 'DESC')
    writeExact(writer, description, encoding)
  end

  dele(writer, bits)
end

--- A `Vec<u8>` or `Vec<u32>` blob as jess-omwaddon writes it, with its length first; whether the
--- vector it holds is empty.
local function isEmptyBlob(text: string): boolean return text == 'AAAAAA==' end

Encoders.Script = function(writer, record, encoding, bits)
  local scriptHeader = tableOf(record, 'header', 'value')
  header(writer, 'SCHD', 52)
  writeFixed(writer, stringOf(record, 'id', 'value'), 32, encoding)
  for _, key in { 'numShorts', 'numLongs', 'numFloats', 'bytecodeLength', 'variablesLength' } do
    Writer.u32(writer, numberOf(scriptHeader, key, 'header'))
  end

  local variables = stringOf(record, 'variables', 'value')
  if not isEmptyBlob(variables) then
    tag(writer, 'SCVR')
    blobWithLength(writer, variables, 'variables')
  end

  local bytecode = stringOf(record, 'bytecode', 'value')
  if not isEmptyBlob(bytecode) then
    tag(writer, 'SCDT')
    blobWithLength(writer, bytecode, 'bytecode')
  end

  local text = stringOf(record, 'text', 'value')
  if text ~= '' then
    tag(writer, 'SCTX')
    writeExact(writer, text, encoding)
  end

  dele(writer, bits)
end

Encoders.Region = function(writer, record, encoding, bits)
  sub(writer, 'NAME', stringOf(record, 'id', 'value'), encoding)
  opt(writer, 'FNAM', stringOf(record, 'name', 'value'), encoding)
  local chances = tableOf(record, 'weatherChances', 'value')
  tag(writer, 'WEAT')
  Writer.u32(writer, 10)
  for _, key in
    {
      'clear',
      'cloudy',
      'foggy',
      'overcast',
      'rain',
      'thunder',
      'ash',
      'blight',
      'snow',
      'blizzard',
    }

  do
    Writer.u8(writer, numberOf(chances, key, 'weatherChances'))
  end

  opt(writer, 'BNAM', stringOf(record, 'sleepCreature', 'value'), encoding)
  header(writer, 'CNAM', 4)
  u8s(writer, listOf(record, 'mapColor', 'value'), 4, 'mapColor')
  for index, item in listOf(record, 'sounds', 'value') do
    local pair = item :: { unknown }
    header(writer, 'SNAM', 33)
    writeFixed(writer, pair[1] :: string, 32, encoding)
    Writer.u8(writer, numberAt(pair, 2, `sounds[{index}]`))
  end

  dele(writer, bits)
end

Encoders.Birthsign = function(writer, record, encoding, bits)
  sub(writer, 'NAME', stringOf(record, 'id', 'value'), encoding)
  opt(writer, 'FNAM', stringOf(record, 'name', 'value'), encoding)
  opt(writer, 'TNAM', stringOf(record, 'texture', 'value'), encoding)
  opt(writer, 'DESC', stringOf(record, 'description', 'value'), encoding)
  spells(writer, record, encoding)
  dele(writer, bits)
end

Encoders.StartScript = function(writer, record, encoding, bits)
  sub(writer, 'DATA', stringOf(record, 'id', 'value'), encoding)
  opt(writer, 'NAME', stringOf(record, 'script', 'value'), encoding)
  dele(writer, bits)
end

Encoders.LandscapeTexture = function(writer, record, encoding, bits)
  sub(writer, 'NAME', stringOf(record, 'id', 'value'), encoding)
  header(writer, 'INTV', 4)
  Writer.u32(writer, numberOf(record, 'index', 'value'))
  opt(writer, 'DATA', stringOf(record, 'fileName', 'value'), encoding)
  dele(writer, bits)
end

Encoders.Spell = function(writer, record, encoding, bits)
  sub(writer, 'NAME', stringOf(record, 'id', 'value'), encoding)
  opt(writer, 'FNAM', stringOf(record, 'name', 'value'), encoding)
  local data = tableOf(record, 'data', 'value')
  header(writer, 'SPDT', 12)
  Writer.u32(writer, enum(Enums.SpellType, data, 'spellType', 'data'))
  Writer.u32(writer, numberOf(data, 'cost', 'data'))
  Writer.u32(writer, flags(Flags.SpellFlags, data, 'flags', 'data'))
  effects(writer, record)
  dele(writer, bits)
end

Encoders.Static = function(writer, record, encoding, bits)
  sub(writer, 'NAME', stringOf(record, 'id', 'value'), encoding)
  opt(writer, 'MODL', stringOf(record, 'mesh', 'value'), encoding)
  dele(writer, bits)
end

Encoders.Door = function(writer, record, encoding, bits)
  itemHead(writer, record, encoding)
  opt(writer, 'SCRI', stringOf(record, 'script', 'value'), encoding)
  opt(writer, 'SNAM', stringOf(record, 'openSound', 'value'), encoding)
  opt(writer, 'ANAM', stringOf(record, 'closeSound', 'value'), encoding)
  dele(writer, bits)
end

Encoders.MiscItem = function(writer, record, encoding, bits)
  itemHead(writer, record, encoding)
  local data = tableOf(record, 'data', 'value')
  header(writer, 'MCDT', 12)
  Writer.f32(writer, numberOf(data, 'weight', 'data'))
  Writer.u32(writer, numberOf(data, 'value', 'data'))
  Writer.u32(writer, flags(Flags.MiscItemFlags, data, 'flags', 'data'))
  itemTail(writer, record, encoding)
  dele(writer, bits)
end

Encoders.Weapon = function(writer, record, encoding, bits)
  itemHead(writer, record, encoding)
  local data = tableOf(record, 'data', 'value')
  header(writer, 'WPDT', 32)
  Writer.f32(writer, numberOf(data, 'weight', 'data'))
  Writer.u32(writer, numberOf(data, 'value', 'data'))
  Writer.u16(writer, enum(Enums.WeaponType, data, 'weaponType', 'data'))
  Writer.u16(writer, numberOf(data, 'health', 'data'))
  Writer.f32(writer, numberOf(data, 'speed', 'data'))
  Writer.f32(writer, numberOf(data, 'reach', 'data'))
  Writer.u16(writer, numberOf(data, 'enchantment', 'data'))
  for _, key in { 'chopMin', 'chopMax', 'slashMin', 'slashMax', 'thrustMin', 'thrustMax' } do
    Writer.u8(writer, numberOf(data, key, 'data'))
  end

  Writer.u32(writer, flags(Flags.WeaponFlags, data, 'flags', 'data'))
  itemTail(writer, record, encoding)
  opt(writer, 'ENAM', stringOf(record, 'enchanting', 'value'), encoding)
  dele(writer, bits)
end

Encoders.Container = function(writer, record, encoding, bits)
  itemHead(writer, record, encoding)
  header(writer, 'CNDT', 4)
  Writer.f32(writer, numberOf(record, 'encumbrance', 'value'))
  header(writer, 'FLAG', 4)
  Writer.u32(writer, flags(Flags.ContainerFlags, record, 'containerFlags', 'value'))
  opt(writer, 'SCRI', stringOf(record, 'script', 'value'), encoding)
  inventory(writer, record, encoding)
  dele(writer, bits)
end

--- An actor's FLAG: its flags with the blood type in bits 10 to 12.
local function actorFlag(writer: Writer, set: Schema.Flags, record: Value, key: string)
  local bits = bit32.band(flags(set, record, key, 'value'), bit32.bnot(0x1c00))
  header(writer, 'FLAG', 4)
  Writer.u32(
    writer,
    bit32.bor(bits, bit32.lshift(bit32.band(numberOf(record, 'bloodType', 'value'), 7), 10))
  )
end

Encoders.Creature = function(writer, record, encoding, bits)
  sub(writer, 'NAME', stringOf(record, 'id', 'value'), encoding)
  opt(writer, 'MODL', stringOf(record, 'mesh', 'value'), encoding)
  opt(writer, 'CNAM', stringOf(record, 'sound', 'value'), encoding)
  opt(writer, 'FNAM', stringOf(record, 'name', 'value'), encoding)
  opt(writer, 'SCRI', stringOf(record, 'script', 'value'), encoding)
  local data = tableOf(record, 'data', 'value')
  header(writer, 'NPDT', 96)
  Writer.u32(writer, enum(Enums.CreatureType, data, 'creatureType', 'data'))
  for _, key in
    {
      'level',
      'strength',
      'intelligence',
      'willpower',
      'agility',
      'speed',
      'endurance',
      'personality',
      'luck',
      'health',
      'magicka',
      'fatigue',
      'soul',
      'combat',
      'magic',
      'stealth',
    }

  do
    Writer.u32(writer, numberOf(data, key, 'data'))
  end

  for _, key in { 'attack1', 'attack2', 'attack3' } do
    local pair = listOf(data, key, 'data')
    Writer.u32(writer, numberAt(pair, 1, `data.{key}`))
    Writer.u32(writer, numberAt(pair, 2, `data.{key}`))
  end

  Writer.u32(writer, numberOf(data, 'gold', 'data'))
  actorFlag(writer, Flags.CreatureFlags, record, 'creatureFlags')
  local scale = record.scale :: number?
  if scale then
    local clamped, default = clampScale(scale)
    if not default then
      header(writer, 'XSCL', 4)
      Writer.f32(writer, clamped)
    end
  end

  inventory(writer, record, encoding)
  spells(writer, record, encoding)
  aiData(writer, record)
  travel(writer, record, encoding)
  packages(writer, record, encoding)
  dele(writer, bits)
end

Encoders.Npc = function(writer, record, encoding, bits)
  sub(writer, 'NAME', stringOf(record, 'id', 'value'), encoding)
  for _, pair in
    {
      { 'MODL', 'mesh' },
      { 'FNAM', 'name' },
      { 'RNAM', 'race' },
      { 'CNAM', 'class' },
      { 'ANAM', 'faction' },
      { 'BNAM', 'head' },
      { 'KNAM', 'hair' },
      { 'SCRI', 'script' },
    }

  do
    opt(writer, pair[1], stringOf(record, pair[2], 'value'), encoding)
  end

  local data = tableOf(record, 'data', 'value')
  tag(writer, 'NPDT')
  local stats = data.stats :: Value?
  if stats then
    Writer.u32(writer, 52)
    Writer.u16(writer, numberOf(data, 'level', 'data') % 65536)
    u8s(writer, listOf(stats, 'attributes', 'data.stats'), 8, 'data.stats.attributes')
    u8s(writer, listOf(stats, 'skills', 'data.stats'), 27, 'data.stats.skills')
    Writer.zeros(writer, 1)
    Writer.u16(writer, numberOf(stats, 'health', 'data.stats'))
    Writer.u16(writer, numberOf(stats, 'magicka', 'data.stats'))
    Writer.u16(writer, numberOf(stats, 'fatigue', 'data.stats'))
    Writer.u8(writer, numberOf(data, 'disposition', 'data') % 256)
    Writer.u8(writer, numberOf(data, 'reputation', 'data') % 256)
    Writer.u8(writer, numberOf(data, 'rank', 'data') % 256)
  else
    Writer.u32(writer, 12)
    Writer.u16(writer, numberOf(data, 'level', 'data') % 65536)
    Writer.u8(writer, numberOf(data, 'disposition', 'data') % 256)
    Writer.u8(writer, numberOf(data, 'reputation', 'data') % 256)
    Writer.u8(writer, numberOf(data, 'rank', 'data') % 256)
    Writer.zeros(writer, 2)
  end

  Writer.zeros(writer, 1)
  Writer.u32(writer, numberOf(data, 'gold', 'data'))
  actorFlag(writer, Flags.NpcFlags, record, 'npcFlags')
  inventory(writer, record, encoding)
  spells(writer, record, encoding)
  aiData(writer, record)
  travel(writer, record, encoding)
  packages(writer, record, encoding)
  dele(writer, bits)
end

Encoders.Bodypart = function(writer, record, encoding, bits)
  sub(writer, 'NAME', stringOf(record, 'id', 'value'), encoding)
  opt(writer, 'MODL', stringOf(record, 'mesh', 'value'), encoding)
  opt(writer, 'FNAM', stringOf(record, 'race', 'value'), encoding)
  local data = tableOf(record, 'data', 'value')
  header(writer, 'BYDT', 4)
  Writer.u8(writer, enum(Enums.BodypartId, data, 'part', 'data'))
  Writer.u8(writer, if data.vampire then 1 else 0)
  Writer.u8(writer, flags(Flags.BodypartFlags, data, 'flags', 'data'))
  Writer.u8(writer, enum(Enums.BodypartType, data, 'bodypartType', 'data'))
  dele(writer, bits)
end

Encoders.Light = function(writer, record, encoding, bits)
  itemHead(writer, record, encoding)
  opt(writer, 'ITEX', stringOf(record, 'icon', 'value'), encoding)
  local data = tableOf(record, 'data', 'value')
  header(writer, 'LHDT', 24)
  Writer.f32(writer, numberOf(data, 'weight', 'data'))
  Writer.u32(writer, numberOf(data, 'value', 'data'))
  Writer.i32(writer, numberOf(data, 'time', 'data'))
  Writer.u32(writer, numberOf(data, 'radius', 'data'))
  u8s(writer, listOf(data, 'color', 'data'), 4, 'data.color')
  Writer.u32(writer, flags(Flags.LightFlags, data, 'flags', 'data'))
  opt(writer, 'SCRI', stringOf(record, 'script', 'value'), encoding)
  opt(writer, 'SNAM', stringOf(record, 'sound', 'value'), encoding)
  dele(writer, bits)
end

Encoders.Enchanting = function(writer, record, encoding, bits)
  sub(writer, 'NAME', stringOf(record, 'id', 'value'), encoding)
  local data = tableOf(record, 'data', 'value')
  header(writer, 'ENDT', 16)
  Writer.u32(writer, enum(Enums.EnchantType, data, 'enchantType', 'data'))
  Writer.u32(writer, numberOf(data, 'cost', 'data'))
  Writer.u32(writer, numberOf(data, 'maxCharge', 'data'))
  Writer.u32(writer, flags(Flags.EnchantingFlags, data, 'flags', 'data'))
  effects(writer, record)
  dele(writer, bits)
end

Encoders.Armor = function(writer, record, encoding, bits)
  itemHead(writer, record, encoding)
  opt(writer, 'SCRI', stringOf(record, 'script', 'value'), encoding)
  local data = tableOf(record, 'data', 'value')
  header(writer, 'AODT', 24)
  Writer.u32(writer, enum(Enums.ArmorType, data, 'armorType', 'data'))
  Writer.f32(writer, numberOf(data, 'weight', 'data'))
  for _, key in { 'value', 'health', 'enchantment', 'armorRating' } do
    Writer.u32(writer, numberOf(data, key, 'data'))
  end

  opt(writer, 'ITEX', stringOf(record, 'icon', 'value'), encoding)
  bipedObjects(writer, record, encoding)
  opt(writer, 'ENAM', stringOf(record, 'enchanting', 'value'), encoding)
  dele(writer, bits)
end

Encoders.Clothing = function(writer, record, encoding, bits)
  itemHead(writer, record, encoding)
  local data = tableOf(record, 'data', 'value')
  header(writer, 'CTDT', 12)
  Writer.u32(writer, enum(Enums.ClothingType, data, 'clothingType', 'data'))
  Writer.f32(writer, numberOf(data, 'weight', 'data'))
  Writer.u16(writer, numberOf(data, 'value', 'data'))
  Writer.u16(writer, numberOf(data, 'enchantment', 'data'))
  itemTail(writer, record, encoding)
  bipedObjects(writer, record, encoding)
  opt(writer, 'ENAM', stringOf(record, 'enchanting', 'value'), encoding)
  dele(writer, bits)
end

Encoders.RepairItem = function(writer, record, encoding, bits)
  itemHead(writer, record, encoding)
  local data = tableOf(record, 'data', 'value')
  header(writer, 'RIDT', 16)
  Writer.f32(writer, numberOf(data, 'weight', 'data'))
  Writer.u32(writer, numberOf(data, 'value', 'data'))
  Writer.u32(writer, numberOf(data, 'uses', 'data'))
  Writer.f32(writer, numberOf(data, 'quality', 'data'))
  itemTail(writer, record, encoding)
  dele(writer, bits)
end

Encoders.Activator = function(writer, record, encoding, bits)
  itemHead(writer, record, encoding)
  opt(writer, 'SCRI', stringOf(record, 'script', 'value'), encoding)
  dele(writer, bits)
end

Encoders.Apparatus = function(writer, record, encoding, bits)
  itemHead(writer, record, encoding)
  opt(writer, 'SCRI', stringOf(record, 'script', 'value'), encoding)
  local data = tableOf(record, 'data', 'value')
  header(writer, 'AADT', 16)
  Writer.u32(writer, enum(Enums.ApparatusType, data, 'apparatusType', 'data'))
  Writer.f32(writer, numberOf(data, 'quality', 'data'))
  Writer.f32(writer, numberOf(data, 'weight', 'data'))
  Writer.u32(writer, numberOf(data, 'value', 'data'))
  opt(writer, 'ITEX', stringOf(record, 'icon', 'value'), encoding)
  dele(writer, bits)
end

local function tool(dataTag: string): Encoder
  return function(writer, record, encoding, bits)
    itemHead(writer, record, encoding)
    local data = tableOf(record, 'data', 'value')
    header(writer, dataTag, 16)
    Writer.f32(writer, numberOf(data, 'weight', 'data'))
    Writer.u32(writer, numberOf(data, 'value', 'data'))
    Writer.f32(writer, numberOf(data, 'quality', 'data'))
    Writer.u32(writer, numberOf(data, 'uses', 'data'))
    itemTail(writer, record, encoding)
    dele(writer, bits)
  end
end

Encoders.Lockpick = tool 'LKDT'
Encoders.Probe = tool 'PBDT'

Encoders.Ingredient = function(writer, record, encoding, bits)
  itemHead(writer, record, encoding)
  local data = tableOf(record, 'data', 'value')
  header(writer, 'IRDT', 56)
  Writer.f32(writer, numberOf(data, 'weight', 'data'))
  Writer.u32(writer, numberOf(data, 'value', 'data'))
  for _, pair in
    {
      { 'effects', Enums.EffectId },
      { 'skills', Enums.SkillId },
      { 'attributes', Enums.AttributeId },
    }

  do
    local key = pair[1] :: string
    for _, item in listOf(data, key, 'data') do
      Writer.i32(writer, Schema.valueOf(pair[2] :: Schema.Enum, item, `data.{key}`))
    end
  end

  itemTail(writer, record, encoding)
  dele(writer, bits)
end

Encoders.Book = function(writer, record, encoding, bits)
  itemHead(writer, record, encoding)
  local data = tableOf(record, 'data', 'value')
  header(writer, 'BKDT', 20)
  Writer.f32(writer, numberOf(data, 'weight', 'data'))
  Writer.u32(writer, numberOf(data, 'value', 'data'))
  Writer.u32(writer, enum(Enums.BookType, data, 'bookType', 'data'))
  Writer.i32(writer, enum(Enums.SkillId, data, 'skill', 'data'))
  Writer.u32(writer, numberOf(data, 'enchantment', 'data'))
  itemTail(writer, record, encoding)
  local text = stringOf(record, 'text', 'value')
  if text ~= '' then
    tag(writer, 'TEXT')
    writeExact(writer, text, encoding)
  end

  opt(writer, 'ENAM', stringOf(record, 'enchanting', 'value'), encoding)
  dele(writer, bits)
end

Encoders.Alchemy = function(writer, record, encoding, bits)
  sub(writer, 'NAME', stringOf(record, 'id', 'value'), encoding)
  opt(writer, 'MODL', stringOf(record, 'mesh', 'value'), encoding)
  opt(writer, 'TEXT', stringOf(record, 'icon', 'value'), encoding)
  opt(writer, 'SCRI', stringOf(record, 'script', 'value'), encoding)
  opt(writer, 'FNAM', stringOf(record, 'name', 'value'), encoding)
  local data = tableOf(record, 'data', 'value')
  header(writer, 'ALDT', 12)
  Writer.f32(writer, numberOf(data, 'weight', 'data'))
  Writer.u32(writer, numberOf(data, 'value', 'data'))
  Writer.u32(writer, flags(Flags.AlchemyFlags, data, 'flags', 'data'))
  effects(writer, record)
  dele(writer, bits)
end

local function leveled(
  flagField: string,
  set: Schema.Flags,
  listField: string,
  entryTag: string
): Encoder
  return function(writer, record, encoding, bits)
    sub(writer, 'NAME', stringOf(record, 'id', 'value'), encoding)
    header(writer, 'DATA', 4)
    Writer.u32(writer, flags(set, record, flagField, 'value'))
    header(writer, 'NNAM', 1)
    Writer.u8(writer, numberOf(record, 'chanceNone', 'value'))
    local entries = listOf(record, listField, 'value')
    if #entries > 0 then
      header(writer, 'INDX', 4)
      Writer.u32(writer, #entries)
      for index, item in entries do
        local pair = item :: { unknown }
        sub(writer, entryTag, pair[1] :: string, encoding)
        header(writer, 'INTV', 2)
        Writer.u16(writer, numberAt(pair, 2, `{listField}[{index}]`))
      end
    end

    dele(writer, bits)
  end
end

Encoders.LeveledItem = leveled('leveledItemFlags', Flags.LeveledItemFlags, 'items', 'INAM')
Encoders.LeveledCreature =
  leveled('leveledCreatureFlags', Flags.LeveledCreatureFlags, 'creatures', 'CNAM')

--[[ CELL ]]

local persistent = References.persistent

local function reference(writer: Writer, ref: Value, encoding: string, path: string)
  sub(writer, 'NAME', stringOf(ref, 'id', path), encoding)
  local blocked = ref.blocked :: number?
  if blocked then
    header(writer, 'UNAM', 1)
    Writer.u8(writer, blocked)
  end

  local scale = ref.scale :: number?
  if scale then
    local clamped, default = clampScale(scale)
    if not default or numberOf(ref, 'mastIndex', path) ~= 0 then
      header(writer, 'XSCL', 4)
      Writer.f32(writer, clamped)
    end
  end

  for _, pair in { { 'ANAM', 'owner' }, { 'BNAM', 'ownerGlobal' }, { 'CNAM', 'ownerFaction' } } do
    local value = ref[pair[2]] :: string?
    if value then sub(writer, pair[1], value, encoding) end
  end

  local rank = ref.ownerFactionRank :: number?
  if rank then
    header(writer, 'INDX', 4)
    Writer.u32(writer, rank)
  end

  local soul = ref.soul :: string?
  if soul then sub(writer, 'XSOL', soul, encoding) end

  local charge = ref.chargeLeft :: number?
  if charge then
    header(writer, 'XCHG', 4)
    Writer.u32(writer, charge)
  end

  local health = ref.healthLeft :: number?
  if health then
    header(writer, 'INTV', 4)
    Writer.i32(writer, health)
  end

  local count = ref.objectCount :: number?
  if count then
    header(writer, 'NAM9', 4)
    Writer.u32(writer, count)
  end

  local destination = ref.destination :: Value?
  if destination then
    header(writer, 'DODT', 24)
    f32s(writer, listOf(destination, 'translation', path), 3, `{path}.destination.translation`)
    f32s(writer, listOf(destination, 'rotation', path), 3, `{path}.destination.rotation`)
    opt(writer, 'DNAM', stringOf(destination, 'cell', path), encoding)
  end

  local lock = ref.lockLevel :: number?
  if lock then
    header(writer, 'FLTV', 4)
    Writer.i32(writer, lock)
  end

  for _, pair in { { 'KNAM', 'key' }, { 'TNAM', 'trap' } } do
    local value = ref[pair[2]] :: string?
    if value then sub(writer, pair[1], value, encoding) end
  end

  if ref.deleted ~= nil then
    header(writer, 'DELE', 4)
    Writer.u32(writer, 0)
  else
    header(writer, 'DATA', 24)
    f32s(writer, listOf(ref, 'translation', path), 3, `{path}.translation`)
    f32s(writer, listOf(ref, 'rotation', path), 3, `{path}.rotation`)
  end
end

Encoders.Cell = function(writer, record, encoding, bits)
  sub(writer, 'NAME', stringOf(record, 'name', 'value'), encoding)
  local data = tableOf(record, 'data', 'value')
  header(writer, 'DATA', 12)
  Writer.u32(writer, flags(Flags.CellFlags, data, 'flags', 'data'))
  i32s(writer, listOf(data, 'grid', 'data'), 2, 'data.grid')
  local region = record.region :: string?
  if region then sub(writer, 'RGNN', region, encoding) end

  local color = record.mapColor :: { unknown }?
  if color then
    header(writer, 'NAM5', 4)
    u8s(writer, color, 4, 'mapColor')
  end

  local water = record.waterHeight :: number?
  if water then
    header(writer, 'WHGT', 4)
    Writer.f32(writer, water)
  end

  local atmosphere = record.atmosphereData :: Value?
  if atmosphere then
    header(writer, 'AMBI', 16)
    u8s(
      writer,
      listOf(atmosphere, 'ambientColor', 'atmosphereData'),
      4,
      'atmosphereData.ambientColor'
    )
    u8s(
      writer,
      listOf(atmosphere, 'sunlightColor', 'atmosphereData'),
      4,
      'atmosphereData.sunlightColor'
    )
    u8s(writer, listOf(atmosphere, 'fogColor', 'atmosphereData'), 4, 'atmosphereData.fogColor')
    Writer.f32(writer, numberOf(atmosphere, 'fogDensity', 'atmosphereData'))
  end

  dele(writer, bits)
  -- Keyed by (master, index) as the Rust HashMap is: a later duplicate replaces an earlier one.
  local byKey: { [number]: Value } = {}
  for index, item in listOf(record, 'references', 'value') do
    local ref = item :: Value
    local path = `references[{index}]`
    byKey[numberOf(ref, 'mastIndex', path) * 16777216 + numberOf(ref, 'refrIndex', path)] = ref
  end

  local sorted = References.ordered(byKey)
  local temporary = 0
  for index, ref in sorted do
    local path = `references[{index}]`
    local packed = bit32.bor(
      numberOf(ref, 'refrIndex', path),
      bit32.lshift(numberOf(ref, 'mastIndex', path), 24)
    )
    if temporary == 0 and not persistent(ref) then
      temporary = #sorted - index + 1
      header(writer, 'NAM0', 4)
      Writer.u32(writer, temporary)
    end

    local moved = ref.movedCell :: { unknown }?
    if moved then
      header(writer, 'MVRF', 4)
      Writer.u32(writer, packed)
      header(writer, 'CNDT', 8)
      i32s(writer, moved, 2, `{path}.movedCell`)
    end

    header(writer, 'FRMR', 4)
    Writer.u32(writer, packed)
    reference(writer, ref, encoding, path)
  end
end

--[[ LAND ]]

local function landBlob(writer: Writer, from: Value, path: string, size: number)
  local data = Schema.unbase64(stringOf(from, 'data', path), `{path}.data`)
  if buffer.len(data) ~= size then
    fail(`{path}.data: expected {size} bytes, got {buffer.len(data)}`)
  end

  Writer.copy(writer, data, 0, size)
end

Encoders.Landscape = function(writer, record, _encoding, bits)
  header(writer, 'INTV', 8)
  i32s(writer, listOf(record, 'grid', 'value'), 2, 'grid')
  local land = flags(Flags.LandscapeFlags, record, 'landscapeFlags', 'value')
  header(writer, 'DATA', 4)
  Writer.u32(writer, land)
  if bit32.btest(land, 1) then
    header(writer, 'VNML', 12675)
    landBlob(writer, tableOf(record, 'vertexNormals', 'value'), 'vertexNormals', 12675)
    local heights = tableOf(record, 'vertexHeights', 'value')
    header(writer, 'VHGT', 4232)
    Writer.f32(writer, numberOf(heights, 'offset', 'vertexHeights'))
    landBlob(writer, heights, 'vertexHeights', 4225)
    Writer.zeros(writer, 3)
  end

  if bit32.btest(land, 7) then
    header(writer, 'WNAM', 81)
    landBlob(writer, tableOf(record, 'worldMapData', 'value'), 'worldMapData', 81)
  end

  if bit32.btest(land, 2) then
    header(writer, 'VCLR', 12675)
    landBlob(writer, tableOf(record, 'vertexColors', 'value'), 'vertexColors', 12675)
  end

  if bit32.btest(land, 4) then
    header(writer, 'VTEX', 512)
    landBlob(writer, tableOf(record, 'textureIndices', 'value'), 'textureIndices', 512)
  end

  dele(writer, bits)
end

--[[ PGRD ]]

Encoders.PathGrid = function(writer, record, encoding, bits)
  local data = tableOf(record, 'data', 'value')
  header(writer, 'DATA', 12)
  i32s(writer, listOf(data, 'grid', 'data'), 2, 'data.grid')
  Writer.u16(writer, numberOf(data, 'granularity', 'data'))
  Writer.u16(writer, numberOf(data, 'pointCount', 'data'))
  sub(writer, 'NAME', stringOf(record, 'cell', 'value'), encoding)
  local points = listOf(record, 'points', 'value')
  if #points > 0 then
    header(writer, 'PGRP', #points * 16)
    for index, item in points do
      local point = item :: Value
      local path = `points[{index}]`
      i32s(writer, listOf(point, 'location', path), 3, `{path}.location`)
      Writer.u8(writer, numberOf(point, 'autoGenerated', path))
      Writer.u8(writer, numberOf(point, 'connectionCount', path))
      Writer.zeros(writer, 2)
    end
  end

  local connections = Schema.unbase64(stringOf(record, 'connections', 'value'), 'connections')
  local count = if buffer.len(connections) >= 4 then buffer.readu32(connections, 0) else 0
  if count > 0 then
    header(writer, 'PGRC', count * 4)
    Writer.copy(writer, connections, 4, count * 4)
  end

  dele(writer, bits)
end

--[[ DIAL and INFO ]]

Encoders.Dialogue = function(writer, record, encoding, bits)
  sub(writer, 'NAME', stringOf(record, 'id', 'value'), encoding)
  header(writer, 'DATA', 1)
  Writer.u8(writer, enum(Enums.DialogueType, record, 'dialogueType', 'value'))
  dele(writer, bits)
end

local QuestTags = { Name = 'QSTN', Finished = 'QSTF', Restart = 'QSTR' }

Encoders.DialogueInfo = function(writer, record, encoding, bits)
  sub(writer, 'INAM', stringOf(record, 'id', 'value'), encoding)
  sub(writer, 'PNAM', stringOf(record, 'prevId', 'value'), encoding)
  sub(writer, 'NNAM', stringOf(record, 'nextId', 'value'), encoding)
  local data = tableOf(record, 'data', 'value')
  header(writer, 'DATA', 12)
  Writer.u32(writer, enum(Enums.DialogueType, data, 'dialogueType', 'data'))
  Writer.i32(writer, numberOf(data, 'disposition', 'data'))
  Writer.u8(writer, numberOf(data, 'speakerRank', 'data') % 256)
  Writer.u8(writer, enum(Enums.Sex, data, 'speakerSex', 'data') % 256)
  Writer.u8(writer, numberOf(data, 'playerRank', 'data') % 256)
  Writer.zeros(writer, 1)
  for _, pair in
    {
      { 'ONAM', 'speakerId' },
      { 'RNAM', 'speakerRace' },
      { 'CNAM', 'speakerClass' },
      { 'FNAM', 'speakerFaction' },
      { 'ANAM', 'speakerCell' },
      { 'DNAM', 'playerFaction' },
      { 'SNAM', 'soundPath' },
    }

  do
    opt(writer, pair[1], stringOf(record, pair[2], 'value'), encoding)
  end

  local text = stringOf(record, 'text', 'value')
  if text ~= '' then
    tag(writer, 'NAME')
    writeExact(writer, text, encoding)
  end

  local state = record.questState :: string?
  if state then
    local name = QuestTags[state]
    if not name then
      fail(`value.questState: unknown variant '{state}', expected one of Finished, Name, Restart`)
    end

    header(writer, name, 1)
    Writer.u8(writer, 1)
  end

  for position, item in listOf(record, 'filters', 'value') do
    local filter = item :: Value
    local path = `filters[{position}]`
    local index = numberOf(filter, 'index', path)
    if index + 48 > 255 then fail 'DialogueInfo: Invalid filter index' end

    local id = encodeText(stringOf(filter, 'id', path), encoding)
    tag(writer, 'SCVR')
    Writer.u32(writer, #id + 5)
    Writer.u8(writer, index + 48)
    Writer.u8(writer, enum(Enums.FilterType, filter, 'filterType', path))
    Writer.u16(writer, enum(Enums.FilterFunction, filter, 'function', path))
    Writer.u8(writer, enum(Enums.FilterComparison, filter, 'comparison', path))
    Writer.string(writer, id)
    local value = tableOf(filter, 'value', path)
    if value.type == 'Integer' then
      header(writer, 'INTV', 4)
      Writer.i32(writer, numberOf(value, 'data', path))
    elseif value.type == 'Float' then
      header(writer, 'FLTV', 4)
      Writer.f32(writer, numberOf(value, 'data', path))
    else
      fail(
        `{path}.value.type: unknown variant '{tostring(value.type)}', expected one of Float, Integer`
      )
    end
  end

  local script = stringOf(record, 'scriptText', 'value')
  if script ~= '' then
    tag(writer, 'BNAM')
    writeExact(writer, script, encoding)
  end

  dele(writer, bits)
end

--[[ LUAL ]]

--- A LUAD blob: the bytes after its length, given the base64 of both.
local function luaData(writer: Writer, text: string, path: string)
  local data = Schema.unbase64(text, path)
  local length = if buffer.len(data) >= 4 then buffer.readu32(data, 0) else 0
  if length == 0 then return end

  tag(writer, 'LUAD')
  Writer.u32(writer, length)
  Writer.copy(writer, data, 4, length)
end

Encoders.ScriptConfigList = function(writer, record, encoding)
  for index, item in listOf(record, 'scripts', 'value') do
    local config = item :: Value
    local path = `scripts[{index}]`
    local scriptPath = encodeText(stringOf(config, 'path', path), encoding)
    tag(writer, 'LUAS')
    Writer.u32(writer, #scriptPath)
    Writer.string(writer, scriptPath)
    local types = listOf(config, 'types', path)
    tag(writer, 'LUAF')
    Writer.u32(writer, 4 + 4 * #types)
    Writer.u32(writer, flags(Flags.OMWScriptAttachFlag, config, 'flags', path))
    for _, kind in types do
      Writer.string(writer, kind :: string)
    end

    luaData(writer, stringOf(config, 'initData', path), `{path}.initData`)
    for recordIndex, entry in listOf(config, 'records', path) do
      local scriptRecord = entry :: Value
      local id = stringOf(scriptRecord, 'id', `{path}.records[{recordIndex}]`)
      tag(writer, 'LUAR')
      Writer.u32(writer, #id + 1)
      Writer.u8(writer, if scriptRecord.attach then 1 else 0)
      Writer.string(writer, id)
      luaData(
        writer,
        stringOf(scriptRecord, 'data', `{path}.records[{recordIndex}]`),
        `{path}.records[{recordIndex}].data`
      )
    end

    for instanceIndex, entry in listOf(config, 'instances', path) do
      local instance = entry :: Value
      local at = `{path}.instances[{instanceIndex}]`
      tag(writer, 'LUAI')
      Writer.u32(writer, 9)
      Writer.u8(writer, if instance.attach then 1 else 0)
      Writer.u32(writer, numberOf(instance, 'refIdx', at))
      Writer.i32(writer, numberOf(instance, 'mastIdx', at))
      luaData(writer, stringOf(instance, 'data', at), `{at}.data`)
    end
  end
end

--[[ Records ]]

local TagsByName: { [string]: string } = {}
for _, entry in Decode.specs do
  TagsByName[entry.name] = entry.tag
end

--- A record value's bytes, header included, text in `encoding`. `value.type` names its record type.
local function encode(value: Value, encoding: string?): buffer
  local codePage = encoding or 'win1252'
  local name = value.type
  if type(name) ~= 'string' then
    return fail(`value.type: expected a record type name, got {type(name)}`)
  end

  local recordTag = TagsByName[name]
  local encoder = Encoders[name]
  if not recordTag or not encoder then return fail(`unknown record type '{name}'`) end

  local record = merge(Decode.default(name), value) :: Value
  local bits = Schema.flagBits(Flags.ObjectFlags, record.flags, 'value.flags')
  local writer = Writer.new(256)
  tag(writer, recordTag)
  Writer.u32(writer, 0)
  Writer.u32(writer, 0)
  Writer.u32(writer, bits)
  encoder(writer, record, codePage, bits)
  local out = Writer.finish(writer)
  buffer.writeu32(out, 4, buffer.len(out) - 16)
  return out
end

return table.freeze { encode = encode, merge = merge }
