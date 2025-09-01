-- ZaesEpicMoments.lua
-- Author: ChatGPT feat. Zaes
-- Version: 0.3.3
-- Changes:
--  - Hardened visibility logic (safer IsInInstance() handling)
--  - Added a tiny deferred visibility refresh on login to catch late roster/instance init
--  - Added /zem vis to print current visibility reasons
-- Everything else is the same feature-wise.

local EM = {}                                                -- Local namespace for UI helpers
local f = CreateFrame("Frame")                               -- Main event frame

-- State caches
local groupGUIDs, guidToName, guidToUnit = {}, {}, {}
local perPlayerBest, perPlayerFailBest = {}, {}
local interruptFails, interruptFailKinds = {}, {}
local deathCounts, nonTankHeavyHits = {}, {}
local recentEnemyCasts = {}
local pendingInterrupts = {}

-- Session records
local records = {}
records.topDamage       = { amount = 0, spell = "None", player = "None", crit = false }
records.topHeal         = { amount = 0, spell = "None", player = "None", crit = false }
records.topCrit         = { amount = 0, spell = "None", player = "None", crit = false, kind = "None" }
records.failOverkill    = { amount = 0, spell = "None", player = "None", by = "None" }
records.failOverheal    = { amount = 0, spell = "None", player = "None" }
records.failDamageTaken = { amount = 0, spell = "None", player = "None", by = "None" }

-- Number formatter for Wrath
local function FormatNum(n)
    local x = tonumber(n) or 0
    local s = tostring(math.floor(x + 0.5))
    local left, num, right = string.match(s, '^([^%d]*%d)(%d*)(.-)$')
    if not left then return s end
    local formatted = left
    while string.len(num) > 3 do
        formatted = formatted .. "," .. string.sub(num, 1, 3)
        num = string.sub(num, 4)
    end
    return formatted .. num .. right
end

-- Interrupt spell IDs
local INTERRUPT_SPELLS = { [1766]=true, [6552]=true, [72]=true, [47528]=true, [2139]=true, [57994]=true }

-- Coloring helper
local function ColorName(name)
    for i = 1, GetNumRaidMembers() do
        local u = "raid"..i
        if UnitExists(u) and UnitName(u) == name then
            local _, class = UnitClass(u)
            local c = class and RAID_CLASS_COLORS[class]
            if c then return string.format("|cff%02x%02x%02x%s|r", c.r*255, c.g*255, c.b*255, name) end
        end
    end
    for i = 1, GetNumPartyMembers() do
        local u = "party"..i
        if UnitExists(u) and UnitName(u) == name then
            local _, class = UnitClass(u)
            local c = class and RAID_CLASS_COLORS[class]
            if c then return string.format("|cff%02x%02x%02x%s|r"
