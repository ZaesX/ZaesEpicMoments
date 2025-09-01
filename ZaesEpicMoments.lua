-- ZaesEpicMoments.lua
-- Author: ChatGPT feat. Zaes
-- Version: 0.3.4
-- Purpose: make loading and slash commands bulletproof while keeping all tracking logic intact
-- Notes:
--  - Always show the frame on login so you can see it even in town
--  - Clear loaded banner so you know the addon actually initialized
--  - Slash aliases: /zem, /zaesepicmoments, /epicmoments
--  - Commands: show, hide, reset, vis

local EM = {}                                                -- Local namespace for UI helpers
local f = CreateFrame("Frame")                               -- Main event frame

local groupGUIDs, guidToName, guidToUnit = {}, {}, {}        -- Group caches
local perPlayerBest, perPlayerFailBest = {}, {}              -- Per-player bests
local interruptFails, interruptFailKinds = {}, {}            -- Interrupt fail counters
local deathCounts, nonTankHeavyHits = {}, {}                 -- Death and non-tank hit counters
local recentEnemyCasts = {}                                  -- Enemy cast memory for interrupt judging
local pendingInterrupts = {}                                 -- Pending interrupt attempts

local records = {}                                           -- Session summary records
records.topDamage       = { amount = 0, spell = "None", player = "None", crit = false }
records.topHeal         = { amount = 0, spell = "None", player = "None", crit = false }
records.topCrit         = { amount = 0, spell = "None", player = "None", crit = false, kind = "None" }
records.failOverkill    = { amount = 0, spell = "None", player = "None", by = "None" }
records.failOverheal    = { amount = 0, spell = "None", player = "None" }
records.failDamageTaken = { amount = 0, spell = "None", player = "None", by = "None" }

local function FormatNum(n)                                  -- Simple thousands formatter (Wrath-safe)
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

local INTERRUPT_SPELLS = {}                                  -- Core Wrath interrupts
INTERRUPT_SPELLS[1766]  = true                               -- Rogue Kick
INTERRUPT_SPELLS[6552]  = true                               -- Warrior Pummel
INTERRUPT_SPELLS[72]    = true                               -- Warrior Shield Bash
INTERRUPT_SPELLS[47528] = true                               -- Death Knight Mind Freeze
INTERRUPT_SPELLS[2139]  = true                               -- Mage Counterspell
INTERRUPT_SPELLS[57994] = true                               -- Shaman Wind Shear

local function ColorName(name)                               -- Class-colored names when possible
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
            if c then return string.format("|cff%02x%02x%02x%s|r", c.r*255, c.g*255, c.b*255, name) end
        end
    end
    if UnitName("player") == name then
        local _, class = UnitClass("player")
        local c = class and RAID_CLASS_COLORS[class]
        if c then return string.format("|cff%02x%02x%02x%s|r", c.r*255, c.g*255, c.b*255, name) end
    end
    return name
end

local function IsInMyGroup(guid)                              -- Quick group GUID check
    if not guid then return false end
    return groupGUIDs[guid] and true or false
end

local function RememberUnitToken(guid, unit)                  -- Cache a nice unit token for that GUID
    if guid and unit and UnitExists(unit) then guidToUnit[guid] = unit end
end

local function RebuildGroup()                                 -- Re-scan raid/party every time roster changes
    for k in pairs(groupGUIDs) do groupGUIDs[k] = nil end
    for k in pairs(guidToName) do guidToName[k] = nil end
    for k in pairs(guidToUnit) do guidToUnit[k] = nil end

    if GetNumRaidMembers() > 0 then
        for i = 1, GetNumRaidMembers() do
            local u = "raid"..i
            if UnitExists(u) and not UnitIsUnit(u, "pet") then
                local g, n = UnitGUID(u), UnitName(u)
                if g and n then groupGUIDs[g] = true; guidToName[g] = n; RememberUnitToken(g, u) end
            end
        end
        return
    end

    local pg, pn = UnitGUID("player"), UnitName("player")
    if pg and pn then groupGUIDs[pg] = true; guidToName[pg] = pn; RememberUnitToken(pg, "player") end

    for i = 1, GetNumPartyMembers() do
        local u = "party"..i
        if UnitExists(u) then
            local g, n = UnitGUID(u), UnitName(u)
            if g and n then groupGUIDs[g] = true; guidToName[g] = n; RememberUnitToken(g, u) end
        end
    end
