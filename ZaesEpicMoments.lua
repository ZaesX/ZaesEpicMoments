-- ZaesEpicMoments.lua
-- Author: ChatGPT feat. Zaes
-- Version: 0.3.2
-- QoL: hide frame until grouped or in an instance; tiny ScrollFrame fix handled in XML; rest unchanged feature-wise
-- WotLK 3.3.5a, Project Epoch

local EM = {}

local f = CreateFrame("Frame")

local groupGUIDs, guidToName, guidToUnit = {}, {}, {}

local perPlayerBest, perPlayerFailBest = {}, {}

local records = {}
records.topDamage       = { amount = 0, spell = "None", player = "None", crit = false }
records.topHeal         = { amount = 0, spell = "None", player = "None", crit = false }
records.topCrit         = { amount = 0, spell = "None", player = "None", crit = false, kind = "None" }
records.failOverkill    = { amount = 0, spell = "None", player = "None", by = "None" }
records.failOverheal    = { amount = 0, spell = "None", player = "None" }
records.failDamageTaken = { amount = 0, spell = "None", player = "None", by = "None" }

local interruptFails, interruptFailKinds = {}, {}
local deathCounts, nonTankHeavyHits = {}, {}

local recentEnemyCasts = {}
local pendingInterrupts = {}

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

local INTERRUPT_SPELLS = { [1766]=true, [6552]=true, [72]=true, [47528]=true, [2139]=true, [57994]=true }

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

local function IsInMyGroup(guid) return guid and groupGUIDs[guid] and true or false end

local function RememberUnitToken(guid, unit) if guid and unit and UnitExists(unit) then guidToUnit[guid] = unit end end

local function RebuildGroup()
    for k in pairs(groupGUIDs) do groupGUIDs[k]=nil end
    for k in pairs(guidToName) do guidToName[k]=nil end
    for k in pairs(guidToUnit) do guidToUnit[k]=nil end

    if GetNumRaidMembers() > 0 then
        for i=1, GetNumRaidMembers() do
            local u = "raid"..i
            if UnitExists(u) and not UnitIsUnit(u, "pet") then
                local g, n = UnitGUID(u), UnitName(u)
                if g and n then groupGUIDs[g]=true; guidToName[g]=n; RememberUnitToken(g,u) end
            end
        end
        return
    end
    local pg, pn = UnitGUID("player"), UnitName("player")
    if pg and pn then groupGUIDs[pg]=true; guidToName[pg]=pn; RememberUnitToken(pg,"player") end
    for i=1, GetNumPartyMembers() do
        local u = "party"..i
        if UnitExists(u) then
            local g, n = UnitGUID(u), UnitName(u)
            if g and n then groupGUIDs[g]=true; guidToName[g]=n; RememberUnitToken(g,u) end
        end
    end
end

local function HasAnyData()
    if records.topDamage.amount > 0 or records.topHeal.amount > 0 or records.topCrit.amount > 0 then return true end
    if records.failOverkill.amount > 0 or records.failOverheal.amount > 0 or records.failDamageTaken.amount > 0 then return true end
    for _ in pairs(perPlayerBest) do return true end
    for _ in pairs(perPlayerFailBest) do return true end
    return false
end

local function ShouldFrameBeVisible()
    local inInstance = IsInInstance()
    if inInstance then return true end
    if GetNumRaidMembers() > 0 or GetNumPartyMembers() > 0 then return true end
    return false
end

local function ResetRecords()
    records.topDamage.amount, records.topDamage.spell, records.topDamage.player, records.topDamage.crit = 0,"None","None",false
    records.topHeal.amount,   records.topHeal.spell,   records.topHeal.player,   records.topHeal.crit   = 0,"None","None",false
    records.topCrit.amount,   records.topCrit.spell,   records.topCrit.player,   records.topCrit.crit,  records.topCrit.kind = 0,"None","None",false,"None"
    records.failOverkill.amount, records.failOverkill.spell, records.failOverkill.player, records.failOverkill.by = 0,"None","None","None"
    records.failOverheal.amount, records.failOverheal.spell, records.failOverheal.player = 0,"None","None"
    records.failDamageTaken.amount, records.failDamageTaken.spell, records.failDamageTaken.player, records.failDamageTaken.by = 0,"None","None","None"

    for k in pairs(perPlayerBest) do perPlayerBest[k]=nil end
    for k in pairs(perPlayerFailBest) do perPlayerFailBest[k]=nil end
    for k in pairs(interruptFails) do interruptFails[k]=nil end
    for k in pairs(interruptFailKinds) do interruptFailKinds[k]=nil end
    for k in pairs(deathCounts) do deathCounts[k]=nil end
    for k in pairs(nonTankHeavyHits) do nonTankHeavyHits[k]=nil end
    for k in pairs(recentEnemyCasts) do recentEnemyCasts[k]=nil end
    for i=#pendingInterrupts,1,-1 do table.remove(pendingInterrupts,i) end

    EM.UpdateUI()
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00ZaesEpicMoments: records reset.|r")
end
_G["ZaesEpicMoments_Reset"] = ResetRecords

