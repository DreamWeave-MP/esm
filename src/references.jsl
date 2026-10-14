--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
The order a CELL keeps its references in, decoded and encoded alike (jess-omwaddon sorts them the
same way to load and to save): the persistent ones first, then by master, the plugin's own (0)
after every master's, then by index.
]]

local data = require '@dream/data'

type Value = { [string]: unknown }

-- A FRMR packs a master into 8 bits and an index into 24, so a reference's place is one number:
-- whether it's temporary, its master (the plugin's own as one past the last), and its index.
local IndexRange = 16777216
local OwnMaster = 256
local Temporary = 2 * OwnMaster * IndexRange

local function persistent(ref: Value): boolean
  return ref.movedCell ~= nil or ref.destination ~= nil or not ref.temporary
end

local function before(left: Value, right: Value): boolean
  local leftPersistent, rightPersistent = persistent(left), persistent(right)
  if leftPersistent ~= rightPersistent then return leftPersistent end

  local leftMaster, rightMaster = left.mastIndex :: number, right.mastIndex :: number
  if leftMaster == 0 then leftMaster = 4294967296 end

  if rightMaster == 0 then rightMaster = 4294967296 end

  if leftMaster ~= rightMaster then return leftMaster < rightMaster end

  return (left.refrIndex :: number) < (right.refrIndex :: number)
end

--- The references of `byKey` (each under its master and index as one number, so no two share
--- both) in a CELL's order.
local function ordered(byKey: { [number]: Value }): { Value }
  local list: { Value } = {}
  for _, ref in byKey do
    table.insert(list, ref)
  end

  local count = #list
  if count < 2 then return list end

  local keys = buffer.create(count * 8)
  for position, ref in list do
    local master, index = ref.mastIndex :: number, ref.refrIndex :: number
    -- A value's master and index are whatever a script set them to, and only whole ones a FRMR
    -- holds make a key; anything else is compared the long way.
    if
      master % 1 ~= 0
      or master < 0
      or master >= OwnMaster
      or index % 1 ~= 0
      or index < 0
      or index >= IndexRange
    then
      table.sort(list, before)
      return list
    end

    buffer.writef64(
      keys,
      (position - 1) * 8,
      (if persistent(ref) then 0 else Temporary)
        + (if master == 0 then OwnMaster else master) * IndexRange
        + index
    )
  end

  local order = buffer.create(count * 4)
  data.argsort(keys, 'f64', 0, count, order)
  return [for position in order[1:count, 'u32'] => list[position + 1]]
end

return table.freeze { ordered = ordered, persistent = persistent }
