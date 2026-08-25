--[[
    heavily based on iced coffee's pk fixes https://gist.github.com/IcedCoffeee/971abeec986e2786ce05f4dee0a17473 
--]]
local CurrentFilePath = debug.getinfo(function() end).short_src
--[[----------------------------------------------------------------
        convars
------------------------------------------------------------------]]
local ConvarCache = {}
--[convar] = value, 
local function CreateConVar_either(...)
    local args = {...}
    if CLIENT then
        CreateClientConVar(unpack(args))
    elseif SERVER then
        CreateConVar(unpack(args))
    end

    local convarname = args[1]
    local convarvalue = GetConVar(convarname):GetString()
    convarvaluetonumber = tonumber(convarvalue) -- :GetInt() :GetFloat()
    --convarvaluetonumber = (convarvaluetonumber == 1 and true) or (convarvaluetonumber == 0 and false) -- :GetBool() -- this is a bad idea. pk_spawndist can be set to 1
    convarvalue = convarvaluetonumber or convarvalue
    ConvarCache[convarname] = convarvalue
    cvars.AddChangeCallback(convarname, function(_, _, value_new)
        ConvarCache[convarname] = value_new
        return
    end, convarname)
end

local function CreateClientConVar_Cached(...)
    CreateConVar_either(unpack({...}))
end

local function CreateConVar_Cached(...)
    CreateConVar_either(unpack({...}))
end

local function GetConVar_Cached(convarname)
    if ConvarCache[convarname] then
        --
        return ConvarCache[convarname]
    end

    -- this hopefully will never happen, the cache hopefully will always work
    local convarvalue = GetConVar(convarname):GetString()
    convarvaluetonumber = tonumber(convarvalue) -- :GetInt() :GetFloat()
    convarvaluetonumber = (convarvaluetonumber == 1 and true) or false -- :GetBool()
    convarvalue = convarvaluetonumber or convarvalue
    return convarvalue
end

if CLIENT then
    CreateClientConVar_Cached("pk_grabfix", "0", true, true, "Whether or not to enable grabfix for yourself")
    CreateClientConVar_Cached("pk_spawndist", "2048", true, true, "Distance to spawn props")
elseif SERVER then
    CreateConVar_Cached("pk_sv_spawndist", "0", FCVAR_ARCHIVE, "Whether or not to allow players to set the distance they spawn props", 0)
    CreateConVar_Cached("pk_sv_maxspawndist", "4096", FCVAR_ARCHIVE, "Max spawn distance for people using pk_spawndist", 0)
end

