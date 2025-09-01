-- ZaesEpicMoments.lua
-- Author: ChatGPT feat. Zaes
-- Version: 0.3.1
-- Addon: ZaesEpicMoments
-- WotLK 3.3.5a friendly for Project Epoch
-- Tracks group-wide biggest hits/heals and "Epic Fails" such as overkill, overheal, interrupt whiffs, many deaths, and non-tanks getting chunked
-- Clean style, heavy line comments, no block comments

local EM = {}                                                -- Local namespace for UI helpers

local f = CreateFrame("Frame")                               -- Event frame for registrations

local groupGUIDs = {}                                        -- Set of group member GUIDs for quick containment checks
local guidToName = {}                                        -- Map GUID -> name for nice printing
local guidToUnit = {}                                        -- Map GUID -> a useful unit token for HP/class checks

local perPlayerBest = {}                                     -- Map GUID -> their best positive epic record this session
local perPlayerFailBest = {}                                 -- Map GUID -> their best fail record this session

local records = {}                                           -- Session-wide summary records table

records.topDamage       = { amount = 0, spell = "None", player = "None", crit = false }
records.topHeal         = { amount = 0, spell = "None", player = "None", crit = false }
records.topCrit         = { amount = 0, spell = "None", player = "None", crit = false, kind = "None" }
records.failOverkill    = { amount = 0, spell = "None", player = "None", by = "None" }
records.failOverheal    = { amount = 0, spell = "None", player = "None" }
records.failDamageTaken = { amount = 0, spell = "None", player = "None", by = "None" }

local interruptFails = {}                                    -- Map GUID -> total interrupt fails count
local interruptFailKinds = {}                                -- Map GUID -> subcounts table per fail kind
local deathCounts = {}                                       -- Map GUID -> death tally
local nonTankHeavyHits = {}                                  -- Map GUID -> count of big hits taken while likely not a tank

local recentEnemyCasts = {}                                  -- Map enemy GUID -> last started cast data
local pendingInterrupts = {}                                 -- Array of interrupt attempts waiting for success/fail decision

local function FormatNum(n)                                  -- Number formatter compatible with Wrath client
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

local INTERRUPT_SPELLS = {}                                  -- Set of common Wrath interrupt spell IDs
INTERRUPT_SPELLS[1766]  = true                               -- Rogue Kick
INTERRUPT_SPELLS[6552]  = true                               -- Warrior Pummel
INTERRUPT_SPELLS[72]    = true                               -- Warrior Shield Bash
INTERRUPT_SPELLS[47528] = true                               -- Death Knight Mind Freeze
INTERRUPT_SPELLS[2139]  = true                               -- Mage Counterspell
INTERRUPT_SPELLS[57994] = true                               -- Shaman Wind Shear

local function ColorName(name)                               -- Return class colored name if unit is known
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

local function IsInMyGroup(guid)                             -- True if GUID is one of our party/raid members
    if not guid then return false end
    return groupGUIDs[guid] and true or false
end

local function RememberUnitToken(guid, unit)                 -- Cache a unit token for later HP/class queries
    if guid and unit and UnitExists(unit) then
        guidToUnit[guid] = unit
    end
end

local function RebuildGroup()                                -- Rebuild GUID/name/unit maps
    for k in pairs(groupGUIDs) do groupGUIDs[k] = nil end
    for k in pairs(guidToName) do guidToName[k] = nil end
    for k in pairs(guidToUnit) do guidToUnit[k] = nil end

    if GetNumRaidMembers() > 0 then
        for i = 1, GetNumRaidMembers() do
            local u = "raid"..i
            if UnitExists(u) and not UnitIsUnit(u, "pet") then
                local g = UnitGUID(u)
                local n = UnitName(u)
                if g and n then
                    groupGUIDs[g] = true
                    guidToName[g] = n
                    RememberUnitToken(g, u)
                end
            end
        end
        return
    end

    local pg = UnitGUID("player")
    local pn = UnitName("player")
    if pg and pn then
        groupGUIDs[pg] = true
        guidToName[pg] = pn
        RememberUnitToken(pg, "player")
    end

    for i = 1, GetNumPartyMembers() do
        local u = "party"..i
        if UnitExists(u) then
            local g = UnitGUID(u)
            local n = UnitName(u)
            if g and n then
                groupGUIDs[g] = true
                guidToName[g] = n
                RememberUnitToken(g, u)
            end
        end
    end