end

local function ResetRecords()                                 -- Full session reset
    records.topDamage.amount, records.topDamage.spell, records.topDamage.player, records.topDamage.crit = 0,"None","None",false
    records.topHeal.amount,   records.topHeal.spell,   records.topHeal.player,   records.topHeal.crit   = 0,"None","None",false
    records.topCrit.amount,   records.topCrit.spell,   records.topCrit.player,   records.topCrit.crit,  records.topCrit.kind = 0,"None","None",false,"None"

    records.failOverkill.amount, records.failOverkill.spell, records.failOverkill.player, records.failOverkill.by = 0,"None","None","None"
    records.failOverheal.amount, records.failOverheal.spell, records.failOverheal.player = 0,"None","None"
    records.failDamageTaken.amount, records.failDamageTaken.spell, records.failDamageTaken.player, records.failDamageTaken.by = 0,"None","None","None"

    for k in pairs(perPlayerBest) do perPlayerBest[k] = nil end
    for k in pairs(perPlayerFailBest) do perPlayerFailBest[k] = nil end
    for k in pairs(interruptFails) do interruptFails[k] = nil end
    for k in pairs(interruptFailKinds) do interruptFailKinds[k] = nil end
    for k in pairs(deathCounts) do deathCounts[k] = nil end
    for k in pairs(nonTankHeavyHits) do nonTankHeavyHits[k] = nil end
    for k in pairs(recentEnemyCasts) do recentEnemyCasts[k] = nil end
    for i = #pendingInterrupts, 1, -1 do table.remove(pendingInterrupts, i) end

    EM.UpdateUI()
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00ZaesEpicMoments: records reset.|r")
end
_G["ZaesEpicMoments_Reset"] = ResetRecords                   -- Used by the Reset button

local function EpicScore(amount, isCrit, kind)               -- Scoring helper for epics
    local s = amount or 0
    if isCrit then s = s * 1.05 end
    if kind == "DMG" then s = s * 1.02 end
    return s
end

local function FailScore(kind, amount)                       -- Scoring helper for fails
    local a = amount or 0
    if kind == "OVERKILL" then return a * 1.02 end
    if kind == "OVERHEAL" then return a * 1.01 end
    if kind == "TAKEN"    then return a * 1.03 end
    if kind == "INT"      then return a * 1.04 end
    if kind == "DEATHS"   then return a * 1.05 end
    if kind == "NON_TANK" then return a * 1.02 end
    return a
end

local function ExtractDamageArgs(subevent, ...)              -- Unify damage payloads
    local ts, _, _, sGUID, sName, _, _, dGUID, dName, _, _, p12, p13, p14, p15, p16, p17, p18, p19, p20, p21 = ...
    local amount, overkill, critical, spellName = 0,0,false,"Melee"
    if subevent == "SWING_DAMAGE" then
        amount = p12 or 0
        overkill = p13 or 0
        critical = p21 or false
        spellName = "Melee"
        return sGUID, sName, dGUID, dName, amount, overkill, critical, spellName
    end
    if subevent == "SPELL_DAMAGE" or subevent == "RANGE_DAMAGE" then
        spellName = p13 or "Unknown"
        amount = p15 or 0
        overkill = p16 or 0
        critical = p21 or false
        return sGUID, sName, dGUID, dName, amount, overkill, critical, spellName
    end
    return sGUID, sName, dGUID, dName, 0, 0, false, "Unknown"
end

local function ExtractHealArgs(...)                          -- Unify heal payloads
    local ts, subevent, _, sGUID, sName, _, _, dGUID, dName, _, _, spellId, spellName, school, amount, overheal, absorbed, crit = ...
    local effective = (amount or 0) - (overheal or 0)
    if effective < 0 then effective = 0 end
    return subevent, sGUID, sName, dGUID, dName, effective, (overheal or 0), (crit or false), (spellName or "Unknown")
end