--[[----------------------------------------------------------------
        Other
------------------------------------------------------------------]]
if SERVER then
    ---[[ From https://steamcommunity.com/sharedfiles/filedetails/?id=2725102799, by steamcommunity.com/profiles/76561197962184163 ]]---
    -- this isn't really that important for propkill, but it might fix some small issues with the trace of the propspawn
    local PLAYERMETA = FindMetaTable("Player")
    function PLAYERMETA:pk_GetFixedShootPos()
        return self.pk_fixedshootpos
    end

    local GetShootPos = PLAYERMETA.GetShootPos
    hook.Add("SetupMove", CurrentFilePath .. "|FixPKShootpos", function(ply, mv, cmd)
        ply.pk_fixedshootpos = GetShootPos(ply)
        return
    end)
    ---[[]]---
end

--[[--------------------------------------------------------------------------------------------
    pk_grabfix
    This uses Iced Coffee's method to fixing physgun grab in the air, just with less detouring
----------------------------------------------------------------------------------------------]]
local DefaultSpawnDist = 2048 -- spawn distance for props by default is 2048 https://github.com/Facepunch/garrysmod/blob/946ed9f101ad36a7ce601e1ea0ae2c9c64bc6e22/garrysmod/gamemodes/sandbox/gamemode/commands.lua#L41
if CLIENT then
    local ValidPropCache = {} -- Probably faster than calling util.IsValidProp() on every single bindpress
    local firsttimepressed = false
    -- Issue: if the player uses a bind to spawn the prop like 'alias tide "gm_spawn models/props/de_tides/gate_large.mdl"' then gm_spawn_pk will never be run
    hook.Add("PlayerBindPress", CurrentFilePath .. "|Suppressgm_spawnBind", function(ply, bind, pressed)
        if tobool(GetConVar_Cached("pk_grabfix")) == false or GetConVar_Cached("pk_spawndist") == DefaultSpawnDist then return end
        if not string.find(bind, "gm_spawn") then return end
        firsttimepressed = not firsttimepressed
        if firsttimepressed == false then return end
        local args = string.Split(bind, " ")
        local modelname = args[2]
        if ValidPropCache[modelname] or util.IsValidProp(modelname) then
            ValidPropCache[modelname] = true
            RunConsoleCommand("gm_spawn_pk", args[2])
            return true
        end
    end)
elseif SERVER then
    -- for reference:
    -- concommand(gm_spawn) runs:
    -- 1. CCSpawn(ply, command, arguments) 
    -- 2. GMODSpawnProp(ply, modelName=args[1], iSkin=args[2], strBody=args[3]) 
    --  1a: local e = DoPlayerEntitySpawn(ply, "prop_physics", model, iSkin, strBody)
    --  2a: FixInvalidPhysicsObject(e)
    --  3a: DoPropSpawnedEffect(e)
    local function GetSpawnTrace(ply) -- https://github.com/Facepunch/garrysmod/blob/946ed9f101ad36a7ce601e1ea0ae2c9c64bc6e22/garrysmod/gamemodes/sandbox/gamemode/commands.lua#L34-L45
        local vStart = ply:pk_GetFixedShootPos()
        local vForward = ply:EyeAngles():Forward() -- Ignores world clicker
        if ply.LastMV and ply:GetInfoNum("pk_grabfix", 0) == 1 then
            local mv = ply.LastMV
            local origin = mv:GetOrigin()
            local eyeheight = ply:pk_GetFixedShootPos().z - ply:GetPos().z
            origin.z = origin.z + eyeheight
            vStart = origin + mv:GetVelocity() / (1 / engine.TickInterval())
            vForward = mv:GetAngles():Forward()
        end

        local trace = {}
        trace.start = vStart
        --
        local PlayerSpawnDist = DefaultSpawnDist
        local pk_spawndist_enabled = GetConVar_Cached("pk_sv_spawndist")
        if pk_spawndist_enabled then
            local MaxSpawnDist = GetConVar_Cached("pk_sv_maxspawndist")
            PlayerSpawnDist = math.Clamp(ply:GetInfoNum("pk_spawndist", 2048), 0, MaxSpawnDist)
        end

        trace.endpos = vStart + vForward * PlayerSpawnDist
        trace.filter = {ply, ply:GetVehicle()}
        return util.TraceLine(trace)
    end

    -- This is the exact same method as the old vFlushPoint, I just like it as a separate function more
    local function GetLegacyvFlushPoint(tr, ent)
        local vFlushPoint = tr.HitPos - (tr.HitNormal * 512) -- Find a point that is definitely out of the object in the direction of the floor
        vFlushPoint = ent:NearestPoint(vFlushPoint) -- Find the nearest point inside the object to that point
        vFlushPoint = ent:GetPos() - vFlushPoint -- Get the difference
        vFlushPoint = tr.HitPos + vFlushPoint -- Add it to our target pos
        return vFlushPoint
    end

    concommand.Add("gm_spawn_pk", function(ply, cmd, args)
        local modelname = args[1]
        ply.spawnQueue = ply.spawnQueue or {}
        ply.spawnQueue[#ply.spawnQueue + 1] = modelname
        ply.LastMV = nil
        return
    end)

    --[[----------------------------------------------------------------
        Fixed duplicate functions
        all of these are almost the same as the original function
    ------------------------------------------------------------------]]
    -- Unchanged, used by TryFixPropPosition()
    local function fixupProp(ply, ent, hitpos, mins, maxs)
        local entPos = ent:GetPos()
        local endposD = ent:LocalToWorld(mins)
        local tr_down = util.TraceLine({
            start = entPos,
            endpos = endposD,
            filter = {ent, ply}
        })

        local endposU = ent:LocalToWorld(maxs)
        local tr_up = util.TraceLine({
            start = entPos,
            endpos = endposU,
            filter = {ent, ply}
        })

        if tr_up.Hit and tr_down.Hit then return end
        if tr_down.Hit then ent:SetPos(entPos + (tr_down.HitPos - endposD)) end
        if tr_up.Hit then ent:SetPos(entPos + (tr_up.HitPos - endposU)) end
    end

    -- Unchanged, used by fixedDoPlayerEntitySpawn()
    local function TryFixPropPosition(ply, ent, hitpos)
        fixupProp(ply, ent, hitpos, Vector(ent:OBBMins().x, 0, 0), Vector(ent:OBBMaxs().x, 0, 0))
        fixupProp(ply, ent, hitpos, Vector(0, ent:OBBMins().y, 0), Vector(0, ent:OBBMaxs().y, 0))
        fixupProp(ply, ent, hitpos, Vector(0, 0, ent:OBBMins().z), Vector(0, 0, ent:OBBMaxs().z))
    end

    -- Changed to:
    -- use mv-aware version of GetSpawnTrace(), 
    -- early returns if entname ~= prop_physics, 
    -- remove logic accounting for non props (bloat)
    local function fixedDoPlayerEntitySpawn(ply, entity_name, model, iSkin, strBody)
        if entity_name ~= "prop_physics" then -- this is a propkill function. it should only spawn prop_physics, everything else would make no sense to account for
            return
        end

        local tr = GetSpawnTrace(ply)
        local ent = ents.Create(entity_name)
        if not IsValid(ent) then return end
        local ang = ply:EyeAngles()
        ang.yaw = ang.yaw + 180
        ang.roll = 0
        ang.pitch = 0
        ent:SetModel(model)
        ent:SetSkin(iSkin)
        ent:SetAngles(ang)
        if strBody then ent:SetBodyGroups(strBody) end
        ent:SetPos(tr.HitPos)
        ent:SetCreator(ply)
        ent:Spawn()
        ent:Activate()
        local vFlushPoint = GetLegacyvFlushPoint(tr, ent)
        ent:SetPos(vFlushPoint)
        ply:SendLua("achievements.SpawnedProp()")
        TryFixPropPosition(ply, ent, tr.HitPos)
        return ent
    end

    -- Unchanged
    local function fixedGMODSpawnProp(ply, model, iSkin, strBody)
        if IsValid(ply) and not gamemode.Call("PlayerSpawnProp", ply, model) then return end
        local e = fixedDoPlayerEntitySpawn(ply, "prop_physics", model, iSkin, strBody)
        if not IsValid(e) then return end
        if IsValid(ply) then gamemode.Call("PlayerSpawnedProp", ply, model, e) end
        FixInvalidPhysicsObject(e) -- This function doesn't need to be duplicated, it's defined global in commands.lua
        DoPropSpawnedEffect(e) -- ditto ^
        undo.Create("prop_physics")
        undo.SetPlayer(ply)
        undo.AddEntity(e)
        undo.Finish("#prop_physics (" .. tostring(model) .. ")")
        ply:AddCleanup("props", e)
    end

    -- Unchanged, except now calls fixedGmodSpawnProp() instead of GmodSpawnProp()
    local function fixedCCSpawn(ply, command, arguments)
        -- We don't support this command from dedicated server console
        if not IsValid(ply) then return end
        if not ply:Alive() and not ply:IsAdmin() then return end
        local modelName = arguments[1]
        if modelName == nil then return end
        if modelName:find("%.[/\\]") then return end
        modelName = modelName:gsub("\\\\+", "/")
        modelName = modelName:gsub("//+", "/")
        modelName = modelName:gsub("\\/+", "/")
        modelName = modelName:gsub("/\\+", "/")
        modelName = modelName:lower()
        modelName = modelName:gsub("\\+", "/")
        if not modelName:StartsWith("models/") or not modelName:EndsWith(".mdl") then return end
        if not util.IsValidModel(modelName) then return end
        local iSkin = tonumber(arguments[2]) or 0
        local strBody = arguments[3] or nil
        if not gamemode.Call("PlayerSpawnObject", ply, modelName, iSkin) then return end
        if util.IsValidProp(modelName) then
            fixedGMODSpawnProp(ply, modelName, iSkin, strBody)
            return
        end
    end

    local reusable_tbl = {
        -- {modelname, iSkin, strBody}, used by fixedCCSpawn()
        nil,
        0,
        nil
    }

    hook.Add("SetupMove", CurrentFilePath .. "pk_grabfixspawnQueue", function(ply, mv, cmd)
        if not ply.spawnQueue or #ply.spawnQueue == 0 then
            ply.LastMV = nil
            return
        end

        ply.LastMV = mv
        local success, err
        for i = #ply.spawnQueue, 1, -1 do
            local modelname = ply.spawnQueue[i]
            reusable_tbl[1] = modelname
            success, err = pcall(fixedCCSpawn, ply, "gm_spawn", reusable_tbl) -- I'm unsure at this point if this pcall is necessary. I don't think I've seen it error in recent versions.
            if not success then ErrorNoHaltWithStack(err) end
            table.remove(ply.spawnQueue, i)
        end
    end)
end