end

local function ResetRecords()                                -- Clear all state for a fresh run
    records.topDamage.amount, records.topDamage.spell, records.topDamage.player, records.topDamage.crit = 0, "None", "None", false
    records.topHeal.amount,   records.topHeal.spell,   records.topHeal.player,   records.topHeal.crit   = 0, "None", "None", false
    records.topCrit.amount,   records.topCrit.spell,   records.topCrit.player,   records.topCrit.crit,  records.topCrit.kind = 0, "None", "None", false, "None"

    records.failOverkill.amount,    records.failOverkill.spell,    records.failOverkill.player,    records.failOverkill.by   = 0, "None", "None", "None"
    records.failOverheal.amount,    records.failOverheal.spell,    records.failOverheal.player     = 0, "None", "None"
    records.failDamageTaken.amount, records.failDamageTaken.spell, records.failDamageTaken.player, records.failDamageTaken.by = 0, "None", "None", "None"

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

_G["ZaesEpicMoments_Reset"] = ResetRecords                   -- Expose reset for XML button

local function EpicScore(amount, isCrit, kind)               -- Score positive epic events
    local score = amount or 0
    if isCrit then score = score * 1.05 end
    if kind == "DMG" then score = score * 1.02 end
    return score
end

local function FailScore(kind, amount)                       -- Score fail events for per-player "best fail"
    local a = amount or 0
    if kind == "OVERKILL" then return a * 1.02 end
    if kind == "OVERHEAL" then return a * 1.01 end
    if kind == "TAKEN"    then return a * 1.03 end
    if kind == "INT"      then return a * 1.04 end
    if kind == "DEATHS"   then return a * 1.05 end
    if kind == "NON_TANK" then return a * 1.02 end
    return a
end

local function ExtractDamageArgs(subevent, ...)              -- Normalize SWING/RANGE/SPELL damage payloads
    local ts, _, _, sGUID, sName, _, _, dGUID, dName, _, _, p12, p13, p14, p15, p16, p17, p18, p19, p20, p21 = ...
    local amount, overkill, critical, spellName = 0, 0, false, "Melee"
    if subevent == "SWING_DAMAGE" then
        amount   = p12 or 0
        overkill = p13 or 0
        critical = p21 or false
        spellName = "Melee"
        return sGUID, sName, dGUID, dName, amount, overkill, critical, spellName
    end
    if subevent == "SPELL_DAMAGE" or subevent == "RANGE_DAMAGE" then
        spellName = p13 or "Unknown"
        amount    = p15 or 0
        overkill  = p16 or 0
        critical  = p21 or false
        return sGUID, sName, dGUID, dName, amount, overkill, critical, spellName
    end
    return sGUID, sName, dGUID, dName, 0, 0, false, "Unknown"
end

local function ExtractHealArgs(...)                          -- Normalize heal payloads
    local ts, subevent, _, sGUID, sName, _, _, dGUID, dName, _, _, spellId, spellName, school, amount, overheal, absorbed, crit = ...
    local effective = (amount or 0) - (overheal or 0)
    if effective < 0 then effective = 0 end
    return subevent, sGUID, sName, dGUID, dName, effective, (overheal or 0), (crit or false), (spellName or "Unknown")
end

local function ConsiderDamage(sGUID, sName, amount, crit, spell) -- Feed positive damage records
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

local function ConsiderHeal(sGUID, sName, effective, crit, spell) -- Feed positive heal records
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

local function ConsiderFailOverkill(sGUID, sName, dGUID, dName, overkill, spell) -- Overkill belongs to victim
    if overkill <= 0 then return end
    if not IsInMyGroup(dGUID) then return end
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