local function ConsiderDamage(sGUID, sName, amount, crit, spell)
    if not IsInMyGroup(sGUID) then return end
    if amount > records.topDamage.amount then
        records.topDamage.amount = amount
        records.topDamage.spell  = spell
        records.topDamage.player = sName or "Unknown"
        records.topDamage.crit   = crit and true or false
    end
    if crit and amount > records.topCrit.amount then
        records.topCrit.amount = amount
        records.topCrit.spell  = spell
        records.topCrit.player = sName or "Unknown"
        records.topCrit.crit   = true
        records.topCrit.kind   = "Damage"
    end
    local score = EpicScore(amount, crit, "DMG")
    local rec = perPlayerBest[sGUID]
    if not rec or score > rec.score then
        perPlayerBest[sGUID] = { score = score, amount = amount, spell = spell, player = sName or "Unknown", crit = crit and true or false, kind = "Damage" }
    end
end

local function ConsiderHeal(sGUID, sName, effective, crit, spell)
    if not IsInMyGroup(sGUID) then return end
    if effective > records.topHeal.amount then
        records.topHeal.amount = effective
        records.topHeal.spell  = spell
        records.topHeal.player = sName or "Unknown"
        records.topHeal.crit   = crit and true or false
    end
    if crit and effective > records.topCrit.amount then
        records.topCrit.amount = effective
        records.topCrit.spell  = spell
        records.topCrit.player = sName or "Unknown"
        records.topCrit.crit   = true
        records.topCrit.kind   = "Heal"
    end
    local score = EpicScore(effective, crit, "HEAL")
    local rec = perPlayerBest[sGUID]
    if not rec or score > rec.score then
        perPlayerBest[sGUID] = { score = score, amount = effective, spell = spell, player = sName or "Unknown", crit = crit and true or false, kind = "Heal" }
    end
end

local function ConsiderFailOverkill(sGUID, sName, dGUID, dName, overkill, spell)
    if overkill <= 0 or not IsInMyGroup(dGUID) then return end
    local victim = dName or "Unknown"
    local killer = sName or "Unknown"
    if overkill > records.failOverkill.amount then
        records.failOverkill.amount = overkill
        records.failOverkill.spell  = spell or "Unknown"
        records.failOverkill.player = victim
        records.failOverkill.by     = killer
    end
    local score = FailScore("OVERKILL", overkill)
    local rec = perPlayerFailBest[dGUID]
    if not rec or score > rec.score then
        perPlayerFailBest[dGUID] = { score = score, amount = overkill, spell = spell or "Unknown", player = victim, by = killer, kind = "Overkill" }
    end
end

local function ConsiderFailOverheal(sGUID, sName, overheal, spell)
    if overheal <= 0 or not IsInMyGroup(sGUID) then return end
    local healer = sName or "Unknown"
    if overheal > records.failOverheal.amount then
        records.failOverheal.amount = overheal
        records.failOverheal.spell  = spell or "Unknown"
        records.failOverheal.player = healer
    end
    local score = FailScore("OVERHEAL", overheal)
    local rec = perPlayerFailBest[sGUID]
    if not rec or score > rec.score then
        perPlayerFailBest[sGUID] = { score = score, amount = overheal, spell = spell or "Unknown", player = healer, kind = "Overheal" }
    end
end

local function ConsiderFailDamageTaken(sGUID, sName, dGUID, dName, amount, spell)
    if amount <= 0 or not IsInMyGroup(dGUID) then return end
    local victim = dName or "Unknown"
    local byname = sName or "Unknown"
    if amount > records.failDamageTaken.amount then
        records.failDamageTaken.amount = amount
        records.failDamageTaken.spell  = spell or "Melee"
        records.failDamageTaken.player = victim
        records.failDamageTaken.by     = byname
    end
    local score = FailScore("TAKEN", amount)
    local rec = perPlayerFailBest[dGUID]
    if not rec or score > rec.score then
        perPlayerFailBest[dGUID] = { score = score, amount = amount, spell = spell or "Melee", player = victim, by = byname, kind = "Damage Taken" }
    end
end

local function IsLikelyTank(guid)                            -- Simple tank heuristic
    if not guid or not guidToName[guid] then return false end
    loca