local function EpicScore(amount, isCrit, kind) local s=amount or 0 if isCrit then s=s*1.05 end if kind=="DMG" then s=s*1.02 end return s end
local function FailScore(kind, amount) local a=amount or 0 if kind=="OVERKILL" then return a*1.02 end if kind=="OVERHEAL" then return a*1.01 end if kind=="TAKEN" then return a*1.03 end if kind=="INT" then return a*1.04 end if kind=="DEATHS" then return a*1.05 end if kind=="NON_TANK" then return a*1.02 end return a end

local function ExtractDamageArgs(subevent, ...)
    local ts, _, _, sGUID, sName, _, _, dGUID, dName, _, _, p12, p13, p14, p15, p16, p17, p18, p19, p20, p21 = ...
    local amount, overkill, critical, spellName = 0,0,false,"Melee"
    if subevent=="SWING_DAMAGE" then amount=p12 or 0 overkill=p13 or 0 critical=p21 or false spellName="Melee" return sGUID,sName,dGUID,dName,amount,overkill,critical,spellName end
    if subevent=="SPELL_DAMAGE" or subevent=="RANGE_DAMAGE" then spellName=p13 or "Unknown" amount=p15 or 0 overkill=p16 or 0 critical=p21 or false return sGUID,sName,dGUID,dName,amount,overkill,critical,spellName end
    return sGUID,sName,dGUID,dName,0,0,false,"Unknown"
end

local function ExtractHealArgs(...)
    local ts, subevent, _, sGUID, sName, _, _, dGUID, dName, _, _, spellId, spellName, school, amount, overheal, absorbed, crit = ...
    local effective=(amount or 0)-(overheal or 0) if effective<0 then effective=0 end
    return subevent,sGUID,sName,dGUID,dName,effective,(overheal or 0),(crit or false),(spellName or "Unknown")
end

local function ConsiderDamage(sGUID,sName,amount,crit,spell)
    if not IsInMyGroup(sGUID) then return end
    if amount>records.topDamage.amount then records.topDamage.amount=amount records.topDamage.spell=spell records.topDamage.player=sName or "Unknown" records.topDamage.crit=crit and true or false end
    if crit and amount>records.topCrit.amount then records.topCrit.amount=amount records.topCrit.spell=spell records.topCrit.player=sName or "Unknown" records.topCrit.crit=true records.topCrit.kind="Damage" end
    local score=EpicScore(amount,crit,"DMG") local rec=perPlayerBest[sGUID] if not rec or score>rec.score then perPlayerBest[sGUID]={score=score,amount=amount,spell=spell,player=sName or "Unknown",crit=crit and true or false,kind="Damage"} end
end

local function ConsiderHeal(sGUID,sName,effective,crit,spell)
    if not IsInMyGroup(sGUID) then return end
    if effective>records.topHeal.amount then records.topHeal.amount=effective records.topHeal.spell=spell records.topHeal.player=sName or "Unknown" records.topHeal.crit=crit and true or false end
    if crit and effective>records.topCrit.amount then records.topCrit.amount=effective records.topCrit.spell=spell records.topCrit.player=sName or "Unknown" records.topCrit.crit=true records.topCrit.kind="Heal" end
    local score=EpicScore(effective,crit,"HEAL") local rec=perPlayerBest[sGUID] if not rec or score>rec.score then perPlayerBest[sGUID]={score=score,amount=effective,spell=spell,player=sName or "Unknown",crit=crit and true or false,kind="Heal"} end
end

local function ConsiderFailOverkill(sGUID,sName,dGUID,dName,overkill,spell)
    if overkill<=0 or not IsInMyGroup(dGUID) then return end
    local victim=dName or "Unknown" local killer=sName or "Unknown"
    if overkill>records.failOverkill.amount then records.failOverkill.amount=overkill records.failOverkill.spell=spell or "Unknown" records.failOverkill.player=victim records.failOverkill.by=killer end
    local score=FailScore("OVERKILL",overkill) local rec=perPlayerFailBest[dGUID] if not rec or score>rec.score then perPlayerFailBest[dGUID]={score=score,amount=overkill,spell=spell or "Unknown",player=victim,by=killer,kind="Overkill"} end