local function ConsiderFailOverheal(sGUID, sName, overheal, spell) -- Overheal belongs to healer
    if overheal <= 0 then return end
    if not IsInMyGroup(sGUID) then return end
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

local function ConsiderFailDamageTaken(sGUID, sName, dGUID, dName, amount, spell) -- Big hit taken belongs to victim
    if amount <= 0 then return end
    if not IsInMyGroup(dGUID) then return end
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

local function IsLikelyTank(guid)                            -- Heuristic tank check
    if not guid or not guidToName[guid] then return false end
    local u = guidToUnit[guid]
    if u and UnitExists(u) then
        local _, class = UnitClass(u)
        if class == "WARRIOR" or class == "PALADIN" or class == "DEATHKNIGHT" then
            return true
        end
        if class == "DRUID" then
            local bearName = GetSpellInfo(9634)
            if bearName and UnitAura(u, bearName) then
                return true
            end
        end
    end
    return false
end

local function IsHeavyHitFor(guid, amount)                   -- Decide if hit qualifies as heavy
    if amount <= 0 then return false end
    local u = guidToUnit[guid]
    if u and UnitExists(u) then
        local hpmax = UnitHealthMax(u) or 0
        if hpmax > 0 then
            return amount >= hpmax * 0.25
        end
    end
    return amount >= 2000
end

local function BumpNonTankHeavyHit(dGUID, amount)            -- Increment non-tank heavy hit count if conditions pass
    if not dGUID then return end
    if IsLikelyTank(dGUID) then return end
    if not IsHeavyHitFor(dGUID, amount) then return end
    nonTankHeavyHits[dGUID] = (nonTankHeavyHits[dGUID] or 0) + 1
end

local function NoteDeath(dGUID)                              -- Increment death tally for a group member
    if not dGUID or not IsInMyGroup(dGUID) then return end
    deathCounts[dGUID] = (deathCounts[dGUID] or 0) + 1
end

local function NoteInterruptFail(sGUID, kind)                -- Increase interrupt fail counters
    if not sGUID or not IsInMyGroup(sGUID) then return end
    interruptFails[sGUID] = (interruptFails[sGUID] or 0) + 1
    interruptFailKinds[sGUID] = interruptFailKinds[sGUID] or {}
    interruptFailKinds[sGUID][kind] = (interruptFailKinds[sGUID][kind] or 0) + 1
end

local function FormatEpic(rec)                               -- Build a readable epic line
    if not rec then return "" end
    local critText = rec.crit and " (crit)" or ""
    local kindText = rec.kind == "Heal" and "Heal" or "Damage"
    return string.format("%s  —  %s: %s for %s%s",
        ColorName(rec.player or "Unknown"),
        kindText,
        rec.spell or "Unknown",
        FormatNum(rec.amount or 0),
        critText
    )
end

local function FormatFail(rec)                               -- Build a readable fail line
    if not rec then return "" end
    if rec.kind == "Overkill" then
        return string.format("%s  —  Overkill by %s: %s for %s",
            ColorName(rec.player or "Unknown"),
            rec.by or "Unknown",
            rec.spell or "Unknown",
            FormatNum(rec.amount or 0)
        )
    elseif rec.kind == "Overheal" then
        return string.format("%s  —  Overheal: %s by %s",
            ColorName(rec.player or "Unknown"),
            rec.spell or "Unknown",
            FormatNum(rec.amount or 0)
        )
    else
        return string.format("%s  —  Took: %s from %s for %s",
            ColorName(rec.player or "Unknown"),
            rec.spell or "Melee",
            rec.by or "Unknown",
            FormatNum(rec.amount or 0)
        )
    end
end

local function TopOffenderCount(tbl)                         -- Return guid,count pair for the highest value in a map
    local bestGuid, bestCount = nil, 0
    for g, n in pairs(tbl) do
        if n > bestCount then bestGuid, bestCount = g, n end
    end
    return bestGuid, bestCount
end

