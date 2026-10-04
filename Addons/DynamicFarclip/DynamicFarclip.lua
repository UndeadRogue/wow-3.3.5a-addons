-- Dynamic Farclip
--
-- Keeps farclip as high as the framerate allows, per zone.
--
-- Three constraints shape the design:
--
--  1. SetCVar("farclip", ...) in large jumps makes the client reinitialise
--     (looks like a ReloadUI). So every write moves by at most `stepSize`
--     yards and a slew loop walks toward the setpoint over several frames.
--
--  2. A frame rate cap (DXVK d3d9.maxFrameRate here) SATURATES the feedback
--     signal: at the cap, GetFramerate() reads the cap whether there is 2 fps
--     of headroom or 200. So this uses AIMD (additive increase, multiplicative
--     decrease) rather than proportional control - back off hard on a drop,
--     probe upward slowly, exponential cooldown, and remember per zone.
--
--     The cap also makes an absolute target dangerous: with a 144 cap and a
--     target of 140, ordinary variance reads as a drop and the setpoint
--     ratchets to the floor. So the effective target is also capped at a
--     FRACTION of the highest framerate actually observed, which self-calibrates
--     to whatever limiter is in play.
--
--  3. Farclip is not always the bottleneck. A busy raid is slow for reasons no
--     view distance change will fix. So after backing off, verify the framerate
--     actually improved; if it did not, restore and disengage for a while.

local ADDON = "DynamicFarclip"

local defaults = {
    enabled          = true,

    target           = 140,   -- absolute framerate floor we aim for
    targetFraction   = 0.92,  -- ...but never aim above this * observed peak
    raiseMargin      = 3,     -- probe upward only while avg > target + this
    dropDwell        = 2.0,   -- seconds continuously below target before backoff

    minClip          = 400,
    maxClip          = 2000,

    decreaseFactor   = 0.85,  -- multiplicative decrease on a sustained drop

    increaseStep     = 10,    -- additive increase (slow: the cap hides headroom)
    increaseInterval = 2.0,

    cooldownBase     = 15,    -- exponential backoff after each drop
    cooldownMax      = 300,
    cooldownDecay    = 120,   -- stable this long -> halve the cooldown

    -- effectiveness check (constraint 3)
    checkDelay       = 2.0,   -- settle this long before judging a backoff
    minGain          = 3,     -- fps improvement required to believe it helped
    disengageTime    = 180,   -- if it did not help, stop trying for this long

    -- write rate limiting (constraint 1)
    stepSize         = 10,
    slewRate         = 300,
    maxStepsPerFrame = 4,

    tick             = 0.3,
    histLen          = 5,     -- ~1.5s window
    settleTime       = 5.0,   -- ignore framerate this long after a load
    skipInstances    = true,
    verbose          = false,
}

local db
local current, want
local accum, count = 0, 0
local hist = {}
local lastTick, lastProbe = 0, 0
local probeAfter, stableSince, dropSince = 0, 0, 0
local suspendUntil, disengageUntil = 0, 0
local slewBudget = 0
local parked = false
local curZone
local observedMax = 0
local check                   -- pending effectiveness check

local function msg(fmt, ...)
    DEFAULT_CHAT_FRAME:AddMessage("|cff66ccff" .. ADDON .. ":|r " .. string.format(fmt, ...))
end

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function roundTo(v, step) return math.floor(v / step + 0.5) * step end

local function zoneKey()
    local z = GetRealZoneText()
    if not z or z == "" then z = "unknown" end
    return z
end

local function zoneStore(z)
    db.zones = db.zones or {}
    z = z or curZone or zoneKey()
    db.zones[z] = db.zones[z] or {}
    return db.zones[z]
end

local function resetHistory()
    accum, count = 0, 0
    for i = #hist, 1, -1 do hist[i] = nil end
    stableSince, dropSince = 0, 0
    check = nil
end

local function average()
    local n = #hist
    if n == 0 then return nil end
    local s = 0
    for i = 1, n do s = s + hist[i] end
    return s / n
end

-- Effective target: the absolute floor, but never above a fraction of the
-- best framerate we have actually seen. Self-calibrates to any frame cap.
local function effectiveTarget()
    local t = db.target
    if observedMax > 0 then
        local rel = observedMax * db.targetFraction
        if rel < t then t = rel end
    end
    return t
end

-- ------------------------------------------------------------ slew (write) --

local function slew(elapsed)
    if not current or not want or current == want then
        slewBudget = 0
        return
    end
    slewBudget = slewBudget + elapsed * db.slewRate
    local steps = 0
    while current ~= want and slewBudget >= db.stepSize and steps < db.maxStepsPerFrame do
        local delta = want - current
        if delta > db.stepSize then delta = db.stepSize
        elseif delta < -db.stepSize then delta = -db.stepSize end
        current = current + delta
        SetCVar("farclip", current)
        slewBudget = slewBudget - db.stepSize
        steps = steps + 1
    end
    if current == want then slewBudget = 0 end