end

local function ConsiderFailOverheal(sGUID,sName,overheal,spell)
    if overheal<=0 or not IsInMyGroup(sGUID) then return end
    local healer=sName or "Unknown"
    if overheal>records.failOverheal.amount then records.failOverheal.amount=overheal records.failOverheal.spell=spell or "Unknown" records.failOverheal.player=healer end
    local score=FailScore("OVERHEAL",overheal) local rec=perPlayerFailBest[sGUID] if not rec or score>rec.score then perPlayerFailBest[sGUID]={score=score,amount=overheal,spell=spell or "Unknown",player=healer,kind="Overheal"} end
end

local function ConsiderFailDamageTaken(sGUID,sName,dGUID,dName,amount,spell)
    if amount<=0 or not IsInMyGroup(dGUID) then return end
    local victim=dName or "Unknown" local byname=sName or "Unknown"
    if amount>records.failDamageTaken.amount then records.failDamageTaken.amount=amount records.failDamageTaken.spell=spell or "Melee" records.failDamageTaken.player=victim records.failDamageTaken.by=byname end
    local score=FailScore("TAKEN",amount) local rec=perPlayerFailBest[dGUID] if not rec or score>rec.score then perPlayerFailBest[dGUID]={score=score,amount=amount,spell=spell or "Melee",player=victim,by=byname,kind="Damage Taken"} end
end

local function IsLikelyTank(guid)
    if not guid or not guidToName[guid] then return false end
    local u=guidToUnit[guid]
    if u and UnitExists(u) then
        local _,class=UnitClass(u)
        if class=="WARRIOR" or class=="PALADIN" or class=="DEATHKNIGHT" then return true end
        if class=="DRUID" then local bear=GetSpellInfo(9634) if bear and UnitAura(u,bear) then return true end end
    end
    return false
end

local function IsHeavyHitFor(guid,amount)
    if amount<=0 then return false end
    local u=guidToUnit[guid]
    if u and UnitExists(u) then local mx=UnitHealthMax(u) or 0 if mx>0 then return amount>=mx*0.25 end end
    return amount>=2000
end

local function BumpNonTankHeavyHit(dGUID,amount)
    if not dGUID or IsLikelyTank(dGUID) or not IsHeavyHitFor(dGUID,amount) then return end
    nonTankHeavyHits[dGUID]=(nonTankHeavyHits[dGUID] or 0) + 1
end

local function NoteDeath(dGUID) if dGUID and IsInMyGroup(dGUID) then deathCounts[dGUID]=(deathCounts[dGUID] or 0)+1 end end

local function NoteInterruptFail(sGUID,kind)
    if not sGUID or not IsInMyGroup(sGUID) then return end
    interruptFails[sGUID]=(interruptFails[sGUID] or 0)+1
    interruptFailKinds[sGUID]=interruptFailKinds[sGUID] or {}
    interruptFailKinds[sGUID][kind]=(interruptFailKinds[sGUID][kind] or 0)+1
end

local function FormatEpic(rec)
    if not rec then return "" end
    local critText=rec.crit and " (crit)" or ""
    local kindText=rec.kind=="Heal" and "Heal" or "Damage"
    return string.format("%s  —  %s: %s for %s%s", ColorName(rec.player or "Unknown"), kindText, rec.spell or "Unknown", FormatNum(rec.amount or 0), critText)
end

local function FormatFail(rec)
    if not rec then return "" end
    if rec.kind=="Overkill" then
        return string.format("%s  —  Overkill by %s: %s for %s", ColorName(rec.player or "Unknown"), rec.by or "Unknown", rec.spell or "Unknown", FormatNum(rec.amount or 0))
    elseif rec.kind=="Overheal" then
        return string.format("%s  —  Overheal: %s by %s", ColorName(rec.player or "Unknown"), rec.spell or "Unknown", FormatNum(rec.amount or 0))
    else
        return string.format("%s  —  Took: %s from %s for %s", ColorName(rec.player or "Unknown"), rec.spell or "Melee", rec.by or "Unknown", FormatNum(rec.amount or 0))
    end
end

