--!strict
--!native
-- The TES3 spine, timed through `@tes3`: framing, saving, record identity, the typed codec, CELL
-- references, LAND terrain, write-back, and OpenMW's Lua payloads. One line per workload,
-- `name<TAB>seconds per call`, the median of seven batches. Run on a release build:
--   jess run --package . --package-path .. --capability filesystem.read bench/bench.luau [filter]
local tes3 = require '@tes3'

-- A build without the verified toolchain runs Luau slower than a release does, so a number from
-- one says nothing about what ships.
if not jess.bench.verified then
  error('tes3 bench: this jess was built without the verified toolchain: measure on a release build', 0)
end

local filter: string? = ...
local only = if filter and filter ~= '' then filter else nil

--- The package's folder, from this file's chunk name.
local function root(): string
  local source = debug.info(1, 's')
  local first = string.sub(source, 1, 1)
  local path = if first == '@' or first == '=' then string.sub(source, 2) else source

  return string.match(path, '^(.*)/bench/[^/]*$') or '.'
end

local function median(samples: { number }): number
  table.sort(samples)
  return samples[(#samples + 1) // 2]
end

--- Seconds per call of `body`: warmed up, then the median of seven batches of a size that takes
--- about a tenth of a second, a full collection between batches.
local function measure(body: () -> number): number
  jess.bench.collect()
  body()
  local start = os.clock()
  body()
  local once = math.max(os.clock() - start, 1e-7)
  local iterations = math.max(1, math.floor(0.1 / once))
  local samples = table.create(7, 0)

  for batch = 1, 7 do
    jess.bench.collect()
    start = os.clock()

    for _ = 1, iterations do
      body()
    end

    samples[batch] = (os.clock() - start) / iterations
  end

  return median(samples)
end

--- Times `body`, which answers with a number saying what it did: `expected`, or the workload is
--- broken and its time means nothing.
local function workload(name: string, expected: number, body: () -> number)
  if only and not string.find(name, only, 1, true) then return end

  local got = body()
  if got ~= expected then error(`tes3 bench: '{name}' answered {got}, not {expected}`, 0) end

  print(`{name}\t{string.format('%.9f', measure(body))}`)
end

local random = 0x2545f491

local function nextRandom(): number
  random = bit32.bxor(random, bit32.lshift(random, 13))
  random = bit32.bxor(random, bit32.rshift(random, 17))
  random = bit32.bxor(random, bit32.lshift(random, 5))
  return random
end

local function u32(value: number): string return string.pack('<I4', value) end

local function subrecord(tag: string, payload: string): string
  return tag .. u32(#payload) .. payload
end

local function record(tag: string, payload: string): string
  return tag .. u32(#payload) .. u32(0) .. u32(0) .. payload
end

--- A default record of type `name` with `fields` set, encoded.
local function typed(name: string, fields: { [string]: unknown }): string
  local value = assert(tes3.default(name))

  for key, field in fields do
    value[key] = field
  end

  return buffer.tostring(tes3.encode(value))
end

local Words = { 'ex', 'in', 'furn', 'flora', 'terrain', 'misc', 'light', 'active', 'contain' }

local function word(): string return Words[nextRandom() % #Words + 1] end

--[[ The inputs ]]

local fixture = assert(jess.fs.readBuffer(`{root()}/tests/assets/all_types.esp`))
local every = tes3.open(fixture)

--- A content file: the fixture's record of every type forty times over, and 13,000 small objects
--- with ids of their own.
local function contentFile(): (buffer, number)
  local parts = { buffer.tostring(every:bytes(0)) }

  for _ = 1, 40 do
    for index = 1, every:count() - 1 do
      table.insert(parts, buffer.tostring(every:bytes(index)))
    end
  end

  for index = 1, 8000 do
    local id = `{word()}_{word()}_{index}`
    table.insert(parts, typed('Static', { id = id, mesh = `{word()}\\{id}.nif` }))
  end

  for index = 1, 3500 do
    local id = `{word()}_{word()}_{index}`
    table.insert(
      parts,
      typed('MiscItem', {
        id = id,
        name = `A {word()} thing`,
        mesh = `m\\{id}.nif`,
        icon = `m\\{id}.tga`,
        data = { weight = nextRandom() % 50, value = nextRandom() % 1000, flags = '' },
      })
    )
  end

  for index = 1, 1500 do
    local inventory = {}

    for item = 1, 8 do
      inventory[item] = { nextRandom() % 9 + 1, `{word()}_{word()}_{nextRandom() % 3500 + 1}` }
    end

    table.insert(
      parts,
      typed('Container', {
        id = `{word()}_chest_{index}`,
        name = 'Chest',
        mesh = 'o\\contain_chest.nif',
        encumbrance = 100,
        inventory = inventory,
      })
    )
  end

  return buffer.fromstring(table.concat(parts)), #parts
end

--- A CELL of `count` references, the first half persistent: each a FRMR, a NAME, sometimes an
--- XSCL, and a DATA.
local function cellRecord(count: number): string
  local parts = {
    subrecord('NAME', 'bench cell\0'),
    subrecord('DATA', u32(1) .. u32(0) .. u32(0)),
  }

  -- References out of order, so sorting them is work: the stride is coprime with the count.
  for position = 1, count do
    if position == count // 2 + 1 then
      table.insert(parts, subrecord('NAM0', u32(count - count // 2)))
    end

    local index = (position * 7919) % count + 1
    table.insert(parts, subrecord('FRMR', u32(bit32.bor(index, bit32.lshift(position % 3, 24)))))
    table.insert(parts, subrecord('NAME', `{word()}_{word()}_{index}\0`))
    if position % 5 == 0 then table.insert(parts, subrecord('XSCL', string.pack('<f', 1.5))) end

    table.insert(
      parts,
      subrecord(
        'DATA',
        string.pack('<ffffff', nextRandom() % 8192, nextRandom() % 8192, nextRandom() % 512, 0, 0, 1)
      )
    )
  end

  return record('CELL', table.concat(parts))
end

--- A LAND at `column`, `row` with every part, its heights rolling gently.
local function landRecord(column: number, row: number): string
  local heights = buffer.create(4 + 65 * 65 + 3)
  buffer.writef32(heights, 0, nextRandom() % 64)

  for vertex = 0, 65 * 65 - 1 do
    buffer.writei8(heights, 4 + vertex, nextRandom() % 7 - 3)
  end

  local normals, colors = buffer.create(65 * 65 * 3), buffer.create(65 * 65 * 3)

  for offset = 0, 65 * 65 * 3 - 1 do
    buffer.writeu8(normals, offset, nextRandom() % 256)
    buffer.writeu8(colors, offset, nextRandom() % 256)
  end

  local textures = buffer.create(16 * 16 * 2)

  for offset = 0, 16 * 16 * 2 - 2, 2 do
    buffer.writeu16(textures, offset, nextRandom() % 40)
  end

  return record(
    'LAND',
    subrecord('INTV', string.pack('<i4i4', column, row))
      .. subrecord('DATA', u32(7))
      .. subrecord('VNML', buffer.tostring(normals))
      .. subrecord('VHGT', buffer.tostring(heights))
      .. subrecord('WNAM', string.rep('\8', 81))
      .. subrecord('VCLR', buffer.tostring(colors))
      .. subrecord('VTEX', buffer.tostring(textures))
  )
end

--- An OpenMW Lua payload: a table of `count` entries of every kind of value.
local function luaTable(count: number): tes3.LuaValue
  local entries = {}

  for index = 1, count do
    local kind = index % 5
    local value: tes3.LuaValue = if kind == 0
      then { kind = 'number', value = index / 7 }
      elseif kind == 1 then { kind = 'string', value = `{word()} {index}` }
      elseif kind == 2 then { kind = 'boolean', value = index % 2 == 0 }
      elseif kind == 3 then { kind = 'vec3', values = { index, index + 1, index + 2 } }
      else { kind = 'object', ref = { index = index, contentFile = index % 4 } }

    entries[index] = { key = { kind = 'string', value = `key{index}` }, value = value }
  end

  return { kind = 'table', entries = entries }
end

--[[ Framing, saving, and identity ]]

local content, contentRecords = contentFile()
local contentLength = buffer.len(content)
local opened = tes3.open(content)

workload('open', contentRecords, function(): number return tes3.open(content):count() end)

workload('open, keeping CELL headers and LAND', 160, function(): number
  local plugin = tes3.open(content, {
    keep = function(tag: string): tes3.Keep
      if tag == 'CELL' then return { references = false } end

      return if tag == 'LAND' then 'whole' else 'skip'
    end,
  })
  return plugin:count()
end)

workload('open, keeping every record', contentRecords, function(): number
  local plugin = tes3.open(content, {
    keep = function(): tes3.Keep return 'whole' end,
  })
  return plugin:count()
end)

workload('save, untouched', contentLength, function(): number return buffer.len(opened:save()) end)

do
  local edited = tes3.open(content)

  for index = 1, edited:count() - 1, 16 do
    local source, start, finish = edited:span(index)
    edited:replacePayload(index, buffer.readstring(source, start + 16, finish - start - 16))
  end

  workload('save, one record in sixteen edited', contentLength, function(): number
    return buffer.len(edited:save())
  end)
end

workload('check a round trip', 1, function(): number
  return if tes3.checkRoundTrip(content) then 0 else 1
end)

workload('tag and id of every record', 303131, function(): number
  local total = 0

  for index = 0, opened:count() - 1 do
    local id = tes3.records.id(opened, index)
    total += #opened:tag(index) + if id then #id else 0
  end

  return total
end)

workload('id span of every record', 238487, function(): number
  local total = 0

  for index = 0, opened:count() - 1 do
    local _, _, length = tes3.records.idSpan(opened, index)
    total += length
  end

  return total
end)

workload('subrecords of every record', 84047, function(): number
  local total = 0

  for index = 0, opened:count() - 1 do
    total += #opened:subrecords(index)
  end

  return total
end)

workload('string fields of every record', 50220, function(): number
  local total = 0

  for index = 0, opened:count() - 1 do
    total += #tes3.records.stringFields(opened, index)
  end

  return total
end)

workload('object keys', 13076, function(): number return #tes3.records.objectKeys(opened) end)

workload('validate as tes3', 0, function(): number return #opened:validateProfile 'tes3' end)

workload('retain every other record and save', 1868995, function(): number
  local plugin = tes3.open(content)
  plugin:retain(function(index: number): boolean return index % 2 == 0 end)
  return buffer.len(plugin:save())
end)

do
  local plugin = tes3.open(content)
  local first = plugin:count() - 1000

  workload('replace a subrecord of 1,000 records', 1000, function(): number
    local done = 0

    for index = first, plugin:count() - 1 do
      local source, at, size = plugin:findSubrecord(index, tes3.tags.code 'NAME')
      plugin:replaceSubrecord(index, 0, buffer.readstring(source :: buffer, at, size))
      done += 1
    end

    return done
  end)

  workload('delete no subrecord of 1,000 records by tag', 0, function(): number
    local gone = 0

    for index = first, plugin:count() - 1 do
      gone += plugin:deleteSubrecordsByTag(index, 'XXXX')
    end

    return gone
  end)
end

--[[ The typed codec ]]

workload('decode a record of every type', 80, function(): number
  local decoded = 0

  for index = 0, every:count() - 1 do
    if every:decode(index) then
      decoded += 1
    end
  end

  return decoded
end)

do
  local values = {}

  for index = 0, every:count() - 1 do
    table.insert(values, assert(every:decode(index)))
  end

  workload('encode a record of every type', 49483, function(): number
    local total = 0

    for _, value in values do
      total += buffer.len(tes3.encode(value))
    end

    return total
  end)
end

workload('display a record of every type', 80, function(): number
  local shown = 0

  for index = 0, every:count() - 1 do
    if tes3.display.display(every, index).record == index then
      shown += 1
    end
  end

  return shown
end)

do
  local actors = tes3.open(fixture)
  local actor = assert(tes3.records.find(actors, 'NPC_', 'test_npc'))

  workload('set an edited NPC_, there and back', 2, function(): number
    local changed = 0

    for _, level in { 12, 30 } do
      local value = assert(actors:decode(actor))
      local data = value.data :: { [string]: unknown }
      data.level = level
      if actors:set(actor, value) then
        changed += 1
      end
    end

    return changed
  end)
end

--[[ CELL references ]]

do
  local cells = tes3.open(cellRecord(2000))
  local value = assert(cells:decode(0))

  workload('decode a CELL of 2,000 references', 2000, function(): number
    local decoded = assert(cells:decode(0))
    return #(decoded.references :: { unknown })
  end)

  workload('encode a CELL of 2,000 references', 140345, function(): number
    return buffer.len(tes3.encode(value))
  end)

  workload('group a CELL of 2,000 references', 2000, function(): number
    return #assert(cells:cellGroups(0)).references
  end)

  local moved = tes3.open(cellRecord(500))

  workload('set a moved reference in a CELL of 500, there and back', 2, function(): number
    local changed = 0

    for _, height in { 64, 128 } do
      local cell = assert(moved:decode(0))
      local references = cell.references :: { { [string]: unknown } }
      local translation = references[250].translation :: { number }
      translation[3] = height
      if moved:set(0, cell) then
        changed += 1
      end
    end

    return changed
  end)

  local crowded = tes3.open(cellRecord(2000))

  workload('delete 200 references of a CELL of 2,000', 200, function(): number
    local plugin = tes3.open(crowded:save())
    local references = table.create(200, 0)

    for index = 1, 200 do
      references[index] = index * 9
    end

    return plugin:deleteCellReferences(0, references)
  end)
end

--[[ LAND terrain ]]

do
  local parts = {}

  for index = 0, 63 do
    table.insert(parts, landRecord(index % 8, index // 8))
  end

  local lands = tes3.open(table.concat(parts))

  workload('read 64 LANDs as buffers', 64 * 42843, function(): number
    local total = 0

    for index = 0, 63 do
      local terrain = tes3.land.read(lands, index)
      total += buffer.len(terrain.heights :: buffer)
        + buffer.len(terrain.normals :: buffer)
        + buffer.len(terrain.colors :: buffer)
        + buffer.len(terrain.textures :: buffer)
        + buffer.len(terrain.worldMap :: buffer)
    end

    return total
  end)

  workload('read the heights of 64 LANDs', 64 * 16900, function(): number
    local total = 0

    for index = 0, 63 do
      total += buffer.len(tes3.land.read(lands, index, { 'heights' }).heights :: buffer)
    end

    return total
  end)

  workload('decode 64 LANDs', 64 * 16900, function(): number
    local total = 0

    for index = 0, 63 do
      local land = assert(lands:decode(index))
      total += #((land.vertexNormals :: { [string]: unknown }).data :: string)
    end

    return total
  end)

  -- The vertex in the middle of the cell goes up a step and comes back down; its VHGT delta says
  -- which of the two the record holds.
  local middle = 32 * 65 + 32
  local written = tes3.open(parts[1])
  local lowered = tes3.land.read(written, 0, { 'heights' }).heights :: buffer
  local raised = buffer.create(buffer.len(lowered))
  buffer.copy(raised, 0, lowered)
  buffer.writei32(raised, middle * 4, buffer.readi32(lowered, middle * 4) + 1)

  local function delta(): number
    local source, at = written:findSubrecord(0, tes3.tags.code 'VHGT')
    return buffer.readi8(source :: buffer, at + 4 + middle)
  end

  local low = delta()

  workload('write the heights of a LAND, there and back', 2, function(): number
    local changed = 0
    tes3.land.write(written, 0, { heights = raised })
    if delta() == low + 1 then
      changed += 1
    end

    tes3.land.write(written, 0, { heights = lowered })
    if delta() == low then
      changed += 1
    end

    return changed
  end)
end

--[[ OpenMW's Lua payloads ]]

do
  local value = luaTable(2000)
  local payload = tes3.save.encodeLuaData(value)
  local bytes = buffer.fromstring(payload)

  workload('encode a Lua payload of 2,000 entries', #payload, function(): number
    return #tes3.save.encodeLuaData(value)
  end)

  workload('decode a Lua payload of 2,000 entries', 2000, function(): number
    local decoded = tes3.save.decodeLuaData(bytes, 0, buffer.len(bytes))
    return #(decoded.entries :: { unknown })
  end)

  local decoded = tes3.save.decodeLuaData(bytes, 0, buffer.len(bytes))

  workload('collect the references of a Lua payload of 2,000 entries', 400, function(): number
    return #tes3.save.luaRefs(decoded)
  end)

  workload('display a Lua payload of 2,000 entries', 2000, function(): number
    local shown = tes3.display.luaPayload(bytes, 0, buffer.len(bytes), true) :: { [string]: unknown }
    local count = 0

    for _ in shown do
      count += 1
    end

    return count
  end)
end