end

-- -------------------------------------------------------------- controller --

local function setWant(v, why)
    v = clamp(roundTo(v, db.stepSize), db.minClip, db.maxClip)
    if v == want then return false end
    want = v
    if db.verbose then msg("setpoint -> %d (%s)", want, why or "") end
    return true
end

local function backoff(now, avg, zs)
    local prev = want
    if not setWant(want * db.decreaseFactor, string.format("sustained %.0f fps", avg)) then
        return
    end
    zs.good = want
    zs.cooldown = math.min((zs.cooldown or db.cooldownBase) * 2, db.cooldownMax)
    probeAfter = now + zs.cooldown
    lastProbe = now
    -- judge whether this actually helped before backing off any further
    check = { before = avg, prevWant = prev, due = nil }
    if db.verbose then
        msg("backoff %d -> %d, cooldown %ds", prev, want, zs.cooldown)
    end
end

local function control(now)
    if db.skipInstances and IsInInstance() then
        if not parked then
            parked = true
            setWant(db.maxClip, "instance")
            check = nil
        end
        return
    elseif parked then
        parked = false
        resetHistory()
        setWant(zoneStore().good or db.maxClip, "left instance")
        return
    end

    local avg = average()
    if not avg or avg <= 0 then return end

    if avg > observedMax then observedMax = avg
    else observedMax = math.max(avg, observedMax - 0.02) end

    local et = effectiveTarget()
    local zs = zoneStore()

    -- Resolve a pending effectiveness check before making new decisions.
    if check then
        if current ~= want then return end              -- still slewing
        if not check.due then check.due = now + db.checkDelay; return end
        if now < check.due then return end
        local gain = avg - check.before
        if gain < db.minGain then
            if db.verbose then
                msg("backoff gained only %.1f fps - farclip is not the limiter here", gain)
            end
            setWant(check.prevWant, "ineffective, restoring")
            zs.good = check.prevWant
            disengageUntil = now + db.disengageTime
            check = nil
            dropSince = 0
            return
        end
        if db.verbose then msg("backoff gained %.1f fps", gain) end
        check = nil
        dropSince = 0
        return
    end

    if avg < et then
        if now < disengageUntil then return end         -- known not farclip-bound
        if dropSince == 0 then dropSince = now end
        if now - dropSince >= db.dropDwell then
            backoff(now, avg, zs)
            dropSince = 0
        end
        stableSince = 0
        return
    end

    dropSince = 0

    if avg > et + db.raiseMargin then
        if stableSince == 0 then stableSince = now end
        if zs.cooldown and zs.cooldown > db.cooldownBase
           and now - stableSince >= db.cooldownDecay then
            zs.cooldown = math.max(db.cooldownBase, zs.cooldown / 2)
            stableSince = now
        end
        if now >= probeAfter and now - lastProbe >= db.increaseInterval
           and want < db.maxClip and current == want then
            setWant(want + db.increaseStep, "probe")
            zs.good = want
            lastProbe = now
        end
    else
        stableSince = 0
    end
end

-- -------------------------------------------------------------------- hooks --

local f = CreateFrame("Frame", ADDON .. "Frame")

f:SetScript("OnUpdate", function(self, elapsed)
    if not db then return end

    slew(elapsed)                      -- always finish a slew, even if disabled
    if not db.enabled then return end

    local now = GetTime()
    if now < suspendUntil then return end   -- do NOT sample during a load/zone settle

    accum = accum + GetFramerate()
    count = count + 1

    if now - lastTick < db.tick then return end
    lastTick = now

    if count > 0 then
        hist[#hist + 1] = accum / count
        while #hist > db.histLen do table.remove(hist, 1) end
        accum, count = 0, 0
    end

    control(now)
end)

local function onZone()
    local z = zoneKey()
    if z == curZone then return end
    curZone = z
    resetHistory()
    suspendUntil = GetTime() + db.settleTime
    disengageUntil = 0
    local zs = zoneStore(z)
    probeAfter = GetTime() + (zs.cooldown or 0)
    setWant(zs.good or db.maxClip, "zone: " .. z)
end

f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("ZONE_CHANGED_NEW_AREA")
f:RegisterEvent("ZONE_CHANGED")

f:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON then return end
        DynamicFarclipDB = DynamicFarclipDB or {}
        db = DynamicFarclipDB
        for k, v in pairs(defaults) do
            if db[k] == nil then db[k] = v end
        end
        db.zones = db.zones or {}
        current = tonumber(GetCVar("farclip")) or db.maxClip
        want = current
        suspendUntil = GetTime() + db.settleTime
        resetHistory()
    else
        if not db then return end
        if event == "PLAYER_ENTERING_WORLD" then
            current = tonumber(GetCVar("farclip")) or db.maxClip
            want = current
            curZone = nil
            observedMax = 0
        end
        onZone()
    end
end)

