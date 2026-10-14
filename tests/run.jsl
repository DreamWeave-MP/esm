--!strict
--!native
-- tes3's own cases: jess-plugin's raw spine tests and jess-omwaddon's codec edges, on bytes
-- built here, and jess's script API contracts for terrain, record metadata, and building, on
-- jess-omwaddon's plugin with a record of every type (`assets/all_types.esp`).
local tes3 = require '@tes3'
local test = require '@jess/test'
local expect = test.expect
local suite = test.new()

local function u32(value: number): string return string.pack('<I4', value) end

local function subrecord(tag: string, payload: string): string
  return tag .. u32(#payload) .. payload
end

local function record(tag: string, payload: string, flags: number?): string
  return tag .. u32(#payload) .. u32(0) .. u32(flags or 0) .. payload
end

local function fixed(text: string, length: number): string
  return text .. string.rep('\0', length - #text)
end

local function hedr(
  fileType: number,
  author: string,
  description: string,
  count: number
): string
  return subrecord(
    'HEDR',
    string.pack('<f', 1.3)
      .. u32(fileType)
      .. fixed(author, 32)
      .. fixed(description, 256)
      .. u32(count)
  )
end

local function variableHedr(
  fileType: number,
  author: string,
  description: string,
  count: number
): string
  return subrecord(
    'HEDR',
    string.pack('<f', 1.3)
      .. u32(fileType)
      .. u32(#author)
      .. author
      .. u32(#description)
      .. description
      .. u32(count)
  )
end

local function nam0(count: number): string return subrecord('NAM0', u32(count)) end

local function open(bytes: string, options: tes3.OpenOptions?): tes3.Plugin
  return tes3.open(bytes, options)
end

local function saved(plugin: tes3.Plugin): string return buffer.tostring(plugin:save()) end

local function tags(plugin: tes3.Plugin, index: number): { string }
  local out = {}
  for _, sub in plugin:subrecords(index) do
    table.insert(out, sub.tag)
  end

  return out
end

suite.describe('framing', function()
  suite.it('reads a tag as a number and back, and displays the bytes that aren\'t text', function()
    local name, damaged = tes3.tags.code 'NAME', 0xff420141
    expect(name).toBe(0x454d414e)

    -- Each twice: a tag read once reads the same the next time.
    for _ = 1, 2 do
      expect(tes3.tags.name(name)).toBe 'NAME'
      expect(tes3.tags.display(name)).toBe 'NAME'
      expect(tes3.tags.isText(name)).toBe(true)
      expect(tes3.tags.name(damaged)).toBe 'A\1B\255'
      expect(tes3.tags.display(damaged)).toBe 'A\\x01B\\xFF'
      expect(tes3.tags.lossy(damaged)).toBe 'A\1B\u{FFFD}'
      expect(tes3.tags.isText(damaged)).toBe(false)
      expect(tes3.tags.display(tes3.tags.code ' ~\127a')).toBe ' ~\\x7Fa'
      expect(#tes3.tags.name(0 / 0)).toBe(4)
    end
  end)

  suite.it('keeps unknown records and subrecords byte for byte', function()
    local bytes = record('ZZZZ', subrecord('ABCD', 'payload') .. subrecord('WXYZ', '\0\1\2\3'))
    local plugin = open(bytes)
    expect(saved(plugin)).toBe(bytes)
    expect(plugin:tag(0)).toBe 'ZZZZ'
    expect(tags(plugin, 0)).toEqual { 'ABCD', 'WXYZ' }
  end)

  suite.it('rejects a truncated record at its offset', function()
    expect(function() open 'TES3' end).toThrow 'truncated record header at offset 0'
  end)

  suite.it('rejects a truncated subrecord at its offset', function()
    expect(function() open(record('TES3', 'NAME')) end).toThrow 'truncated subrecord header at offset 16'
  end)

  suite.it('rejects a subrecord past its record', function()
    expect(function() open(record('TES3', 'NAME' .. u32(9) .. 'abc')) end).toThrow 'subrecord NAME extends past record payload at offset 16'
  end)

  suite.it('rejects a record past the end of the file', function()
    expect(function() open('STAT' .. u32(100) .. u32(0) .. u32(0)) end).toThrow 'record STAT extends past end of file at offset 0'
  end)

  suite.it('skips what a filter leaves out, and ends at a skipped record past the end', function()
    local bytes = record('STAT', subrecord('NAME', 'a')) .. record('BOOK', subrecord('NAME', 'b'))
    local plugin = open(bytes, {
      keep = function(tag) return if tag == 'BOOK' then 'skip' else 'whole' end,
    })
    expect(plugin:count()).toBe(1)
    expect(saved(plugin)).toBe(record('STAT', subrecord('NAME', 'a')))
    local truncated = open(record('STAT', '') .. 'BOOK' .. u32(100) .. u32(0) .. u32(0), {
      keep = function(tag) return if tag == 'BOOK' then 'skip' else 'whole' end,
    })
    expect(truncated:count()).toBe(1)
  end)

  suite.it('keeps only the parts of a CELL a filter asks for', function()
    local header = subrecord('NAME', 'cell') .. subrecord('DATA', string.rep('\0', 12))
    local refs = subrecord('FRMR', u32(1))
      .. subrecord('NAME', 'ref')
      .. subrecord('DATA', string.rep('\0', 24))
    local bytes = record('CELL', header .. refs)
    local headerOnly = open(bytes, {
      keep = function() return { references = false } end,
    })
    expect(headerOnly:isPartial(0)).toBe(true)
    expect(headerOnly:keptParts(0)).toEqual { header = true, references = false }
    expect(tags(headerOnly, 0)).toEqual { 'NAME', 'DATA' }
    local refsOnly = open(bytes, {
      keep = function() return { header = false } end,
    })
    expect(tags(refsOnly, 0)).toEqual { 'FRMR', 'NAME', 'DATA' }
    expect(tes3.records.id(refsOnly, 0)).toBeNil()
    local whole = open(record('CELL', header), {
      keep = function() return { references = false } end,
    })
    expect(whole:isPartial(0)).toBe(false)
  end)

  suite.it('says whether a filter left any record in part', function()
    local header = subrecord('NAME', 'cell') .. subrecord('DATA', string.rep('\0', 12))
    local refs = subrecord('FRMR', u32(1))
      .. subrecord('NAME', 'ref')
      .. subrecord('DATA', string.rep('\0', 24))
    local bytes = record('STAT', subrecord('NAME', 'a'))
      .. record('CELL', header .. refs)
      .. record('CELL', header)

    local function headers(): tes3.Keep return { references = false } end

    expect(open(bytes):hasPartialRecords()).toBe(false)
    expect(open(''):hasPartialRecords()).toBe(false)
    expect(open(bytes, { keep = function() return 'whole' end }):hasPartialRecords()).toBe(false)
    local partial = open(bytes, { keep = headers })
    expect(partial:hasPartialRecords()).toBe(true)
    expect(partial:isPartial(1)).toBe(true)
    expect(partial:isPartial(2)).toBe(false)

    -- Only the CELL with references to leave out is in part; without it, no record is.
    partial:delete(1)
    expect(partial:hasPartialRecords()).toBe(false)
    partial:delete(0)
    partial:delete(0)
    expect(partial:hasPartialRecords()).toBe(false)
  end)
end)

suite.describe('editing', function()
  suite.it('rebuilds only the parent of a replaced subrecord', function()
    local bytes = record('ZZZZ', subrecord('ABCD', 'payload') .. subrecord('WXYZ', '\0\1\2\3'))
    local plugin = open(bytes)
    plugin:replaceSubrecord(0, 1, 'changed')
    local reopened = open(saved(plugin))
    expect(reopened:size(0)).toBe(30)
    expect(reopened:subrecords(0)[2].size).toBe(7)
  end)

  suite.it('deletes a record and keeps its neighbours', function()
    local first = record('AAAA', subrecord('NAME', 'first'))
    local third = record('CCCC', subrecord('NAME', 'third'))
    local plugin = open(first .. record('BBBB', subrecord('NAME', 'second')) .. third)
    plugin:delete(1)
    expect(saved(plugin)).toBe(first .. third)
  end)

  suite.it('deletes subrecords in one rebuild', function()
    local first, fourth = subrecord('KEEP', 'one'), subrecord('KEEP', 'four')
    local next = record('NEXT', subrecord('NAME', 'next'))
    local plugin = open(
      record('TEST', first .. subrecord('DROP', 'two') .. subrecord('DROP', 'three') .. fourth)
        .. next
    )
    expect(plugin:deleteSubrecords(0, { 2, 1, 2 })).toBe(2)
    expect(saved(plugin)).toBe(record('TEST', first .. fourth) .. next)
    expect(function() plugin:deleteSubrecords(0, { 5 }) end).toThrow 'subrecord index 5 out of bounds'
  end)

  suite.it('deletes subrecords by tag', function()
    local plugin = open(
      record(
        'TEST',
        subrecord('NAME', 'id') .. subrecord('FNAM', 'display') .. subrecord('FNAM', 'other')
      )
    )
    expect(plugin:deleteSubrecordsByTag(0, 'ZZZZ')).toBe(0)
    expect(plugin:isDirty(0)).toBe(false)
    expect(plugin:deleteSubrecordsByTag(0, 'FNAM')).toBe(2)
    expect(plugin:isDirty(0)).toBe(true)
    expect(tags(open(saved(plugin)), 0)).toEqual { 'NAME' }
    expect(plugin:deleteSubrecordsByTag(0, 'FNAM')).toBe(0)
    expect(function() plugin:deleteSubrecordsByTag(1, 'FNAM') end).toThrow 'record index out of bounds'
  end)

  suite.it('inserts records where asked and keeps the rest', function()
    local first = record('AAAA', subrecord('NAME', 'first'))
    local second = record('BBBB', subrecord('NAME', 'second'))
    local plugin = open(first .. second)
    local inserted = record('NEWW', subrecord('NAME', 'new'))
    plugin:insert(1, inserted)
    expect(saved(plugin)).toBe(first .. inserted .. second)
    expect(plugin:isDirty(1)).toBe(true)
    expect(function() plugin:insert(1, 'NEWW' .. u32(9) .. u32(0) .. u32(0)) end).toThrow 'record NEWW size doesn\'t match its bytes at offset 4'
  end)

  suite.it('replaces a record with new bytes of the same tag', function()
    local plugin = open(record('AAAA', subrecord('NAME', 'first')))
    plugin:replaceBytes(0, record('AAAA', subrecord('NAME', 'other'), 0x400))
    expect(saved(plugin)).toBe(record('AAAA', subrecord('NAME', 'other'), 0x400))
    expect(function() plugin:replaceBytes(0, record('BBBB', '')) end).toThrow 'different tag'
  end)

  suite.it('keeps deleted subrecords deleted through later edits', function()
    local plugin = open(
      record('TEST', subrecord('KEEP', 'a') .. subrecord('DROP', 'b') .. subrecord('LAST', 'c'))
    )
    plugin:deleteSubrecord(0, 1)
    plugin:replaceSubrecord(0, 1, 'changed')
    expect(saved(plugin)).toBe(
      record('TEST', subrecord('KEEP', 'a') .. subrecord('LAST', 'changed'))
    )
  end)

  suite.it('retains the records a predicate keeps', function()
    local plugin = open(record('AAAA', '') .. record('BBBB', '') .. record('CCCC', ''))
    plugin:retain(function(index) return index ~= 1 end)
    expect(saved(plugin)).toBe(record('AAAA', '') .. record('CCCC', ''))
  end)
end)

suite.describe('the TES3 header', function()
  suite.it('reads and updates the record count', function()
    local plugin = open(
      record('TES3', hedr(0, 'me', 'desc', 999)) .. record('STAT', subrecord('NAME', 'marker'))
    )
    local header = plugin:header()
    expect(header.author).toBe 'me'
    expect(header.description).toBe 'desc'
    expect(header.recordCount).toBe(999)
    expect(plugin:updateRecordCount()).toBe(true)
    expect(open(saved(plugin)):header().recordCount).toBe(1)
    expect(plugin:updateRecordCount()).toBe(false)
  end)

  suite.it('reads an absent FORM as version 0 and refuses a malformed one', function()
    expect(open(record('TES3', hedr(0, 'me', 'desc', 0))):formatVersion()).toBe(0)
    local bad = open(record('TES3', subrecord('FORM', '\1\2\3')))
    expect(function() bad:formatVersion() end).toThrow 'FORM payload is not 4 bytes at offset 24'
  end)

  suite.it('reads size-prefixed header strings after FORM 23', function()
    local plugin = open(
      record('TES3', subrecord('FORM', u32(34)) .. variableHedr(0, 'me', 'desc', 2))
        .. record('STAT', subrecord('NAME', 'marker'))
    )
    expect(plugin:formatVersion()).toBe(34)
    expect(plugin:header().author).toBe 'me'
    expect(plugin:header().recordCount).toBe(2)
    expect(plugin:updateRecordCount()).toBe(true)
    expect(open(saved(plugin)):header().recordCount).toBe(1)
    expect(function() plugin:setAuthor 'x' end).toThrow 'variable-size HEDR author strings'
  end)

  suite.it('sets the file type, author, and description', function()
    local plugin = open(record('TES3', hedr(0, 'me', 'first', 0)))
    expect(plugin:header().fileType).toBe 'plugin'
    expect(plugin:setFileType 'master').toBe(true)
    expect(plugin:setAuthor '+ and you').toBe(true)
    expect(plugin:setDescription '+\\nsecond').toBe(true)
    local header = open(saved(plugin)):header()
    expect(header.fileType).toBe 'master'
    expect(header.author).toBe 'me and you'
    expect(header.description).toBe 'first\nsecond'
    expect(plugin:setAuthor 'me and you').toBe(false)
  end)

  suite.it('refuses an author that doesn\'t fit, at its offset', function()
    local plugin = open(record('TES3', hedr(0, 'me', 'desc', 0)))
    expect(function() plugin:setAuthor 'abcdefghijklmnopqrstuvwxyzabcdefg' end).toThrow 'header string is too long for 32-byte field at offset 32'
  end)

  suite.it('refuses text the code page lacks, naming the character', function()
    local plugin = open(record('TES3', hedr(0, 'me', 'desc', 0)))
    expect(function() plugin:setAuthor 'Ж' end).toThrow 'TES3 HEDR author: \'Ж\' (U+0416) can\'t be written in Windows-1252, the plugin\'s encoding'
    local cyrillic = open(record('TES3', hedr(0, 'me', 'desc', 0)), { encoding = 'win1251' })
    expect(cyrillic:setAuthor 'Жук').toBe(true)
    expect(cyrillic:header().author).toBe 'Жук'
  end)

  suite.it('reads, sets, and syncs masters', function()
    local master = subrecord('MAST', 'Morrowind.esm\0')
      .. subrecord('DATA', string.pack('<I8', 79837557))
    local plugin = open(record('TES3', hedr(0, '', '', 0) .. master))
    expect(plugin:masters()).toEqual {
      { name = 'Morrowind.esm', size = 79837557, mast = 1, data = 2 },
    }
    expect(plugin:setMasterSize('MORROWIND.ESM', 1)).toBe(true)
    expect(plugin:masters()[1].size).toBe(1)
    expect(plugin:setMasters {
      { name = 'Morrowind.esm', size = 1 },
      { name = 'Tribunal.esm', size = 4565686 },
    }).toBe(true)
    expect(tags(plugin, 0)).toEqual { 'HEDR', 'MAST', 'DATA', 'MAST', 'DATA' }
    expect(plugin:masters()[2]).toEqual { name = 'Tribunal.esm', size = 4565686, mast = 3, data = 4 }
    local missing = open(record('TES3', hedr(0, '', '', 0) .. subrecord('MAST', 'a\0')))
    expect(function() missing:masters() end).toThrow 'TES3 MAST subrecord is missing following DATA'
  end)

  suite.it('leaves masters that are as asked, and sets ones whose name or size differs', function()
    local function master(name: string, size: number): string
      return subrecord('MAST', name .. '\0') .. subrecord('DATA', string.pack('<I8', size))
    end

    local function header(...: string): string
      return record('TES3', hedr(0, '', '', 0) .. table.concat { ... })
    end

    local bytes = header(master('a.esm', 1), master('b.esm', 2))
    local plugin = open(bytes)
    expect(plugin:setMasters { { name = 'a.esm', size = 1 }, { name = 'b.esm', size = 2 } }).toBe(false)
    expect(plugin:isDirty(0)).toBe(false)
    expect(saved(plugin)).toBe(bytes)

    -- The last master's size alone, then its name alone.
    expect(plugin:setMasters { { name = 'a.esm', size = 1 }, { name = 'b.esm', size = 3 } }).toBe(true)
    expect(saved(plugin)).toBe(header(master('a.esm', 1), master('b.esm', 3)))
    expect(plugin:setMasters { { name = 'a.esm', size = 1 }, { name = 'c.esm', size = 3 } }).toBe(true)
    expect(saved(plugin)).toBe(header(master('a.esm', 1), master('c.esm', 3)))
    expect(plugin:setMasters { { name = 'a.esm', size = 1 }, { name = 'c.esm', size = 3 } }).toBe(false)

    expect(plugin:setMasters { { name = 'a.esm', size = 1 } }).toBe(true)
    expect(saved(plugin)).toBe(header(master('a.esm', 1)))
    expect(plugin:setMasters {}).toBe(true)
    expect(plugin:setMasters {}).toBe(false)
    expect(tags(plugin, 0)).toEqual { 'HEDR' }
  end)

  suite.it('builds an empty plugin', function()
    local plugin = tes3.new 'master'
    expect(plugin:header()).toEqual {
      version = string.unpack('<f', string.pack('<f', 1.3)),
      fileType = 'master',
      author = '',
      description = '',
      recordCount = 0,
    }
    expect(plugin:count()).toBe(1)
  end)
end)

suite.describe('CELL references', function()
  suite.it('groups references and saves unchanged', function()
    local bytes = record(
      'CELL',
      subrecord('NAME', 'cell')
        .. subrecord('DATA', string.rep('\0', 4))
        .. nam0(2)
        .. subrecord('FRMR', string.rep('\1', 4))
        .. subrecord('NAME', 'first_ref')
        .. subrecord('DATA', string.rep('\1', 24))
        .. subrecord('FRMR', string.rep('\2', 4))
        .. subrecord('NAME', 'second_ref')
        .. subrecord('DATA', string.rep('\2', 24))
    )
    local plugin = open(bytes)
    expect(plugin:cellGroups(0)).toEqual { header = 3, nam0 = 2, references = { { 3, 5 }, { 6, 8 } } }
    expect(saved(plugin)).toBe(bytes)
  end)

  suite.it('starts a moved reference at its MVRF and deletes it whole', function()
    local bytes = record(
      'CELL',
      subrecord('NAME', 'cell')
        .. subrecord('DATA', string.rep('\0', 12))
        .. subrecord('MVRF', string.rep('\1', 4))
        .. subrecord('CNDT', string.rep('\0', 8))
        .. subrecord('FRMR', string.rep('\1', 4))
        .. subrecord('NAME', 'moved_first')
        .. subrecord('FRMR', string.rep('\2', 4))
        .. subrecord('NAME', 'still')
        .. subrecord('MVRF', string.rep('\3', 4))
        .. subrecord('FRMR', string.rep('\3', 4))
        .. subrecord('NAME', 'moved_no_cndt')
        .. subrecord('MVRF', string.rep('\4', 4))
        .. subrecord('CNDT', string.rep('\0', 8))
        .. subrecord('FRMR', string.rep('\4', 4))
        .. subrecord('NAME', 'moved_last')
    )
    local plugin = open(bytes)
    expect((plugin:cellGroups(0) :: any).references).toEqual {
      { 2, 5 },
      { 6, 7 },
      { 8, 10 },
      { 11, 14 },
    }
    expect(plugin:deleteCellReferences(0, { 2 })).toBe(1)
    expect(tags(plugin, 0)).toEqual {
      'NAME',
      'DATA',
      'MVRF',
      'CNDT',
      'FRMR',
      'NAME',
      'FRMR',
      'NAME',
      'MVRF',
      'CNDT',
      'FRMR',
      'NAME',
    }
  end)

  suite.it('updates NAM0 when a reference goes', function()
    local bytes = record(
      'CELL',
      subrecord('NAME', 'cell')
        .. nam0(2)
        .. subrecord('FRMR', string.rep('\1', 4))
        .. subrecord('NAME', 'first_ref')
        .. subrecord('DATA', string.rep('\1', 24))
        .. subrecord('FRMR', string.rep('\2', 4))
        .. subrecord('NAME', 'second_ref')
        .. subrecord('DATA', string.rep('\2', 24))
    )
    local plugin = open(bytes)
    expect(plugin:deleteCellReferences(0, { 0 })).toBe(1)
    local reopened = open(saved(plugin))
    expect((reopened:cellGroups(0) :: any).references).toEqual { { 2, 4 } }
    local subs = reopened:subrecords(0)
    local source = reopened:span(0)
    expect(buffer.readu32(source, subs[2].payload)).toBe(1)
    expect(buffer.readstring(source, subs[4].payload, subs[4].size)).toBe 'second_ref'
  end)

  --- The ids of an encoded CELL's references, in the order they were written.
  local function writtenIds(encoded: buffer): { string }
    local plugin = tes3.open(encoded)
    local source = plugin:span(0)
    local ids = {}
    local reference = false

    for _, sub in plugin:subrecords(0) do
      if sub.tag == 'NAME' and reference then
        table.insert(ids, buffer.readstring(source, sub.payload, sub.size - 1))
      end

      reference = sub.tag == 'FRMR'
    end

    return ids
  end

  suite.it('keeps references persistent first, by master with its own last, then by index', function()
    local function reference(master: number, index: number): string
      return subrecord('FRMR', u32(master * 16777216 + index))
        .. subrecord('NAME', `m{master}i{index}\0`)
        .. subrecord('DATA', string.rep('\0', 24))
    end

    local bytes = record(
      'CELL',
      subrecord('NAME', 'cell\0')
        .. subrecord('DATA', string.rep('\0', 12))
        .. reference(0, 9)
        .. reference(2, 5)
        .. reference(0, 3)
        .. reference(1, 700)
        .. reference(255, 16777215)
        .. nam0(4)
        .. reference(0, 2)
        .. reference(255, 1)
        .. reference(1, 4)
        .. reference(0, 1)
    )
    local value = open(bytes):decode(0) :: any
    local ids = {}

    for _, entry in value.references do
      table.insert(ids, entry.id)
    end

    local order =
      { 'm1i700', 'm2i5', 'm255i16777215', 'm0i3', 'm0i9', 'm1i4', 'm255i1', 'm0i1', 'm0i2' }
    expect(ids).toEqual(order)
    expect(writtenIds(tes3.encode(value))).toEqual(order)
  end)

  suite.it('orders references whose master or index no FRMR holds by the same rule', function()
    local function reference(master: number, index: number, temporary: boolean): tes3.Value
      return {
        id = `m{master}i{index}`,
        mastIndex = master,
        refrIndex = index,
        temporary = temporary,
        translation = { 0, 0, 0 },
        rotation = { 0, 0, 0 },
      }
    end

    local value = tes3.default 'Cell' :: tes3.Value
    value.references = {
      reference(0, 0.5, false),
      reference(300, 2, false),
      reference(1, 16777300, false),
      reference(0, 3, true),
      reference(2, 1, false),
      reference(1.5, 1, true),
      reference(0, 2, false),
    }

    expect(writtenIds(tes3.encode(value))).toEqual {
      'm1i16777300',
      'm2i1',
      'm300i2',
      'm0i0.5',
      'm0i2',
      'm1.5i1',
      'm0i3',
    }
  end)

  suite.it('keeps the later of two references with one master and index', function()
    local value = tes3.default 'Cell' :: tes3.Value
    value.references = {
      {
        id = 'first',
        mastIndex = 1,
        refrIndex = 7,
        temporary = false,
        translation = { 0, 0, 0 },
        rotation = { 0, 0, 0 },
      },
      {
        id = 'second',
        mastIndex = 1,
        refrIndex = 7,
        temporary = false,
        translation = { 0, 0, 0 },
        rotation = { 0, 0, 0 },
      },
    }
    expect(writtenIds(tes3.encode(value))).toEqual { 'second' }
  end)
end)

suite.describe('profiles', function()
  suite.it('flags OpenMW records for the vanilla profile only', function()
    local plugin =
      open(record('TES3', hedr(0, '', '', 1)) .. record('LUAL', subrecord('NAME', 'lua')))
    expect(plugin:validateProfile 'raw').toEqual {}
    expect(plugin:validateProfile 'tes3').toEqual {
      { offset = 324, message = 'LUAL is an OpenMW-only record type' },
    }
  end)

  suite.it('checks the structure every profile relies on', function()
    expect(open(''):validateProfile 'raw').toEqual {
      { offset = 0, message = 'the file has no records, not even a TES3 header' },
    }
    local second = open(record('TES3', hedr(0, '', '', 0)) .. record('TES3', hedr(0, '', '', 0)))
    expect(second:validateProfile 'raw').toEqual {
      { offset = 324, message = 'a second TES3 header' },
    }
  end)

  suite.it('flags what OpenMW refuses or skips', function()
    local plugin = open(
      record('TES3', hedr(0, '', '', 0))
        .. record('INFO', subrecord('INAM', 'a\0'))
        .. record('XXXX', '')
        .. record('DIAL', subrecord('NAME', 't\0'))
        .. record('INFO', subrecord('INAM', 'b\0'))
    )
    local messages = {}
    for _, diagnostic in plugin:validateProfile 'omwaddon' do
      table.insert(messages, diagnostic.message)
    end

    expect(messages).toEqual {
      'INFO has no DIAL before it; OpenMW skips it ("info record without dialog")',
      'XXXX isn\'t a record type OpenMW loads; it refuses the file ("Unknown record")',
    }
  end)

  suite.it('says where each tag that isn\'t text and each subrecord vanilla lacks is', function()
    local plugin = open(
      record('TES3', hedr(0, '', '', 3) .. subrecord('FORM', u32(1)))
        .. record(
          'STAT',
          subrecord('NAME', 'a\0')
            .. subrecord('ZZZZ', '')
            .. subrecord('A\1B\255', 'x')
            .. subrecord('ENID', '')
        )
        .. record('\1BCD', subrecord('NAME', 'b\0'))
        .. record('BOOK', subrecord('SKIL', '') .. subrecord('NAME', 'c\0'))
    )
    local damaged = {
      {
        offset = 370,
        message = 'STAT subrecord type [65, 1, 66, 255] isn\'t text; the record is damaged here',
      },
      {
        offset = 387,
        message = 'record type [1, 66, 67, 68] isn\'t text; the file is damaged here',
      },
    }

    expect(plugin:validateProfile 'raw').toEqual(damaged)
    expect(plugin:validateProfile 'omwaddon').toEqual {
      damaged[1],
      damaged[2],
      {
        offset = 387,
        message = '\\x01BCD isn\'t a record type OpenMW loads; it refuses the file ("Unknown record")',
      },
    }

    local static = {
      { offset = 362, message = 'STAT.ZZZZ is not part of the Morrowind format' },
      { offset = 370, message = 'STAT.A\\x01B\\xFF is not part of the Morrowind format' },
      { offset = 379, message = 'STAT.ENID is an OpenMW extension' },
    }

    expect(plugin:recordProfileDiagnostics(1, 'tes3')).toEqual(static)
    expect(plugin:recordProfileDiagnostics(1, 'raw')).toEqual {}
    expect(plugin:recordProfileDiagnostics(2, 'tes3')).toEqual {
      { offset = 387, message = '\\x01BCD is not a Morrowind record type' },
    }

    expect(plugin:validateProfile 'tes3').toEqual {
      damaged[1],
      damaged[2],
      { offset = 324, message = 'TES3.FORM is an OpenMW extension' },
      static[1],
      static[2],
      static[3],
      { offset = 387, message = '\\x01BCD is not a Morrowind record type' },
      { offset = 429, message = 'BOOK.SKIL is an OpenMW extension' },
    }

    -- An edited record has no bytes of its own in the file: its problems are where it ends.
    plugin:replaceSubrecord(1, 0, 'renamed\0')
    expect(plugin:validateProfile 'tes3').toEqual {
      { offset = 387, message = damaged[1].message },
      damaged[2],
      { offset = 324, message = 'TES3.FORM is an OpenMW extension' },
      { offset = 387, message = static[1].message },
      { offset = 387, message = static[2].message },
      { offset = 387, message = static[3].message },
      { offset = 387, message = '\\x01BCD is not a Morrowind record type' },
      { offset = 429, message = 'BOOK.SKIL is an OpenMW extension' },
    }
  end)
end)

suite.describe('typed records', function()
  suite.it('decodes into jess-omwaddon\'s shape', function()
    local bytes = record(
      'BOOK',
      subrecord('NAME', 'book\0')
        .. subrecord('BKDT', string.pack('<fIIiI', 1, 2, 1, 20, 3))
        .. subrecord('TEXT', 'text\0'),
      0x2000
    )
    local plugin = open(bytes)
    expect(plugin:decode(0)).toEqual {
      type = 'Book',
      flags = 'BLOCKED',
      id = 'book',
      name = '',
      script = '',
      mesh = '',
      icon = '',
      enchanting = '',
      text = 'text\0',
      data = { weight = 1, value = 2, bookType = 'Scroll', skill = 'Acrobatics', enchantment = 3 },
    }
    expect(buffer.tostring(plugin:encode(plugin:decode(0) :: tes3.Value))).toBe(bytes)
  end)

  suite.it('spells unknown flag bits in hex and unknown enum values as the default', function()
    local plugin = open(
      record(
        'LIGH',
        subrecord('NAME', 'l\0')
          .. subrecord('LHDT', string.pack('<fIiIBBBBI', 0, 0, 0, 0, 0, 0, 0, 0, 0x1003)),
        0x40
      )
    )
    local value = plugin:decode(0) :: any
    expect(value.flags).toBe '0x40'
    expect(value.data.flags).toBe 'DYNAMIC | CAN_CARRY | 0x1000'
    local book = open(record('BOOK', subrecord('BKDT', string.pack('<fIIiI', 0, 0, 7, 99, 0))))
    expect((book:decode(0) :: any).data.skill).toBe 'None'
    expect((book:decode(0) :: any).data.bookType).toBe 'Book'
  end)

  suite.it('fails where the Rust loader fails', function()
    local unknown = open(record('BOOK', subrecord('ZZZZ', '')))
    expect(function() unknown:decode(0) end).toThrow 'Unexpected Tag: BOOK::ZZZZ'
    local short = open(record('BOOK', subrecord('BKDT', 'short')))
    expect(function() short:decode(0) end).toThrow 'Unexpected Value'
    expect(open(record('ZZZZ', '')):decode(0)).toBeNil()
  end)

  suite.it('gives defaults for every record type', function()
    for _, spec in tes3.recordTypes do
      local value = tes3.default(spec.name) :: tes3.Value
      expect(value.type).toBe(spec.name)
      expect(tes3.default(spec.tag)).toEqual(value)
      local encoded = tes3.encode(value)
      expect(tes3.decode(encoded, 0, buffer.len(encoded), 'win1252')).toEqual(value)
    end
  end)

  --- What encoding a default `name` with `fields` set raises, or `''`.
  local function refusal(name: string, fields: { [string]: unknown }): string
    local value = tes3.default(name) :: tes3.Value

    for key, field in fields do
      value[key] = field
    end

    -- tes3.encode raises on a value its record type can't hold; what it says is what's checked.
    local ok, problem = pcall(tes3.encode, value)
    return if ok then '' else tostring(problem)
  end

  suite.it('reads flags by name, in hex, and as a number, and names the field of a bad one', function()
    local function flagsOf(flags: unknown): unknown
      local value = tes3.default 'Static' :: tes3.Value
      value.flags = flags
      local encoded = tes3.encode(value)
      return (tes3.decode(encoded, 0, buffer.len(encoded), 'win1252') :: tes3.Value).flags
    end

    expect(flagsOf ' PERSISTENT |BLOCKED|0x40 ').toBe 'PERSISTENT | BLOCKED | 0x40'
    expect(flagsOf(0x400)).toBe 'PERSISTENT'
    expect(flagsOf '   ').toBe ''
    expect(flagsOf '').toBe ''

    -- Each twice: a text read once reads the same the next time, and a bad one is bad again.
    for _ = 1, 2 do
      expect(flagsOf 'PERSISTENT | BLOCKED').toBe 'PERSISTENT | BLOCKED'
      expect(refusal('Static', { flags = 'NOPE' })).toBe 'value.flags: unrecognized named flag `NOPE`'
    end

    expect(refusal('Static', { flags = 'DELETED | ' })).toBe 'value.flags: encountered empty flag'
    expect(refusal('Static', { flags = {} })).toBe 'value.flags: expected a flags string, got table'
    expect(refusal('MiscItem', { data = { flags = 'KEY | NOPE' } })).toBe 'data.flags: unrecognized named flag `NOPE`'
  end)

  suite.it('names the field of a variant no enum has', function()
    local variants = 'expected one of Greeting, Journal, Persuasion, Topic, Voice'
    expect(refusal('Dialogue', { dialogueType = 'Chat' })).toBe(
      `value.dialogueType: unknown variant 'Chat', {variants}`
    )
    expect(refusal('Dialogue', { dialogueType = 3 })).toBe(
      `value.dialogueType: unknown variant '3', {variants}`
    )
    expect(refusal('Dialogue', { dialogueType = 'Journal' })).toBe ''
    expect(refusal('Class', { data = { major3 = 'Flying' } })).toBe(
      'data.major3: unknown variant \'Flying\', expected one of Acrobatics, Alchemy, Alteration, '
        .. 'Armorer, Athletics, Axe, Block, BluntWeapon, Conjuration, Destruction, Enchant, '
        .. 'HandToHand, HeavyArmor, Illusion, LightArmor, LongBlade, Marksman, MediumArmor, '
        .. 'Mercantile, Mysticism, None, Restoration, Security, ShortBlade, Sneak, Spear, '
        .. 'Speechcraft, Unarmored'
    )
  end)

  suite.it('names the reference and the field of one it can\'t write', function()
    local function reference(fields: { [string]: unknown }): tes3.Value
      local value: tes3.Value = {
        id = 'a',
        mastIndex = 0,
        refrIndex = 1,
        temporary = false,
        translation = { 0, 0, 0 },
        rotation = { 0, 0, 0 },
      }

      for key, field in fields do
        value[key] = if field == 'none' then nil else field
      end

      return value
    end

    local function refused(...: tes3.Value): string return refusal('Cell', { references = { ... } }) end

    expect(refused(reference { translation = { 1, 'x', 3 } })).toBe 'references[1].translation[2]: expected number, got string'
    expect(refused(reference {}, reference { refrIndex = 2, rotation = 'none' })).toBe 'references[2].rotation: expected list, got nil'
    expect(refused(reference { rotation = { 0, 0 } })).toBe 'references[1].rotation[3]: expected number, got nil'
    expect(refused(reference { mastIndex = 'none' })).toBe 'references[1].mastIndex: expected number, got nil'
    expect(refused(reference { refrIndex = 'seven' })).toBe 'references[1].refrIndex: expected number, got string'
    expect(refused(reference { id = 7 })).toBe 'references[1].id: expected string, got number'
    expect(refused(reference { destination = { translation = {}, rotation = { 0, 0, 0 }, cell = '' } })).toBe 'references[1].destination.translation[1]: expected number, got nil'
    expect(refused(reference { destination = { translation = { 0, 0, 0 }, rotation = { 0, 0 }, cell = '' } })).toBe 'references[1].destination.rotation[3]: expected number, got nil'
    expect(refused(reference { destination = { rotation = { 0, 0, 0 }, cell = '' } })).toBe 'references[1].translation: expected list, got nil'
    expect(refusal('Npc', {
      travelDestinations = { { translation = { 0, 0 }, rotation = { 0, 0, 0 }, cell = '' } },
    })).toBe 'travelDestinations[1].translation[3]: expected number, got nil'

    expect(refusal('Npc', {
      aiPackages = { { type = 'Travel', location = { 0, 'x', 0 }, reset = 0 } },
    })).toBe 'aiPackages[1][2]: expected number, got string'
  end)

  suite.it('takes a field a value answers for through a metatable', function()
    local value = setmetatable({ type = 'Static' }, { __index = { id = 'kept', mesh = 'm.nif' } })
    expect(buffer.tostring(tes3.encode(value :: tes3.Value))).toBe(
      record('STAT', subrecord('NAME', 'kept\0') .. subrecord('MODL', 'm.nif\0'))
    )
  end)

  suite.it('lays a value over its type\'s defaults: a struct field by field, a list whole', function()
    local function written(value: tes3.Value): string return buffer.tostring(tes3.encode(value)) end

    local function item(): tes3.Value
      return { type = 'MiscItem', id = 'item', data = { weight = 2 }, name = 'Item' }
    end

    local full = tes3.default 'MiscItem' :: any
    full.id = 'item'
    full.name = 'Item'
    full.data.weight = 2
    local partial = item()
    expect(written(partial)).toBe(written(full))

    -- Encoding reads the value handed in: it's as it was after, and its tables the caller's.
    expect(partial).toEqual(item())
    expect(table.isfrozen(partial)).toBe(false)
    expect(table.isfrozen(partial.data :: { [string]: unknown })).toBe(false)

    -- A field no default has is carried along and never written.
    local extra = item()
    local extraData = extra.data :: { [string]: unknown }
    extra.unheardOf = { 1, 2, 3 }
    extraData.another = 'x'
    expect(written(extra)).toBe(written(full))

    -- A field that is there is the value's, whatever it is: nothing stands in for a wrong one.
    expect(refusal('MiscItem', { data = false })).toBe 'value.data: expected table, got boolean'
    expect(refusal('MiscItem', { id = false })).toBe 'value.id: expected string, got boolean'

    -- A list is taken whole, and never filled out from the default's.
    expect(refusal('Cell', { data = { grid = { 5 } } })).toBe 'data.grid[2]: expected number, got nil'
    expect(refusal('Cell', { data = { grid = { 5, 6, 7 } } })).toBe ''
  end)

  suite.it('gives a default that is the caller\'s to change, a new one each time', function()
    local first = tes3.default 'Npc' :: any
    local untouched = buffer.tostring(tes3.encode(first))
    first.data.level = 77
    table.insert(first.inventory, { 1, 'gold' })
    expect(buffer.tostring(tes3.encode(first)) == untouched).toBe(false)

    -- What one caller did to its default is in no other, nor in what a bare value encodes to.
    local second = tes3.default 'Npc' :: any
    expect(second.data.level).toBe(0)
    expect(second.inventory).toEqual {}
    expect(table.isfrozen(second.data)).toBe(false)
    expect(buffer.tostring(tes3.encode(second))).toBe(untouched)
    expect(buffer.tostring(tes3.encode { type = 'Npc' })).toBe(untouched)
  end)

  suite.it('gives a class of no attributes, skills, or services by default', function()
    expect((tes3.default 'Class' :: tes3.Value).data).toEqual {
      attribute1 = 'None',
      attribute2 = 'None',
      specialization = 'None',
      minor1 = 'None',
      minor2 = 'None',
      minor3 = 'None',
      minor4 = 'None',
      minor5 = 'None',
      major1 = 'None',
      major2 = 'None',
      major3 = 'None',
      major4 = 'None',
      major5 = 'None',
      flags = '',
      services = '',
    }
  end)

  suite.it('reads a faction\'s ten ranks and seven skills each from its own place', function()
    local value = tes3.default 'Faction' :: any
    value.id = 'faction'
    value.data.favoredAttributes = { 'Strength', 'Luck' }
    value.data.favoredSkills =
      { 'Block', 'Armorer', 'MediumArmor', 'HeavyArmor', 'BluntWeapon', 'LongBlade', 'Axe' }

    for rank, requirement in value.data.requirements do
      requirement.attributes = { rank, rank + 10 }
      requirement.primarySkill = rank + 20
      requirement.favoredSkill = rank + 30
      requirement.reputation = rank + 40
    end

    expect(#value.data.requirements).toBe(10)
    local encoded = tes3.encode(value)
    expect(tes3.decode(encoded, 0, buffer.len(encoded), 'win1252')).toEqual(value)

    -- FADT: two attributes, ten ranks of five i32s, seven skills, and flags.
    local source, at, size = tes3.open(encoded):findSubrecord(0, tes3.tags.code 'FADT')
    expect(size).toBe(240)
    expect(buffer.readi32(source :: buffer, at + 8 + 9 * 20 + 16)).toBe(50)
    expect(buffer.readi32(source :: buffer, at + 208 + 6 * 4)).toBe(6)
  end)

  suite.it('refuses text its code page lacks, and takes text it has', function()
    expect(refusal('Static', { id = 'Ж' })).toBe 'encode error: Ж'
    local value = tes3.default 'Static' :: tes3.Value
    value.id = 'caf\u{e9}'
    expect(buffer.tostring(tes3.encode(value))).toBe(record('STAT', subrecord('NAME', 'caf\xe9\0')))
    value.id = 'Ж'
    expect(buffer.tostring(tes3.encode(value, 'win1251'))).toBe(
      record('STAT', subrecord('NAME', '\xc6\0'))
    )
  end)

  suite.it('keeps the first of several subrecords an edit leaves alike, and their own bytes', function()
    -- Bytes after an item's NUL aren't part of its name, so these read alike and are told apart
    -- only by what a write-back keeps.
    local function item(count: number, name: string, junk: string): string
      local padding = string.rep('\0', 31 - #name - #junk)
      return subrecord('NPCO', string.pack('<i4', count) .. name .. '\0' .. junk .. padding)
    end

    local head = subrecord('NAME', 'chest')
      .. subrecord('MODL', 'm.nif\0')
      .. subrecord('CNDT', string.pack('<f', 10))
      .. subrecord('FLAG', u32(8))
    local plugin = open(
      record(
        'CONT',
        head
          .. item(1, 'gold', 'a')
          .. item(1, 'gold', 'b')
          .. item(1, 'gold', 'c')
          .. item(2, 'key', 'd')
          .. item(3, 'ring', 'e')
      )
    )
    local value = plugin:decode(0) :: any
    value.inventory = { { 1, 'gold' }, { 1, 'gold' }, { 2, 'key' }, { 5, 'new' }, { 3, 'ring' } }
    expect(plugin:set(0, value)).toBe(true)
    expect(buffer.tostring(plugin:bytes(0))).toBe(
      record(
        'CONT',
        head
          .. item(1, 'gold', 'a')
          .. item(1, 'gold', 'b')
          .. item(2, 'key', 'd')
          .. item(5, 'new', '')
          .. item(3, 'ring', 'e')
      )
    )

    value.inventory = { { 1, 'gold' }, { 2, 'key' }, { 1, 'gold' }, { 3, 'ring' }, { 1, 'gold' } }
    expect(plugin:set(0, value)).toBe(true)
    expect(buffer.tostring(plugin:bytes(0))).toBe(
      record(
        'CONT',
        head
          .. item(1, 'gold', 'a')
          .. item(2, 'key', '')
          .. item(1, 'gold', 'b')
          .. item(3, 'ring', 'e')
          .. item(1, 'gold', '')
      )
    )
  end)

  suite.it('writes back only the subrecords an edit changed', function()
    -- No NUL after the name: an encoding would add one, but an untouched NAME keeps its bytes.
    local bytes = record(
      'MISC',
      subrecord('NAME', 'coin')
        .. subrecord('FNAM', 'Coin\0')
        .. subrecord('MCDT', string.pack('<fII', 1, 2, 0))
    )
    local plugin = open(bytes)
    local value = plugin:decode(0) :: any
    expect(plugin:set(0, value)).toBe(false)
    value.name = 'Gold'
    expect(plugin:set(0, value)).toBe(true)
    expect(buffer.tostring(plugin:bytes(0))).toBe(
      record(
        'MISC',
        subrecord('NAME', 'coin')
          .. subrecord('FNAM', 'Gold\0')
          .. subrecord('MCDT', string.pack('<fII', 1, 2, 0))
      )
    )
  end)
end)

suite.describe('OpenMW saves', function()
  local save = tes3.save

  local function metadata(): string
    return record(
      'SAVE',
      subrecord('PLNA', 'Tester')
        .. subrecord('PLLE', string.pack('<i4', 7))
        .. subrecord('PLCL', '\2Archer')
        .. subrecord('PLCN', 'Pilgrim')
        .. subrecord('PLCE', 'Balmora')
        .. subrecord('TSTM', string.pack('<fi4i4i4', 8.5, 18, 7, 427))
        .. subrecord('TIME', string.pack('<d', 25))
        .. subrecord('DESC', 'checkpoint')
        .. subrecord('DEPE', 'Morrowind.esm\0')
        .. subrecord('SCRN', '\255\216')
        .. subrecord('CDAY', string.pack('<i4', 4))
        .. subrecord('CHLT', string.pack('<f', 50))
        .. subrecord('MHLT', string.pack('<f', 75))
    )
  end

  local function current(): string
    return record(
      'TES3',
      subrecord('FORM', u32(save.CurrentFormatVersion)) .. variableHedr(0, '', '', 1)
    )
  end

  suite.it('reports the version window OpenMW loads', function()
    local old =
      open(record('TES3', subrecord('FORM', u32(save.MinEngineSupportedFormatVersion - 1))))
    local new = open(record('TES3', subrecord('FORM', u32(save.CurrentFormatVersion + 1))))
    expect(save.compatibility(old)).toEqual {
      kind = 'tooOld',
      version = save.MinEngineSupportedFormatVersion - 1,
      minimum = save.MinEngineSupportedFormatVersion,
    }

    expect(save.compatibility(new)).toEqual {
      kind = 'tooNew',
      version = save.CurrentFormatVersion + 1,
      maximum = save.CurrentFormatVersion,
    }
    expect(save.FormatHistory[#save.FormatHistory].version).toBe(save.CurrentFormatVersion)
  end)

  suite.it('reads the SAVE metadata and the screenshot', function()
    local plugin = open(current() .. metadata(), { profile = 'omwsave' })
    expect(save.profile(plugin)).toEqual {
      formatVersion = save.CurrentFormatVersion,
      playerName = 'Tester',
      playerLevel = 7,
      playerClassId = 'Archer',
      playerClassName = 'Pilgrim',
      playerCellName = 'Balmora',
      inGameTime = { gameHour = 8.5, day = 18, month = 7, year = 427 },
      timePlayed = 25,
      description = 'checkpoint',
      dependencies = { 'Morrowind.esm' },
      screenshotLength = 2,
      currentDay = 4,
      currentHealth = 50,
      maximumHealth = 75,
    }
    expect(buffer.tostring(save.screenshot(plugin))).toBe '\255\216'
    expect(function() save.profile(open(current())) end).toThrow 'OpenMW save has no SAVE record'
  end)

  suite.it('reads a save header\'s text as UTF-8', function()
    local plugin = open(record('TES3', hedr(0, 'Жук', '', 0)) .. record('SAVE', ''))
    expect(plugin:header().author).toBe 'Жук'
  end)

  suite.it('spells typed RefIds as OpenMW does', function()
    local function text(payload: string): string?
      local id = save.decodeRefId(buffer.fromstring(payload), 0, #payload)
      return if id then save.refIdText(id) else nil
    end

    expect(text '\0').toBe ''
    expect(text('\1' .. u32(3) .. 'abc')).toBe 'abc'
    expect(text '\2plain').toBe 'plain'
    expect(text('\3' .. string.pack('<I4i4', 0x123, 2))).toBe '0x2000123'
    expect(text('\3' .. string.pack('<I4i4', 5, -2))).toBe '@0x100000005'
    expect(text('\4' .. string.pack('<I4I4', 0xabc, 1))).toBe '0x100000abc'
    expect(text('\5SKIL' .. u32(26))).toBe 'SKIL:0x1a'
    expect(text('\6' .. string.pack('<i4i4', -2, -9))).toBe '#-2 -9'
    expect(text '\3short').toBeNil()
    expect(text '\9').toBeNil()
  end)

  suite.it('decodes object references in Lua data', function()
    local payload = '\0'
      .. string.char(0x80 + bit32.lshift(8, 3))
      .. 'o'
      .. string.pack('<I4i4', 42, 1)
    local value = save.decodeLuaData(buffer.fromstring(payload), 0, #payload)
    expect(value).toEqual { kind = 'object', ref = { index = 42, contentFile = 1 }, version = 0 }
    expect(save.luaRefs(value)).toEqual { { index = 42, contentFile = 1 } }
    local list = '\0'
      .. string.char(0x46)
      .. u32(16)
      .. 'objlist'
      .. string.pack('<I4i4I4i4', 7, 0, 8, 2)
    expect(save.luaRefs(save.decodeLuaData(buffer.fromstring(list), 0, #list))).toEqual {
      { index = 7, contentFile = 0 },
      { index = 8, contentFile = 2 },
    }
  end)

  suite.it('keeps tables and unknown userdata, and encodes them back', function()
    local payload = '\0\3\33x' .. string.char(0x42) .. u32(3) .. 'abc\1\2\3\4'
    local value = save.decodeLuaData(buffer.fromstring(payload), 0, #payload)
    expect(value).toEqual {
      kind = 'table',
      version = 0,
      entries = {
        {
          key = { kind = 'string', value = 'x' },
          value = { kind = 'userdata', typeName = 'abc', data = '\1\2\3' },
        },
      },
    }
    expect(save.encodeLuaData(value)).toBe(payload)
    expect(save.decodeLuaData(buffer.create(0), 0, 0)).toEqual { kind = 'nil' }
    expect(save.encodeLuaData { kind = 'nil' }).toBe ''
    expect(function() save.decodeLuaData(buffer.fromstring '\2', 0, 1) end).toThrow 'unsupported Lua serialization format version 2'
    expect(function() save.decodeLuaData(buffer.fromstring '\0\0\0', 0, 3) end).toThrow 'unexpected end of serialized Lua data at offset 2'
  end)

  suite.it('reads and writes format version 1, which adds the integer', function()
    expect(save.LuaFormatVersion).toBe(1)

    -- { count = 7i, [2i] = -1i, big = 2^63 - 1 }, as OpenMW's version 1 writes it.
    local payload = '\1\3'
      .. '\37count\5'
      .. string.pack('<i8', 7)
      .. '\5'
      .. string.pack('<i8', 2)
      .. '\5'
      .. string.pack('<i8', -1)
      .. '\35big\5\255\255\255\255\255\255\255\127'
      .. '\4'
    local value = save.decodeLuaData(buffer.fromstring(payload), 0, #payload)
    local entries = value.entries or {}
    expect({ value.kind, value.version, #entries }).toEqual { 'table', 1, 3 }
    expect({ entries[1].value.kind, entries[1].value.value }).toEqual { 'integer', 7i }
    expect({ entries[2].key.value, entries[2].value.value }).toEqual { 2i, -1i }
    expect(entries[3].value.value).toBe(integer.fromstring '9223372036854775807')

    -- Written back in the format it came in, byte for byte.
    expect(save.encodeLuaData(value)).toBe(payload)

    -- Shown as whole numbers: a number while one holds it exactly, the integer itself past that.
    expect(tes3.display.luaValue(value, true)).toEqual {
      count = 7,
      ['2'] = -1,
      big = integer.fromstring '9223372036854775807',
    }
  end)

  suite.it('keeps a version 1 payload at version 1, and a version 0 one at version 0', function()
    -- The same table, { 'a' }, written by each format: nothing in it needs version 1.
    local body = '\3\0' .. string.pack('<d', 1) .. '\33a\4'
    for version = 0, 1 do
      local payload = string.char(version) .. body
      local value = save.decodeLuaData(buffer.fromstring(payload), 0, #payload)
      expect(value.version).toBe(version)
      expect(save.encodeLuaData(value)).toBe(payload)
      expect(tes3.display.luaValue(value, true)).toEqual { 'a' }
    end
  end)

  suite.it('writes a value of its own in the oldest format that holds it', function()
    local plain: tes3.LuaValue = { kind = 'number', value = 1.5 }
    local whole: tes3.LuaValue = { kind = 'integer', value = 3i }
    expect(string.byte(save.encodeLuaData(plain), 1)).toBe(0)
    expect(string.byte(save.encodeLuaData(whole), 1)).toBe(1)
    expect(string.byte(save.encodeLuaData(plain, 1), 1)).toBe(1)
    expect(function() save.encodeLuaData(whole, 0) end).toThrow 'an integer is not valid in Lua serialization format version 0'
    expect(function() save.encodeLuaData(plain, 2) end).toThrow 'unsupported Lua serialization format version 2'
  end)

  suite.it('refuses an integer in a version 0 payload, as OpenMW does', function()
    local payload = '\0\5' .. string.pack('<i8', 7)
    expect(function() save.decodeLuaData(buffer.fromstring(payload), 0, #payload) end).toThrow 'an integer is not valid in Lua serialization format version 0 at offset 1'
    expect(function() save.decodeLuaData(buffer.fromstring '\1\5\1\2', 0, 4) end).toThrow 'unexpected end of serialized Lua data'
  end)

  suite.it('shows a Lua table as a list only when its keys count up from one', function()
    type Entry = { key: tes3.LuaValue, value: tes3.LuaValue }

    local function entry(key: number, value: string): Entry
      return { key = { kind = 'number', value = key }, value = { kind = 'string', value = value } }
    end

    local function shown(...: Entry): unknown
      return tes3.display.luaValue { kind = 'table', entries = { ... } }
    end

    expect(shown()).toEqual {}
    expect(tes3.display.luaValue { kind = 'table' }).toEqual {}
    expect(shown(entry(1, 'a'))).toEqual { 'a' }
    expect(shown(entry(1, 'a'), entry(2, 'b'))).toEqual { 'a', 'b' }
    expect(shown(entry(2, 'a'))).toEqual { ['2'] = 'a' }
    expect(shown(entry(1, 'a'), entry(3, 'b'))).toEqual { ['1'] = 'a', ['3'] = 'b' }
    expect(shown(entry(2, 'a'), entry(1, 'b'))).toEqual { ['1'] = 'b', ['2'] = 'a' }
    expect(shown(entry(1, 'a'), entry(2.5, 'b'))).toEqual { ['1'] = 'a', ['2.5'] = 'b' }
  end)

  suite.it('shows, collects, and writes back an object list, each reference in its place', function()
    local list = '\0'
      .. string.char(0x46)
      .. u32(16)
      .. 'objlist'
      .. string.pack('<I4i4I4i4', 7, 0, 8, -1)
    local value = save.decodeLuaData(buffer.fromstring(list), 0, #list)
    expect(save.encodeLuaData(value)).toBe(list)
    expect(tes3.display.luaValue(value)).toEqual {
      objlist = { { index = 7, contentFile = 0 }, { index = 8, contentFile = -1 } },
    }

    expect(tes3.display.luaValue(value, true)).toEqual {
      objlist = { { index = 7, content_file = 0 }, { index = 8, content_file = -1 } },
    }

    -- A list of none, and a value with no list at all.
    local none = '\0' .. string.char(0x46) .. u32(0) .. 'objlist'
    local empty = save.decodeLuaData(buffer.fromstring(none), 0, #none)
    expect(empty.refs).toEqual {}
    expect(tes3.display.luaValue(empty)).toEqual { objlist = {} }
    expect(tes3.display.luaValue { kind = 'objectList' }).toEqual { objlist = {} }
    expect(save.luaRefs(empty)).toEqual {}
    expect(save.luaRefs { kind = 'table' }).toEqual {}

    -- References are added to a list handed in, after what it holds, in the order they're met.
    local held = { { index = 1, contentFile = 0 } }
    local nested: tes3.LuaValue = {
      kind = 'table',
      entries = {
        { key = { kind = 'object', ref = { index = 2, contentFile = 0 } }, value = value },
        {
          key = { kind = 'string', value = 'last' },
          value = { kind = 'object', ref = { index = 3, contentFile = 0 } },
        },
      },
    }
    expect(save.luaRefs(nested, held)).toBe(held)
    expect(held).toEqual {
      { index = 1, contentFile = 0 },
      { index = 2, contentFile = 0 },
      { index = 7, contentFile = 0 },
      { index = 8, contentFile = -1 },
      { index = 3, contentFile = 0 },
    }
  end)
end)

suite.describe('display', function()
  suite.it('shows a record the typed model can\'t read as why, and its subrecords', function()
    local plugin = open(record('BOOK', subrecord('ZZZZ', 'ab') .. subrecord('NAME', 'b\0')))
    expect(tes3.display.display(plugin, 0)).toEqual {
      record = 0,
      type = 'BOOK',
      id = 'b',
      undecoded = 'Unexpected Tag: BOOK::ZZZZ',
      subrecords = { 'ZZZZ (2 bytes)', 'NAME (2 bytes)' },
    }
  end)

  suite.it('keeps only the CELL references asked for, by where they are in the record', function()
    local function reference(index: number, name: string): string
      return subrecord('FRMR', u32(index))
        .. subrecord('NAME', name .. '\0')
        .. subrecord('DATA', string.rep('\0', 24))
    end

    local plugin = open(
      record(
        'CELL',
        subrecord('NAME', 'cell\0')
          .. subrecord('DATA', string.rep('\0', 12))
          .. reference(3, 'three')
          .. reference(1, 'one')
          .. reference(2, 'two')
      )
    )

    --- The ids of the references shown, or nil when none is.
    local function ids(references: { number }?): { string }?
      local shown = tes3.display.display(plugin, 0, references).references :: { tes3.Value }?
      if not shown then return nil end

      return [for entry in shown => entry.id :: string]
    end

    expect(ids(nil)).toEqual { 'one', 'two', 'three' }
    expect(ids { 0 }).toEqual { 'three' }
    expect(ids { 2, 1 }).toEqual { 'one', 'two' }
    expect(ids { 0, 0, 2 }).toEqual { 'two', 'three' }
    expect(ids {}).toBeNil()
    expect(ids { 9 }).toBeNil()
  end)
end)

--- Where this file is, from its chunk name: the folder the suite and its asset are in.
local function here(): string
  local source = debug.info(1, 's')
  local first = string.sub(source, 1, 1)
  local path = if first == '@' or first == '=' then string.sub(source, 2) else source

  return string.match(path, '^(.*)/[^/]*$') or '.'
end

--- jess-omwaddon's plugin with a record of every type: what jess's contract fixtures opened.
local function allTypes(): tes3.Plugin
  return tes3.open(assert(jess.fs.readBuffer(`{here()}/assets/all_types.esp`)))
end

--- FNV-1a (32 bits) of a buffer's bytes, as the contracts' expected results spell a buffer.
local function fnv(data: buffer): string
  local hash = 2166136261
  for index = 0, buffer.len(data) - 1 do
    hash = bit32.bxor(hash, buffer.readu8(data, index))
    -- hash * 16777619, kept exact: 16777619 is 2^24 + 403.
    hash = (bit32.lshift(hash, 24) + hash * 403) % 4294967296
  end

  return string.format('%08x', hash)
end

local function firstOf(plugin: tes3.Plugin, tag: string): number
  for index = 0, plugin:count() - 1 do
    if plugin:tag(index) == tag then return index end
  end

  return error(`no {tag} record`)
end

--- Which parts a terrain has, with each buffer's length.
local function partsOf(terrain: tes3.LandTerrain): { [string]: unknown }
  local function length(part: buffer?): number? return if part then buffer.len(part) else nil end

  return {
    grid = terrain.grid,
    flags = terrain.flags,
    heightOffset = terrain.heightOffset,
    heights = length(terrain.heights),
    normals = length(terrain.normals),
    colors = length(terrain.colors),
    textures = length(terrain.textures),
    worldMap = length(terrain.worldMap),
  }
end

local Vertices = 65 * 65

-- jess's `jess.land` contract (`contracts/land`) and its `land.rs` cases: the same answers, but
-- for errors naming `land.read` and `land.write`, not `jess.land.read` and `jess.land.write`.
suite.describe('LAND terrain', function()
  suite.it('reads a LAND\'s parts as buffers', function()
    local plugin = allTypes()
    local land = firstOf(plugin, 'LAND')
    local terrain = tes3.land.read(plugin, land)
    expect(terrain.grid).toEqual { -15, -8 }
    expect(terrain.flags).toBe(15)
    expect(terrain.heightOffset).toBe(-256)
    expect({
      heights = fnv(terrain.heights :: buffer),
      normals = fnv(terrain.normals :: buffer),
      colors = fnv(terrain.colors :: buffer),
      textures = fnv(terrain.textures :: buffer),
      worldMap = fnv(terrain.worldMap :: buffer),
    }).toEqual {
      heights = 'fdf160a4',
      normals = 'ecac9ce8',
      colors = 'a00d8f49',
      textures = '64916e85',
      worldMap = 'a2e768ee',
    }

    expect(partsOf(terrain)).toEqual {
      grid = { -15, -8 },
      flags = 15,
      heightOffset = -256,
      heights = 16900,
      normals = 12675,
      colors = 12675,
      textures = 512,
      worldMap = 81,
    }

    expect(partsOf(tes3.land.read(plugin, land, { 'heights', 'worldMap' }))).toEqual {
      grid = { -15, -8 },
      flags = 15,
      heightOffset = -256,
      heights = 16900,
      worldMap = 81,
    }

    expect(partsOf(tes3.land.read(plugin, land, {}))).toEqual { grid = { -15, -8 }, flags = 15 }
  end)

  suite.it('sums VHGT\'s deltas down the first column and along each row', function()
    local deltas = buffer.create(4 + Vertices + 3)
    buffer.writef32(deltas, 0, 2.5)
    -- Row 0 starts at 3 and climbs one a vertex; row 1 starts 2 below row 0's start and falls.
    buffer.writei8(deltas, 4, 3)
    buffer.writei8(deltas, 4 + 65, -2)
    for column = 1, 64 do
      buffer.writei8(deltas, 4 + column, 1)
      buffer.writei8(deltas, 4 + 65 + column, -1)
    end

    local plugin = open(
      record(
        'LAND',
        subrecord('INTV', string.pack('<i4i4', 1, 2))
          .. subrecord('DATA', u32(1))
          .. subrecord('VHGT', buffer.tostring(deltas))
      )
    )
    local terrain = tes3.land.read(plugin, 0)
    local heights = terrain.heights :: buffer
    expect(terrain.heightOffset).toBe(2.5)
    expect({
      buffer.readi32(heights, 0),
      buffer.readi32(heights, 64 * 4),
      buffer.readi32(heights, 65 * 4),
      buffer.readi32(heights, (65 + 64) * 4),
      buffer.readi32(heights, 130 * 4),
    }).toEqual { 3, 67, 1, -63, 1 }
    expect(terrain.normals).toBeNil()

    -- Writing the heights back gives VHGT the same deltas.
    tes3.land.write(plugin, 0, { heights = heights })
    local source, at, size = plugin:findSubrecord(0, tes3.tags.code 'VHGT')
    expect(buffer.readstring(source :: buffer, at, size)).toBe(buffer.tostring(deltas))
  end)

  suite.it('writes a terrain back without changing a byte', function()
    local bytes = assert(jess.fs.readBuffer(`{here()}/assets/all_types.esp`))
    local plugin = tes3.open(bytes)
    local land = firstOf(plugin, 'LAND')
    tes3.land.write(plugin, land, tes3.land.read(plugin, land))
    expect(plugin:isDirty(land)).toBe(false)
    expect(buffer.tostring(plugin:save()) == buffer.tostring(bytes)).toBe(true)
  end)

  suite.it('writes heights, and leaves out a part given as false', function()
    local plugin = allTypes()
    local land = firstOf(plugin, 'LAND')
    local heights = buffer.create(Vertices * 4)
    for vertex = 0, Vertices - 1 do
      buffer.writei32(heights, vertex * 4, (vertex % 65) * 2)
    end

    tes3.land.write(plugin, land, { heights = heights, heightOffset = -16, worldMap = false })
    local written = tes3.land.read(plugin, land)
    expect(partsOf(written)).toEqual {
      grid = { -15, -8 },
      flags = 15,
      heightOffset = -16,
      heights = 16900,
      normals = 12675,
      colors = 12675,
      textures = 512,
    }

    expect({
      buffer.readi32(written.heights :: buffer, 0),
      buffer.readi32(written.heights :: buffer, 64 * 4),
    }).toEqual { 0, 128 }
    expect(tags(plugin, land)).toEqual { 'INTV', 'DATA', 'VNML', 'VHGT', 'VCLR', 'VTEX' }
    -- The parts the write didn't name are the bytes they were.
    expect(fnv(written.normals :: buffer)).toBe 'ecac9ce8'
    expect(fnv(written.colors :: buffer)).toBe 'a00d8f49'
    expect(fnv(written.textures :: buffer)).toBe '64916e85'
  end)

  suite.it('leaves every other record\'s bytes alone', function()
    local bytes = assert(jess.fs.readBuffer(`{here()}/assets/all_types.esp`))
    local plugin, original = tes3.open(bytes), tes3.open(bytes)
    local land = firstOf(plugin, 'LAND')
    local colors = buffer.create(Vertices * 3)
    buffer.fill(colors, 0, 200)
    tes3.land.write(plugin, land, { colors = colors, grid = { 4, -5 } })

    local saved = tes3.open(plugin:save())
    expect(saved:count()).toBe(original:count())
    local changed = {}
    for index = 0, original:count() - 1 do
      if buffer.tostring(saved:bytes(index)) ~= buffer.tostring(original:bytes(index)) then
        table.insert(changed, index)
      end
    end

    expect(changed).toEqual { land }
    -- Within the LAND, only the grid and the colors are new bytes.
    local differing = {}
    local before, after = original:subrecords(land), saved:subrecords(land)
    local was, now = original:span(land), saved:span(land)
    for ordinal, sub in before do
      local other = after[ordinal]
      expect(other.tag).toBe(sub.tag)
      local same = buffer.readstring(was, sub.payload, sub.size)
        == buffer.readstring(now, other.payload, other.size)
      if not same then table.insert(differing, sub.tag) end
    end

    expect(differing).toEqual { 'INTV', 'VCLR' }
    expect(tes3.land.read(saved, land, {}).grid).toEqual { 4, -5 }
  end)

  suite.it('builds a LAND from its parts', function()
    local plugin = tes3.new()
    plugin:insertValue(1, {
      type = 'Landscape',
      grid = { 3, -2 },
      landscapeFlags = 'USES_VERTEX_HEIGHTS_AND_NORMALS | USES_TEXTURES',
    })

    local heights, normals = buffer.create(Vertices * 4), buffer.create(Vertices * 3)
    local textures = buffer.create(512)
    for vertex = 0, Vertices - 1 do
      buffer.writei32(heights, vertex * 4, (vertex % 65) * 3 - (vertex // 65) * 2)
      buffer.writei8(normals, vertex * 3 + 2, 127)
    end

    buffer.writeu16(textures, 510, 7)
    tes3.land.write(
      plugin,
      1,
      { heightOffset = -4, heights = heights, normals = normals, textures = textures }
    )

    local terrain = tes3.land.read(plugin, 1)
    expect(terrain.grid).toEqual { 3, -2 }
    expect(terrain.flags).toBe(5)
    expect(terrain.heightOffset).toBe(-4)
    expect(buffer.tostring(terrain.heights :: buffer) == buffer.tostring(heights)).toBe(true)
    expect(buffer.tostring(terrain.normals :: buffer) == buffer.tostring(normals)).toBe(true)
    expect(buffer.readu16(terrain.textures :: buffer, 510)).toBe(7)
    expect(terrain.colors).toBeNil()
    expect(buffer.len(terrain.worldMap :: buffer)).toBe(81)
    expect(((plugin:decode(1) :: tes3.Value).vertexHeights :: tes3.Value).offset).toBe(-4)

    tes3.land.write(plugin, 1, { worldMap = false })
    expect(tags(plugin, 1)).toEqual { 'INTV', 'DATA', 'VNML', 'VHGT', 'VTEX' }
    expect(tes3.land.read(plugin, 1).worldMap).toBeNil()

    local only = tes3.land.read(plugin, 1, { 'textures' })
    expect(only.heights).toBeNil()
    expect(only.normals).toBeNil()
    expect(only.textures ~= nil).toBe(true)

    -- The flags decide the subrecords: colors come, and textures go. The world map this LAND
    -- lost stays lost, as a write changes only what the terrain does.
    tes3.land.write(plugin, 1, { flags = 3, heightOffset = 9 })
    expect(tags(plugin, 1)).toEqual { 'INTV', 'DATA', 'VNML', 'VHGT', 'VCLR' }
    expect(tes3.land.read(plugin, 1, { 'heights' }).heightOffset).toBe(9)
    expect((plugin:decode(1) :: tes3.Value).landscapeFlags).toBe 'USES_VERTEX_HEIGHTS_AND_NORMALS | USES_VERTEX_COLORS'
  end)

  suite.it('counts a subrecord given twice as its last, and refuses one of the wrong size', function()
    local first, second = string.rep('\1', 81), string.rep('\2', 81)
    local twice = open(
      record(
        'LAND',
        subrecord('INTV', string.pack('<i4i4', 0, 0))
          .. subrecord('WNAM', first)
          .. subrecord('WNAM', second)
      )
    )
    expect(buffer.tostring(tes3.land.read(twice, 0).worldMap :: buffer)).toBe(second)
    expect(tes3.land.read(twice, 0).flags).toBeNil()

    local short = open(record('LAND', subrecord('VNML', 'short')))
    expect(function() tes3.land.read(short, 0, { 'normals' }) end).toThrow 'LAND VNML is 5 bytes, not 12675'
    -- A part that isn't asked for isn't checked.
    expect(partsOf(tes3.land.read(short, 0, { 'colors' }))).toEqual {}
    local flagless = open(record('LAND', subrecord('DATA', '\1')))
    expect(function() tes3.land.read(flagless, 0, {}) end).toThrow 'LAND DATA is 1 bytes, not 4'
  end)

  suite.it('refuses what isn\'t a LAND or a terrain', function()
    local plugin = allTypes()
    local land, light = firstOf(plugin, 'LAND'), firstOf(plugin, 'LIGH')
    local before = buffer.tostring(plugin:bytes(land))
    local tooSteep, cliff = buffer.create(Vertices * 4), buffer.create(Vertices * 4)
    buffer.writei32(tooSteep, 4, 1000)
    buffer.writei32(cliff, 66 * 4, -200)

    -- Each call is the error it is checked to raise.
    expect(function() tes3.land.read(plugin, land, { 'heigths' :: any }) end).toThrow 'unknown LAND part \'heigths\'; expected heights, normals, colors, textures, or worldMap'
    expect(function() tes3.land.read(plugin, light) end).toThrow 'land.read takes a LAND record, not LIGH'
    expect(function() tes3.land.write(plugin, light, {}) end).toThrow 'land.write takes a LAND record'
    expect(function() tes3.land.write(plugin, land, { colors = buffer.create(3) }) end).toThrow 'LAND colors must be 12675 bytes, not 3'
    expect(function() tes3.land.write(plugin, land, { normals = 'x' :: any }) end).toThrow 'LAND normals must be a buffer, not string'
    expect(function() tes3.land.write(plugin, land, { textures = true :: any }) end).toThrow 'LAND textures must be a buffer, not boolean'
    expect(function() tes3.land.write(plugin, land, { grid = { 1 } }) end).toThrow 'LAND grid must be { x, y }'
    expect(function() tes3.land.write(plugin, land, { grid = { 1, 2.5 } }) end).toThrow 'LAND grid must be { x, y }'
    expect(function() tes3.land.write(plugin, land, { flags = 'USES_TEXTURES' :: any }) end).toThrow 'LAND flags must be a number, not string'
    expect(function() tes3.land.write(plugin, land, { heights = tooSteep }) end).toThrow 'LAND heights step too far at vertex (1, 0): a delta must fit in an i8'
    expect(function() tes3.land.write(plugin, land, { heights = cliff }) end).toThrow 'LAND heights step too far at vertex (1, 1): a delta must fit in an i8'
    expect(function() tes3.land.write(plugin, land, { height = cliff } :: any) end).toThrow 'unknown land.write option \'height\': expected colors, flags, grid, heightOffset, heights, normals, textures, or worldMap'
    -- A write that fails changes nothing, even with parts before the bad one that were fine.
    expect(function()
      tes3.land.write(plugin, land, { grid = { 9, 9 }, worldMap = buffer.create(80) })
    end).toThrow 'LAND worldMap must be 81 bytes, not 80'
    expect(buffer.tostring(plugin:bytes(land))).toBe(before)
  end)
end)

-- jess's `jess.meta` contract (`contracts/meta`): what a record handle's metadata answered, from
-- the plugin and the record's number.
suite.describe('record metadata', function()
  suite.it('gives each record\'s tag, type, id, size, and header flags', function()
    local plugin = allTypes()
    type Expected =
      { index: number, tag: string, name: string, id: string?, size: number, flags: number }

    local records: { Expected } = {
      { index = 0, tag = 'TES3', name = 'Header', size = 421, flags = 0 },
      { index = 11, tag = 'SKIL', name = 'Skill', size = 70, flags = 0 },
      { index = 12, tag = 'MGEF', name = 'MagicEffect', size = 312, flags = 0 },
      { index = 16, tag = 'SSCR', name = 'StartScript', id = 'test_script', size = 45, flags = 0 },
      {
        index = 17,
        tag = 'LTEX',
        name = 'LandscapeTexture',
        id = 'Tx_BC_mainroad_01.tga',
        size = 72,
        flags = 0,
      },
      { index = 36, tag = 'LIGH', name = 'Light', id = 'test_light', size = 158, flags = 8192 },
      { index = 37, tag = 'LIGH', name = 'Light', id = 'test_light_p', size = 160, flags = 9216 },
      { index = 64, tag = 'CELL', name = 'Cell', id = 'test_exterior', size = 70, flags = 0 },
      { index = 65, tag = 'LAND', name = 'Landscape', size = 30243, flags = 0 },
      {
        index = 66,
        tag = 'CELL',
        name = 'Cell',
        id = 'Dagoth Ur, Facility Cavern',
        size = 305,
        flags = 0,
      },
      { index = 68, tag = 'PGRD', name = 'PathGrid', id = 'test_interior', size = 138, flags = 0 },
      {
        index = 71,
        tag = 'INFO',
        name = 'DialogueInfo',
        id = '3159038603265019263',
        size = 117,
        flags = 0,
      },
    }

    for _, expected in records do
      local index = expected.index
      expect(plugin:tag(index)).toBe(expected.tag)
      expect(tes3.typeName(plugin:tag(index))).toBe(expected.name)
      expect(tes3.records.fieldId(plugin, index) or tes3.records.id(plugin, index)).toBe(expected.id)
      expect(plugin:size(index)).toBe(expected.size)
      expect(tes3.records.headerFlags(plugin, index).value).toBe(expected.flags)
    end

    expect(tes3.records.headerFlags(plugin, 36)).toEqual {
      value = 8192,
      deleted = false,
      persistent = false,
      ignored = false,
      blocked = true,
    }

    expect(tes3.records.headerFlags(plugin, 37)).toEqual {
      value = 9216,
      deleted = false,
      persistent = true,
      ignored = false,
      blocked = true,
    }
  end)

  suite.it('names every bit the format does, and follows an edit', function()
    local plugin = open(
      record('STAT', subrecord('NAME', 'gone\0'), 0x20)
        .. record('STAT', subrecord('NAME', 'skipped\0'), 0x1000 + 0x40)
    )
    expect(tes3.records.headerFlags(plugin, 0)).toEqual {
      value = 0x20,
      deleted = true,
      persistent = false,
      ignored = false,
      blocked = false,
    }

    expect(tes3.records.headerFlags(plugin, 1)).toEqual {
      value = 0x1040,
      deleted = false,
      persistent = false,
      ignored = true,
      blocked = false,
    }

    local value = plugin:decode(0) :: tes3.Value
    value.flags = 'PERSISTENT | BLOCKED'
    plugin:set(0, value)
    expect(tes3.records.headerFlags(plugin, 0).value).toBe(0x2400)
  end)

  suite.it('lists object keys by type and then id, each once', function()
    local plugin = open(
      record('TES3', hedr(0, '', '', 0))
        .. record('STAT', subrecord('NAME', 'b\0'))
        .. record('MISC', subrecord('NAME', 'z\0'))
        .. record('STAT', subrecord('NAME', 'a\0'))
        .. record('STAT', subrecord('NAME', 'b\0'))
        .. record('STAT', subrecord('NAME', 'B\0'))
        .. record('STAT', subrecord('NAME', 'ab\0'))
        .. record('STAT', subrecord('NAME', '\0'))
        .. record('ABC\\', subrecord('NAME', 'x\0'))
        .. record('ABC\1', subrecord('NAME', 'a\0'))
        .. record('INFO', subrecord('INAM', '10\0'))
        .. record('INFO', subrecord('INAM', '9\0'))
        .. record('STAT', '')
    )
    expect(tes3.records.objectKeys(plugin)).toEqual {
      { type = 'ABC\\', id = 'x' },
      { type = 'ABC\\x01', id = 'a' },
      { type = 'INFO', id = '10' },
      { type = 'INFO', id = '9' },
      { type = 'MISC', id = 'z' },
      { type = 'STAT', id = '' },
      { type = 'STAT', id = 'B' },
      { type = 'STAT', id = 'a' },
      { type = 'STAT', id = 'ab' },
      { type = 'STAT', id = 'b' },
    }
  end)

  suite.it('gives a record\'s string fields where they are, and its first id', function()
    local plugin = open(
      record(
        'INFO',
        subrecord('DATA', string.rep('\0', 12))
          .. subrecord('INAM', '7\0')
          .. subrecord('PNAM', '')
          .. subrecord('NAME', 'caf\xe9')
          .. subrecord('ZZZZ', 'not text')
          .. subrecord('NAME', 'again\0junk')
      ) .. record('CELL', subrecord('RGNN', 'region\0') .. subrecord('NAME', 'cell\0'))
    )
    expect(tes3.records.stringFields(plugin, 0)).toEqual {
      { name = 'info-id', value = '7', tag = 'INAM', subrecord = 1, start = 36, finish = 46 },
      { name = 'previous', value = '', tag = 'PNAM', subrecord = 2, start = 46, finish = 54 },
      { name = 'text', value = 'caf\u{e9}', tag = 'NAME', subrecord = 3, start = 54, finish = 66 },
      { name = 'text', value = 'again', tag = 'NAME', subrecord = 5, start = 82, finish = 100 },
    }
    expect(tes3.records.fieldId(plugin, 0)).toBe '7'
    expect(tes3.records.stringFields(plugin, 1)).toEqual {
      { name = 'region', value = 'region', tag = 'RGNN', subrecord = 0, start = 116, finish = 131 },
      { name = 'id', value = 'cell', tag = 'NAME', subrecord = 1, start = 131, finish = 144 },
    }
    expect(tes3.records.fieldId(plugin, 1)).toBe 'cell'
    expect(tes3.records.fieldId(open(record('STAT', subrecord('MODL', 'a\0'))), 0)).toBeNil()

    -- An edited record's fields are where they are in its own bytes.
    plugin:replaceSubrecord(1, 0, 'r\0')
    expect(tes3.records.stringFields(plugin, 1)).toEqual {
      { name = 'region', value = 'r', tag = 'RGNN', subrecord = 0, start = 16, finish = 26 },
      { name = 'id', value = 'cell', tag = 'NAME', subrecord = 1, start = 26, finish = 39 },
    }
  end)
end)

-- jess's `jess.plugin.new` contract (`contracts/plugin/build`): the same bytes, from the calls a
-- script makes today.
suite.describe('building', function()
  suite.it('builds the empty plugin jess.plugin.new built', function()
    local empty = tes3.new()
    local bytes = empty:save()
    expect(buffer.len(bytes)).toBe(324)
    expect(fnv(bytes)).toBe '11dc8ac6'
    expect(empty:masters()).toEqual {}
    expect(empty.encoding).toBe 'win1252'
  end)

  suite.it('builds a plugin with a header, masters, and a record', function()
    local master = tes3.new('master', { encoding = 'win1250' })
    master:setAuthor 'Jess'
    master:setDescription 'Built in a fixture'
    master:setMasters { { name = 'Base.esm', size = 1234 } }
    master:insertValue(master:count(), { type = 'Static', id = 'rock', mesh = 'rock.nif' })
    -- An insert leaves the header's count as it was; the script sets it before it saves.
    expect(master:header().recordCount).toBe(0)
    expect(master:updateRecordCount()).toBe(true)
    expect(master:header().recordCount).toBe(1)

    expect(master:setAuthor 'Someone').toBe(true)
    expect(master:setFileType 'plugin').toBe(true)
    expect(master:setAuthor 'Someone').toBe(false)
    local masters = { { name = 'Other.esm', size = 2 ^ 40 }, { name = 'Third.esm', size = 7 } }
    expect(master:setMasters(masters)).toBe(true)
    expect(master:setMasters(masters)).toBe(false)

    expect(master:header()).toEqual {
      version = string.unpack('<f', string.pack('<f', 1.3)),
      fileType = 'plugin',
      author = 'Someone',
      description = 'Built in a fixture',
      recordCount = 1,
    }

    expect(master:masters()).toEqual {
      { name = 'Other.esm', size = 1099511627776, mast = 1, data = 2 },
      { name = 'Third.esm', size = 7, mast = 3, data = 4 },
    }

    expect(master.encoding).toBe 'win1250'
    expect(master:updateRecordCount()).toBe(false)
    expect(master:tag(1)).toBe 'STAT'
    local bytes = master:save()
    expect(buffer.len(bytes)).toBe(438)
    expect(fnv(bytes)).toBe '3ae27591'
  end)
end)

suite.describe('round trips', function()
  suite.it('checks a round trip, with types left out and cruft skipped', function()
    local bytes = record('TES3', '') .. record('GMST', subrecord('NAME', 'a\0'))
    expect(tes3.checkRoundTrip(buffer.fromstring(bytes))).toBeNil()
    expect(tes3.checkRoundTrip(buffer.fromstring(bytes), { 'GMST' })).toBeNil()
    expect(tes3.checkRoundTrip(buffer.fromstring('junk' .. bytes), nil, true)).toBeNil()
    expect(tes3.checkRoundTrip(buffer.fromstring('junk' .. bytes))).toContain 'failed to parse plugin'
  end)
end)

return suite