function EM.UpdateUI()                                       -- Refresh the addon frame
    local frame = _G["ZaesEpicMomentsFrame"]
    if not frame then return end

    local dmg = string.format("Biggest Hit: %s - %s for %s%s",
        ColorName(records.topDamage.player),
        records.topDamage.spell,
        FormatNum(records.topDamage.amount),
        records.topDamage.crit and " (crit)" or ""
    )
    local heal = string.format("Biggest Heal: %s - %s for %s%s",
        ColorName(records.topHeal.player),
        records.topHeal.spell,
        FormatNum(records.topHeal.amount),
        records.topHeal.crit and " (crit)" or ""
    )
    local crit = string.format("Biggest Crit: %s - %s for %s [%s]",
        ColorName(records.topCrit.player),
        records.topCrit.spell,
        FormatNum(records.topCrit.amount),
        records.topCrit.kind
    )

    local summary = _G["ZaesEpicMomentsFrameSummary"]
    if summary then summary:SetText(dmg .. "\n" .. heal .. "\n" .. crit) end

    local topIntGUID, topIntCount = TopOffenderCount(interruptFails)
    local topIntName = topIntGUID and ColorName(guidToName[topIntGUID] or "None") or "None"
    local topDeathsGUID, topDeaths = TopOffenderCount(deathCounts)
    local topDeathsName = topDeathsGUID and ColorName(guidToName[topDeathsGUID] or "None") or "None"
    local topNonTankGUID, topNonTank = TopOffenderCount(nonTankHeavyHits)
    local topNonTankName = topNonTankGUID and ColorName(guidToName[topNonTankGUID] or "None") or "None"

    local failsText = string.format(
        "Overkill: %s by %s with %s for %s\nOverheal: %s - %s for %s\nChunked: %s took %s from %s for %s\nInt Whiffs: %s (%d)\nDeaths (max): %s (%d)\nNon-Tank Hits (max): %s (%d)",
        ColorName(records.failOverkill.player),
        ColorName(records.failOverkill.by),
        records.failOverkill.spell,
        FormatNum(records.failOverkill.amount),
        ColorName(records.failOverheal.player),
        records.failOverheal.spell,
        FormatNum(records.failOverheal.amount),
        ColorName(records.failDamageTaken.player),
        records.failDamageTaken.spell,
        ColorName(records.failDamageTaken.by),
        FormatNum(records.failDamageTaken.amount),
        topIntName, topIntCount or 0,
        topDeathsName, topDeaths or 0,
        topNonTankName, topNonTank or 0
    )

    local failsHeader = _G["ZaesEpicMomentsFrameFailsHeader"]
    if failsHeader then failsHeader:SetText("Epic Fails") end

    local failsSummary = _G["ZaesEpicMomentsFrameFailsSummary"]
    if failsSummary then failsSummary:SetText(failsText) end

    local linesWidget = _G["ZaesEpicMomentsLines"]
    if not linesWidget then return end

    local epicList = {}
    for _, rec in pairs(perPlayerBest) do table.insert(epicList, rec) end
    table.sort(epicList, function(a, b)
        if a.player == b.player then return (a.amount or 0) > (b.amount or 0) end
        return (a.player or "") < (b.player or "")
    end)

    local failList = {}
    for _, rec in pairs(perPlayerFailBest) do table.insert(failList, rec) end
    table.sort(failList, function(a, b)
        if a.player == b.player then return (a.amount or 0) > (b.amount or 0) end
        return (a.player or "") < (b.player or "")
    end)

    local out = {}
    table.insert(out, "|cffffff00Per-Player Best:|r")
    for i = 1, #epicList do table.insert(out, "  " .. FormatEpic(epicList[i])) end
    table.insert(out, "")
    table.insert(out, "|cffff6060Per-Player Epic Fails:|r")
    for i = 1, #failList do table.insert(out, "  " .. FormatFail(failList[i])) end

    if topDeaths and topDeaths >= 3 then
        table.insert(out, "")
        table.insert(out, "|cffff4040Death Watch (3+):|r")
        for g, n in pairs(deathCounts) do
            if n >= 3 then
                table.insert(out, string.format("  %s — %d deaths", ColorName(guidToName[g] or "Unknown"), n))
            end
        end
    end

    linesWidget:SetText(table.concat(out, "\n"))