local function TopOffenderCount(tbl) local bestGuid,bestCount=nil,0 for g,n in pairs(tbl) do if n>bestCount then bestGuid,bestCount=g,n end end return bestGuid,bestCount end

function EM.UpdateUI()
    local frame=_G["ZaesEpicMomentsFrame"] if not frame then return end

    if not HasAnyData() then
        _G["ZaesEpicMomentsFrameSummary"]:SetText("Biggest Hit: None - None for 0\nBiggest Heal: None - None for 0\nBiggest Crit: None - None for 0 [None]")
        _G["ZaesEpicMomentsFrameFailsHeader"]:SetText("Epic Fails")
        _G["ZaesEpicMomentsFrameFailsSummary"]:SetText("Overkill: None by None with None for 0\nOverheal: None - None for 0\nChunked: None took None from None for 0\nInt Whiffs: None (0)\nDeaths (max): None (0)\nNon-Tank Hits (max): None (0)")
    end

    local dmg=string.format("Biggest Hit: %s - %s for %s%s", ColorName(records.topDamage.player), records.topDamage.spell, FormatNum(records.topDamage.amount), records.topDamage.crit and " (crit)" or "")
    local heal=string.format("Biggest Heal: %s - %s for %s%s", ColorName(records.topHeal.player), records.topHeal.spell, FormatNum(records.topHeal.amount), records.topHeal.crit and " (crit)" or "")
    local crit=string.format("Biggest Crit: %s - %s for %s [%s]", ColorName(records.topCrit.player), records.topCrit.spell, FormatNum(records.topCrit.amount), records.topCrit.kind)

    local summary=_G["ZaesEpicMomentsFrameSummary"]; if summary then summary:SetText(dmg.."\n"..heal.."\n"..crit) end

    local topIntGUID,topIntCount=TopOffenderCount(interruptFails)
    local topIntName = topIntGUID and ColorName(guidToName[topIntGUID] or "None") or "None"
    local topDeathsGUID,topDeaths=TopOffenderCount(deathCounts)
    local topDeathsName = topDeathsGUID and ColorName(guidToName[topDeathsGUID] or "None") or "None"
    local topNonTankGUID,topNonTank=TopOffenderCount(nonTankHeavyHits)
    local topNonTankName = topNonTankGUID and ColorName(guidToName[topNonTankGUID] or "None") or "None"

    local failsText=string.format("Overkill: %s by %s with %s for %s\nOverheal: %s - %s for %s\nChunked: %s took %s from %s for %s\nInt Whiffs: %s (%d)\nDeaths (max): %s (%d)\nNon-Tank Hits (max): %s (%d)",
        ColorName(records.failOverkill.player), ColorName(records.failOverkill.by), records.failOverkill.spell, FormatNum(records.failOverkill.amount),
        ColorName(records.failOverheal.player), records.failOverheal.spell, FormatNum(records.failOverheal.amount),
        ColorName(records.failDamageTaken.player), records.failDamageTaken.spell, ColorName(records.failDamageTaken.by), FormatNum(records.failDamageTaken.amount),
        topIntName, topIntCount or 0, topDeathsName, topDeaths or 0, topNonTankName, topNonTank or 0)

    _G["ZaesEpicMomentsFrameFailsHeader"]:SetText("Epic Fails")
    _G["ZaesEpicMomentsFrameFailsSummary"]:SetText(failsText)

    local linesWidget=_G["ZaesEpicMomentsLines"] if not linesWidget then return end

    local epicList={} for _,rec in pairs(perPlayerBest) do table.insert(epicList,rec) end
    table.sort(epicList,function(a,b) if a.player==b.player then return (a.amount or 0)>(b.amount or 0) end return (a.player or "")<(b.player or "") end)

    local failList={} for _,rec in pairs(perPlayerFailBest) do table.insert(failList,rec) end
    table.sort(failList,function(a,b) if a.player==b.player then return (a.amount or 0)>(b.amount or 0) end return (a.player or "")<(b.player or "") end)

    local out={}
    table.insert(out,"|cffffff00Per-Player Best:|r")
    for i=1,#epicList do table.insert(out,"  "..FormatEpic(epicList[i])) end
    table.insert(out,"")
    table.insert(out,"|cffff6060Per-Player Epic Fails:|r")
    for i=1,#failList do table.insert(out,"  "..FormatFail(failList[i])) end

    if (topDeaths or 0) >= 3 then
        table.insert(out,"")
        table.insert(out,"|cffff4040Death Watch (3+):|r")
        for g,n in pairs(deathCounts) do if n>=3 then table.insert(out,string.format("  %s — %d deaths", ColorName(guidToName[g] or "Unknown"), n)) end end
    end

    linesWidget:SetText(table.concat(out,"\n"))