-- ---------------------------------------------------------------- slash cmd --

local function status()
    local avg = average()
    local zs = zoneStore()
    msg("%s | farclip %d -> %d | fps %.0f (avg %s)",
        db.enabled and "|cff00ff00on|r" or "|cffff0000off|r",
        current or -1, want or -1, GetFramerate(),
        avg and string.format("%.0f", avg) or "-")
    msg("target %d (abs %d, %d%% of observed peak %.0f)",
        math.floor(effectiveTarget()), db.target,
        math.floor(db.targetFraction * 100), observedMax)
    msg("zone '%s': learned %s, cooldown %ss%s%s",
        curZone or "?", tostring(zs.good or "none"),
        tostring(math.floor(zs.cooldown or db.cooldownBase)),
        parked and " |cffffff00(instance)|r" or "",
        (GetTime() < disengageUntil) and " |cffffff00(disengaged)|r" or "")
end

SLASH_DYNAMICFARCLIP1 = "/dfc"
SLASH_DYNAMICFARCLIP2 = "/dynamicfarclip"
SlashCmdList["DYNAMICFARCLIP"] = function(input)
    local cmd, rest = string.match(input or "", "^(%S*)%s*(.-)$")
    cmd = string.lower(cmd or "")
    local n = tonumber(rest)

    if cmd == "" or cmd == "status" then
        status()
    elseif cmd == "on" then
        db.enabled = true; resetHistory(); msg("enabled")
    elseif cmd == "off" then
        db.enabled = false; setWant(db.maxClip, "disabled")
        msg("disabled - slewing back to %d", db.maxClip)
    elseif cmd == "target" and n then
        db.target = n; resetHistory(); msg("absolute target = %d fps", n)
    elseif cmd == "fraction" and n then
        db.targetFraction = n > 1 and n / 100 or n
        msg("target fraction = %d%% of observed peak", math.floor(db.targetFraction * 100))
    elseif cmd == "min" and n then
        db.minClip = n; setWant(want, "min changed"); msg("min farclip = %d", n)
    elseif cmd == "max" and n then
        db.maxClip = n; msg("max farclip = %d", n)
    elseif cmd == "set" and n then
        local zs = zoneStore()
        zs.good = clamp(roundTo(n, db.stepSize), db.minClip, db.maxClip)
        zs.cooldown = db.cooldownMax
        probeAfter = GetTime() + zs.cooldown
        setWant(zs.good, "manual"); check = nil
        msg("zone '%s' pinned to %d", curZone or "?", zs.good)
    elseif cmd == "forget" then
        if rest == "all" then
            db.zones = {}; msg("forgot all zones")
        elseif rest ~= "" then
            if db.zones[rest] then db.zones[rest] = nil; msg("forgot '%s'", rest)
            else msg("no record for '%s'", rest) end
        else
            db.zones[curZone or ""] = nil
            setWant(db.maxClip, "forget"); msg("forgot '%s'", curZone or "?")
        end
    elseif cmd == "list" then
        local any = false
        for z, zs in pairs(db.zones) do
            any = true
            msg("  %s: %s (cooldown %ss)", z, tostring(zs.good or "-"),
                tostring(math.floor(zs.cooldown or db.cooldownBase)))
        end
        if not any then msg("nothing learned yet") end
    elseif cmd == "verbose" then
        db.verbose = not db.verbose; msg("verbose = %s", tostring(db.verbose))
    elseif cmd == "instances" then
        db.skipInstances = not db.skipInstances
        msg("skipInstances = %s", tostring(db.skipInstances))
    elseif cmd == "reset" then
        local zones = db.zones
        for k, v in pairs(defaults) do db[k] = v end
        db.zones = zones
        setWant(db.maxClip, "reset"); msg("settings reset (learned zones kept)")
    else
        msg("/dfc                - status")
        msg("/dfc on | off")
        msg("/dfc target <fps>   - absolute floor (default %d)", defaults.target)
        msg("/dfc fraction <pct> - floor as %% of observed peak (default %d)",
            math.floor(defaults.targetFraction * 100))
        msg("/dfc min | max <n>  - bounds (default %d / %d)", defaults.minClip, defaults.maxClip)
        msg("/dfc set <n>        - pin current zone, stop probing")
        msg("/dfc list | forget [zone|all]")
        msg("/dfc instances | verbose | reset")
    end
end