end

local function TrackEnemyCastStart(dstGUID, spellName)       -- Remember an enemy started casting
    if not dstGUID then return end
    recentEnemyCasts[dstGUID] = recentEnemyCasts[dstGUID] or {}
    recentEnemyCasts[dstGUID].name = spellName or "Unknown"
    recentEnemyCasts[dstGUID].t = GetTime()
end

local function EnemyWasCastingRecently(dstGUID, window)       -- True if the enemy began a cast within window seconds
    local info = recentEnemyCasts[dstGUID]
    if not info then return false end
    local w = window or 2.0
    return (GetTime() - (info.t or 0)) <= w
end

local function AddPendingInterrupt(sGUID, sName, dGUID, dName, spellId, spellName) -- Queue an interrupt attempt
    local deadline = GetTime() + 0.8
    table.insert(pendingInterrupts, {
        sGUID = sGUID,
        sName = sName,
        dGUID = dGUID,
        dName = dName,
        spellId = spellId,
        spellName = spellName,
        deadline = deadline,
    })
end

local function ClearPendingForSource(sGUID)                  -- Remove pending attempts for a given source GUID
    if not sGUID then return end
    for i = #pendingInterrupts, 1, -1 do
        if pendingInterrupts[i].sGUID == sGUID then
            table.remove(pendingInterrupts, i)
        end
    end
end

local function PendingTick()                                 -- Convert expired pendings into whiffs or late interrupts
    local now = GetTime()
    for i = #pendingInterrupts, 1, -1 do
        local p = pendingInterrupts[i]
        if now >= p.deadline then
            if EnemyWasCastingRecently(p.dGUID, 2.0) then
                NoteInterruptFail(p.sGUID, "late")
                local name = guidToName[p.sGUID] or "Unknown"
                DEFAULT_CHAT_FRAME:AddMessage(string.format("|cffff6060ZaesEpicMoments: late interrupt by %s (%s)|r", name, p.spellName or "Interrupt"))
                local score = FailScore("INT", 1)
                local rec = perPlayerFailBest[p.sGUID]
                if not rec or score > rec.score then
                    perPlayerFailBest[p.sGUID] = { score = score, amount = 1, spell = p.spellName or "Interrupt", player = name, kind = "Interrupt Late" }
                end
            else
                NoteInterruptFail(p.sGUID, "nothing")
                local name = guidToName[p.sGUID] or "Unknown"
                DEFAULT_CHAT_FRAME:AddMessage(string.format("|cffff6060ZaesEpicMoments: interrupt on nothing by %s (%s)|r", name, p.spellName or "Interrupt"))
                local score = FailScore("INT", 1)
                local rec = perPlayerFailBest[p.sGUID]
                if not rec or score > rec.score then
                    perPlayerFailBest[p.sGUID] = { score = score, amount = 1, spell = p.spellName or "Interrupt", player = name, kind = "Interrupt Whiff" }
                end
            end
            table.remove(pendingInterrupts, i)
            EM.UpdateUI()
        end
    end
end

local tickerElapsed = 0                                      -- Accumulator for a simple OnUpdate ticker
local tickerFrame = CreateFrame("Frame")                      -- Small frame to drive PendingTick
tickerFrame:SetScript("OnUpdate", function(self, elapsed)
    tickerElapsed = tickerElapsed + (elapsed or 0)
    if tickerElapsed >= 0.25 then
        PendingTick()
        tickerElapsed = 0
    end
end)