end

local function TrackEnemyCastStart(dstGUID, spellName) if not dstGUID then return end recentEnemyCasts[dstGUID]=recentEnemyCasts[dstGUID] or {} recentEnemyCasts[dstGUID].name=spellName or "Unknown" recentEnemyCasts[dstGUID].t=GetTime() end
local function EnemyWasCastingRecently(dstGUID, window) local info=recentEnemyCasts[dstGUID] if not info then return false end local w=window or 2.0 return (GetTime()-(info.t or 0))<=w end
local function AddPendingInterrupt(sGUID,sName,dGUID,dName,spellId,spellName) local deadline=GetTime()+0.8 table.insert(pendingInterrupts,{sGUID=sGUID,sName=sName,dGUID=dGUID,dName=dName,spellId=spellId,spellName=spellName,deadline=deadline}) end
local function ClearPendingForSource(sGUID) if not sGUID then return end for i=#pendingInterrupts,1,-1 do if pendingInterrupts[i].sGUID==sGUID then table.remove(pendingInterrupts,i) end end end
local function PendingTick() local now=GetTime() for i=#pendingInterrupts,1,-1 do local p=pendingInterrupts[i] if now>=p.deadline then if EnemyWasCastingRecently(p.dGUID,2.0) then NoteInterruptFail(p.sGUID,"late") local name=guidToName[p.sGUID] or "Unknown" DEFAULT_CHAT_FRAME:AddMessage(string.format("|cffff6060ZaesEpicMoments: late interrupt by %s (%s)|r",name,p.spellName or "Interrupt")) local score=FailScore("INT",1) local rec=perPlayerFailBest[p.sGUID] if not rec or score>rec.score then perPlayerFailBest[p.sGUID]={score=score,amount=1,spell=p.spellName or "Interrupt",player=name,kind="Interrupt Late"} end else NoteInterruptFail(p.sGUID,"nothing") local name=guidToName[p.sGUID] or "Unknown" DEFAULT_CHAT_FRAME:AddMessage(string.format("|cffff6060ZaesEpicMoments: interrupt on nothing by %s (%s)|r",name,p.spellName or "Interrupt")) local score=FailScore("INT",1) local rec=perPlayerFailBest[p.sGUID] if not rec or score>rec.score then perPlayerFailBest[p.sGUID]={score=score,amount=1,spell=p.spellName or "Interrupt",player=name,kind="Interrupt Whiff"} end end table.remove(pendingInterrupts,i) EM.UpdateUI() end end end

local tickerElapsed=0
local tickerFrame=CreateFrame("Frame")
tickerFrame:SetScript("OnUpdate", function(self, elapsed) tickerElapsed=tickerElapsed+(elapsed or 0) if tickerElapsed>=0.25 then PendingTick() tickerElapsed=0 end end)