local function OnCombatLogEvent()                            -- Main combat log parser
    local ts, subevent, hideCaster,
          sGUID, sName, sFlags, sRaidFlags,
          dGUID, dName, dFlags, dRaidFlags,
          spellId, spellName = CombatLogGetCurrentEventInfo()

    if subevent == "SPELL_CAST_START" then                   -- Enemy started casting
        if not IsInMyGroup(sGUID) then
            TrackEnemyCastStart(sGUID, spellName)
        end
        return
    end

    if subevent == "SPELL_INTERRUPT" then                    -- Successful interrupt
        if IsInMyGroup(sGUID) then
            ClearPendingForSource(sGUID)
        end
        return
    end

    if subevent == "SPELL_MISSED" then                       -- Interrupt was resisted or missed
        local missSpellId = spellId
        local missType = select(12, CombatLogGetCurrentEventInfo())
        if IsInMyGroup(sGUID) and INTERRUPT_SPELLS[missSpellId] then
            NoteInterruptFail(sGUID, "resisted")
            local name = guidToName[sGUID] or "Unknown"
            local sLabel = GetSpellInfo(missSpellId) or "Interrupt"
            DEFAULT_CHAT_FRAME:AddMessage(string.format("|cffff6060ZaesEpicMoments: interrupt resisted by %s (%s)|r", name, sLabel))
            local score = FailScore("INT", 1)
            local rec = perPlayerFailBest[sGUID]
            if not rec or score > rec.score then
                perPlayerFailBest[sGUID] = { score = score, amount = 1, spell = sLabel, player = name, kind = "Interrupt Resisted" }
            end
            ClearPendingForSource(sGUID)
            EM.UpdateUI()
        end
        return
    end

    if subevent == "SPELL_CAST_SUCCESS" then                 -- Interrupt attempt fired
        if IsInMyGroup(sGUID) and INTERRUPT_SPELLS[spellId] then
            AddPendingInterrupt(sGUID, sName, dGUID, dName, spellId, spellName)
        end
        return
    end

    if subevent == "SWING_DAMAGE" or subevent == "RANGE_DAMAGE" or subevent == "SPELL_DAMAGE" then
        local aGUID, aName, vGUID, vName, amount, overkill, crit, dmgSpell = ExtractDamageArgs(subevent, CombatLogGetCurrentEventInfo())
        if amount and amount > 0 then
            ConsiderDamage(aGUID, aName, amount, crit, dmgSpell)
            ConsiderFailDamageTaken(aGUID, aName, vGUID, vName, amount, dmgSpell)
            if overkill and overkill > 0 then
                ConsiderFailOverkill(aGUID, aName, vGUID, vName, overkill, dmgSpell)
            end
            BumpNonTankHeavyHit(vGUID, amount)
            EM.UpdateUI()
        end
        return
    end

    if subevent == "SPELL_HEAL" or subevent == "SPELL_PERIODIC_HEAL" then
        local _, aGUID, aName, vGUID, vName, effective, overheal, crit, healSpell = ExtractHealArgs(CombatLogGetCurrentEventInfo())
        if effective and effective > 0 then
            ConsiderHeal(aGUID, aName, effective, crit, healSpell)
        end
        if overheal and overheal > 0 then
            ConsiderFailOverheal(aGUID, aName, overheal, healSpell)
        end
        EM.UpdateUI()
        return
    end

    if subevent == "UNIT_DIED" or subevent == "UNIT_DESTROYED" then
        if IsInMyGroup(dGUID) then
            NoteDeath(dGUID)
            if (deathCounts[dGUID] or 0) >= 3 then
                local n = guidToName[dGUID] or "Unknown"
                DEFAULT_CHAT_FRAME:AddMessage(string.format("|cffff4040ZaesEpicMoments: %s has died %d times this run.|r", n, deathCounts[dGUID]))
            end
            EM.UpdateUI()
        end
        return
    end
end

local function OnGroupChanged()                               -- Rebuild caches on roster change
    RebuildGroup()
    EM.UpdateUI()
end

local function OnZoneChanged()                                -- Reset on new instance or zone
    ResetRecords()
end

f:RegisterEvent("PLAYER_ENTERING_WORLD")                      -- Load/reset on login or reload
f:RegisterEvent("RAID_ROSTER_UPDATE")                         -- Raid roster updates
f:RegisterEvent("PARTY_MEMBERS_CHANGED")                      -- Party roster updates
f:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")                -- Combat log stream
f:RegisterEvent("ZONE_CHANGED_NEW_AREA")                      -- Instance/zone change

f:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_ENTERING_WORLD" then
        RebuildGroup()
        ResetRecords()
        if ZaesEpicMomentsFrame then ZaesEpicMomentsFrame:Show() end
        return
    end
    if event == "RAID_ROSTER_UPDATE" or event == "PARTY_MEMBERS_CHANGED" then
        OnGroupChanged()
        return
    end
    if event == "ZONE_CHANGED_NEW_AREA" then
        OnZoneChanged()
        return
    end
    if event == "COMBAT_LOG_EVENT_UNFILTERED" then
        OnCombatLogEvent()
        return
    end
end)

SLASH_ZAESEPICMOMENTS1 = "/zem"                               -- Short slash alias
SLASH_ZAESEPICMOMENTS2 = "/zaesepicmoments"                   -- Long slash alias
SlashCmdList["ZAESEPICMOMENTS"] = function(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cffffff00=== Zaes Epic Moments — This Run ===|r")
    DEFAULT_CHAT_FRAME:AddMessage(string.format("Biggest Hit: %s - %s for %s%s",
        records.topDamage.player, records.topDamage.spell, FormatNum(records.topDamage.amount), records.topDamage.crit and " (crit)" or ""))
    DEFAULT_CHAT_FRAME:AddMessage(string.format("Biggest Heal: %s - %s for %s%s",
        records.topHeal.player, records.topHeal.spell, FormatNum(records.topHeal.amount), records.topHeal.crit and " (crit)" or ""))
    DEFAULT_CHAT_FRAME:AddMessage(string.format("Biggest Crit: %s - %s for %s [%s]",
        records.topCrit.player, records.topCrit.spell, FormatNum(records.topCrit.amount), records.topCrit.kind))

    DEFAULT_CHAT_FRAME:AddMessage("|cffff6060=== Epic Fails ===|r")
    DEFAULT_CHAT_FRAME:AddMessage(string.format("Overkill: %s by %s with %s for %s",
        records.failOverkill.player, records.failOverkill.by, records.failOverkill.spell, FormatNum(records.failOverkill.amount)))
    DEFAULT_CHAT_FRAME:AddMessage(string.format("Overheal: %s - %s for %s",
        records.failOverheal.player, records.failOverheal.spell, FormatNum(records.failOverheal.amount)))
    DEFAULT_CHAT_FRAME:AddMessage(string.format("Chunked: %s took %s from %s for %s",
        records.failDamageTaken.player, records.failDamageTaken.spell, records.failDamageTaken.by, FormatNum(records.failDamageTaken.amount)))

    local topIntGUID, topIntCount = TopOffenderCount(interruptFails)
    if topIntGUID then
        local kinds = interruptFailKinds[topIntGUID] or {}
        DEFAULT_CHAT_FRAME:AddMessage(string.format("Interrupt whiffs: %s (%d) [late=%d, nothing=%d, resisted=%d]",
            guidToName[topIntGUID] or "Unknown", topIntCount or 0, kinds["late"] or 0, kinds["nothing"] or 0, kinds["resisted"] or 0))
    end

    local printedDeaths = false
    for g, n in pairs(deathCounts) do
        if n >= 3 then
            if not printedDeaths then
                DEFAULT_CHAT_FRAME:AddMessage("Death Watch (3+):")
                printedDeaths = true
            end
            DEFAULT_CHAT_FRAME:AddMessage(string.format(" - %s: %d", guidToName[g] or "Unknown", n))
        end
    end

    local topNonTankGUID, topNonTank = TopOffenderCount(nonTankHeavyHits)
    if topNonTankGUID then
        DEFAULT_CHAT_FRAME:AddMessage(string.format("Non-tank heavy hits: %s (%d)", guidToName[topNonTankGUID] or "Unknown", topNonTank or 0))
    end

    for _, rec in pairs(perPlayerBest) do
        DEFAULT_CHAT_FRAME:AddMessage(" - " .. FormatEpic(rec))
    end
    for _, rec in pairs(perPlayerFailBest) do
        DEFAULT_CHAT_FRAME:AddMessage(" - " .. FormatFail(rec))
    end
end