local function OnCombatLogEvent()
    local ts, subevent, hideCaster, sGUID, sName, sFlags, sRaidFlags, dGUID, dName, dFlags, dRaidFlags, spellId, spellName = CombatLogGetCurrentEventInfo()

    if subevent=="SPELL_CAST_START" then if not IsInMyGroup(sGUID) then TrackEnemyCastStart(sGUID,spellName) end return end
    if subevent=="SPELL_INTERRUPT" then if IsInMyGroup(sGUID) then ClearPendingForSource(sGUID) end return end
    if subevent=="SPELL_MISSED" then local missSpellId=spellId if IsInMyGroup(sGUID) and INTERRUPT_SPELLS[missSpellId] then NoteInterruptFail(sGUID,"resisted") local name=guidToName[sGUID] or "Unknown" local sLabel=GetSpellInfo(missSpellId) or "Interrupt" DEFAULT_CHAT_FRAME:AddMessage(string.format("|cffff6060ZaesEpicMoments: interrupt resisted by %s (%s)|r",name,sLabel)) local score=FailScore("INT",1) local rec=perPlayerFailBest[sGUID] if not rec or score>rec.score then perPlayerFailBest[sGUID]={score=score,amount=1,spell=sLabel,player=name,kind="Interrupt Resisted"} end ClearPendingForSource(sGUID) EM.UpdateUI() end return end
    if subevent=="SPELL_CAST_SUCCESS" then if IsInMyGroup(sGUID) and INTERRUPT_SPELLS[spellId] then AddPendingInterrupt(sGUID,sName,dGUID,dName,spellId,spellName) end return end

    if subevent=="SWING_DAMAGE" or subevent=="RANGE_DAMAGE" or subevent=="SPELL_DAMAGE" then
        local aGUID,aName,vGUID,vName,amount,overkill,crit,dmgSpell = ExtractDamageArgs(subevent, CombatLogGetCurrentEventInfo())
        if amount and amount>0 then ConsiderDamage(aGUID,aName,amount,crit,dmgSpell) ConsiderFailDamageTaken(aGUID,aName,vGUID,vName,amount,dmgSpell) if overkill and overkill>0 then ConsiderFailOverkill(aGUID,aName,vGUID,vName,overkill,dmgSpell) end BumpNonTankHeavyHit(vGUID,amount) EM.UpdateUI() end
        return
    end

    if subevent=="SPELL_HEAL" or subevent=="SPELL_PERIODIC_HEAL" then
        local _,aGUID,aName,vGUID,vName,effective,overheal,crit,healSpell = ExtractHealArgs(CombatLogGetCurrentEventInfo())
        if effective and effective>0 then ConsiderHeal(aGUID,aName,effective,crit,healSpell) end
        if overheal and overheal>0 then ConsiderFailOverheal(aGUID,aName,overheal,healSpell) end
        EM.UpdateUI()
        return
    end

    if subevent=="UNIT_DIED" or subevent=="UNIT_DESTROYED" then
        if IsInMyGroup(dGUID) then
            NoteDeath(dGUID)
            if (deathCounts[dGUID] or 0) >= 3 then local n=guidToName[dGUID] or "Unknown" DEFAULT_CHAT_FRAME:AddMessage(string.format("|cffff4040ZaesEpicMoments: %s has died %d times this run.|r", n, deathCounts[dGUID])) end
            EM.UpdateUI()
        end
        return
    end
end

local function OnGroupChanged()
    RebuildGroup()
    if ShouldFrameBeVisible() then ZaesEpicMomentsFrame:Show() else ZaesEpicMomentsFrame:Hide() end
    EM.UpdateUI()
end

local function OnZoneChanged()
    ResetRecords()
    if ShouldFrameBeVisible() then ZaesEpicMomentsFrame:Show() else ZaesEpicMomentsFrame:Hide() end
end

f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("RAID_ROSTER_UPDATE")
f:RegisterEvent("PARTY_MEMBERS_CHANGED")
f:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
f:RegisterEvent("ZONE_CHANGED_NEW_AREA")

f:SetScript("OnEvent", function(self, event)
    if event=="PLAYER_ENTERING_WORLD" then
        RebuildGroup()
        ResetRecords()
        if ShouldFrameBeVisible() then ZaesEpicMomentsFrame:Show() else ZaesEpicMomentsFrame:Hide() end
        return
    end
    if event=="RAID_ROSTER_UPDATE" or event=="PARTY_MEMBERS_CHANGED" then OnGroupChanged() return end
    if event=="ZONE_CHANGED_NEW_AREA" then OnZoneChanged() return end
    if event=="COMBAT_LOG_EVENT_UNFILTERED" then OnCombatLogEvent() return end
end)

SLASH_ZAESEPICMOMENTS1 = "/zem"
SLASH_ZAESEPICMOMENTS2 = "/zaesepicmoments"
SlashCmdList["ZAESEPICMOMENTS"] = function(msg)
    if msg=="show" then ZaesEpicMomentsFrame:Show() return end
    if msg=="hide" then ZaesEpicMomentsFrame:Hide() return end
    DEFAULT_CHAT_FRAME:AddMessage("|cffffff00=== Zaes Epic Moments — This Run ===|r")
    DEFAULT_CHAT_FRAME:AddMessage(string.format("Biggest Hit: %s - %s for %s%s", records.topDamage.player, records.topDamage.spell, FormatNum(records.topDamage.amount), records.topDamage.crit and " (crit)" or ""))
    DEFAULT_CHAT_FRAME:AddMessage(string.format("Biggest Heal: %s - %s for %s%s", records.topHeal.player, records.topHeal.spell, FormatNum(records.topHeal.amount), records.topHeal.crit and " (crit)" or ""))
    DEFAULT_CHAT_FRAME:AddMessage(string.format("Biggest Crit: %s - %s for %s [%s]", records.topCrit.player, records.topCrit.spell, FormatNum(records.topCrit.amount), records.topCrit.kind))
end
