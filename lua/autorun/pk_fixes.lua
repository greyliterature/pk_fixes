--[[
    heavily based on iced coffee's pk fixes https://gist.github.com/IcedCoffeee/971abeec986e2786ce05f4dee0a17473 
--]]
local CurrentFilePath = debug.getinfo(function() end).short_src
if CLIENT then
    CreateClientConVar("pk_spawnfix", "0", true, true, "Whether or not to enable spawnfix for yourself")
    CreateClientConVar("pk_spawndist", "2048", true, true, "Distance to spawn props")
    local function PropRequest(modelname) -- like iced coffee's redundnet system
        net.Start("PropRequest")
        net.WriteString(modelname)
        net.SendToServer()
        print("yep", modelname)
    end

    net.Receive("PropPingPoll", function()
        net.Start("PropPingPoll")
        net.SendToServer()
    end)

    local firsttime = true
    hook.Add("PlayerBindPress", "SuppressPropBinds", function(ply, bind, pressed)
        -- make this hook add remove dynamically later
        if not string.find(bind, "gm_spawn") then return end
        firsttime = not firsttime
        if firsttime ~= true then return end
        if GetConVar("pk_spawnfix"):GetBool() == true then
            local split = string.Split(bind, " ")
            local modelname = split[2]
            print(modelname, util.IsValidProp("models/props/de_tides/gate_large.mdl"), "X")
            if util.IsValidProp(modelname) then -- if its a prop then run the special command, otherwise just run gm_spawn like normal (so things like ragdolls are handled normally)
                RunConsoleCommand("pk_gm_spawn", modelname)
                print("ye")
                return true
            else
                return
            end
        end
    end)

    concommand.Add("pk_gm_spawn", function(ply, cmd, args)
        print("HI", args[1])
        PropRequest(args[1])
    end)
elseif SERVER then
    CreateConVar("pk_sv_spawndist", "0", FCVAR_ARCHIVE, "Whether or not to allow players to set the distance they spawn props", 0)
    CreateConVar("pk_sv_maxspawndist", "4096", FCVAR_ARCHIVE, "Max spawn distance for people using pk_spawndist", 0)
    ---[[ From https://steamcommunity.com/sharedfiles/filedetails/?id=2725102799, by steamcommunity.com/profiles/76561197962184163 ]]---
    -- this isn't really that important for propkill, but it might fix some small issues with the trace of the propspawn
    local PLAYERMETA = FindMetaTable("Player")
    function PLAYERMETA:GetFixedShootPos()
        return self.pk_fixedshootpos
    end

    hook.Add("SetupMove", CurrentFilePath .. "|FixPKShootpos", function(ply, mv, cmd)
        ply.pk_fixedshootpos = ply:GetShootPos()
        return
    end)

    ---[[]]---
    local DefaultSpawnDist = 2048 -- spawn distance for props by default is 2048 https://github.com/Facepunch/garrysmod/blob/946ed9f101ad36a7ce601e1ea0ae2c9c64bc6e22/garrysmod/gamemodes/sandbox/gamemode/commands.lua#L41
    local function GetSpawnTrace(ply, ent) -- https://github.com/Facepunch/garrysmod/blob/946ed9f101ad36a7ce601e1ea0ae2c9c64bc6e22/garrysmod/gamemodes/sandbox/gamemode/commands.lua#L34-L45
        -- ent is added to args because it needs to be added to the trace filter
        local pk_spawndist_enabled = GetConVar("pk_sv_spawndist"):GetBool()
        local MaxSpawnDist = (pk_spawndist_enabled == true and GetConVar("pk_sv_maxspawndist"):GetInt()) or DefaultSpawnDist
        local vStart = ply:GetFixedShootPos()
        print("fix:", ply:GetFixedShootPos(), "unfix: ", ply:GetShootPos())
        local vForward = ply:EyeAngles():Forward() -- Ignores world clicker
        if ply.LastMV then
            local mv = ply.LastMV
            local origin = mv:GetOrigin()
            local eyeheight = ply:GetShootPos().z - ply:GetPos().z
            origin.z = origin.z + eyeheight
            vStart = origin + mv:GetVelocity() / (1 / engine.TickInterval()) 
            print(mv:GetVelocity() / (1 / engine.TickInterval()), "ASDIASDIOSA")
            vForward = mv:GetAngles():Forward()
            print(mv, "ASDASD")
        end

        local trace = {}
        trace.start = vStart
        local PlayerSpawnDist = (pk_spawndist_enabled == true and math.Clamp(ply:GetInfoNum("pk_spawndist", 2048), 0, MaxSpawnDist)) or DefaultSpawnDist
        trace.endpos = vStart + vForward * PlayerSpawnDist
        trace.filter = {ply, ply:GetVehicle(), ent}
        return util.TraceLine(trace)
    end

    local ENTMETA = FindMetaTable("Entity")
    function ENTMETA:NearestCollisionPoint(origin, direction_vec) -- returns the physgun vector such that hitpos - physgun vector = closest point to which the prop can be moved and be hit by a trace
        -- this fixes ent:NearestPoint() not working with physguns, because the physgun uses the collision mesh for its traces instead of the bounding box (which ent:NearestPoint() uses)
        -- visually: https://files.catbox.moe/wb1hrj.PNG 
        local physobj = self:GetPhysicsObject()
        local bestdist = math.huge
        local nearestpos = nil
        --[[
        local direction_tr = util.TraceLine({
            startpos = origin,
            endpos = self:GetPos()
        })

        local direction_vec = (direction_tr.StartPos - direction_tr.HitPos):GetNormalized()
        --]]
        for _, meshtbl in ipairs(physobj:GetMeshConvexes()) do
            for _, vertextbl in ipairs(meshtbl) do
                local vertexpos = self:LocalToWorld(vertextbl["pos"])
                local len = vertexpos - origin
                local dot = len:Dot(direction_vec)
                local closestalongray = origin + direction_vec * dot
                local dist = vertexpos:DistToSqr(closestalongray)
                if dist < bestdist then
                    bestdist = dist
                    nearestpos = vertexpos
                end
            end
        end
        return nearestpos
    end

    local function GetLegacyvFlushPoint(tr, ent)
        local vFlushPoint = tr.HitPos - (tr.HitNormal * 512) -- Find a point that is definitely out of the object in the direction of the floor
        vFlushPoint = ent:NearestPoint(vFlushPoint) -- Find the nearest point inside the object to that point
        vFlushPoint = ent:GetPos() - vFlushPoint -- Get the difference
        vFlushPoint = tr.HitPos + vFlushPoint -- Add it to our target pos
        return vFlushPoint
    end

    --local reusable_vec = Vector(0, 0, 0)
    --local trackedplayer = nil
    --[[
    -- the current implementation of this is a bit too awkward to be used. if a prop is spawned below the floor, then in the next tick it will be sent to vflushpoint (far above the floor).
    hook.Add("OnPhysgunPickup", CurrentFilePath .. "|MoveToLegacyvFlushPointOnPickup", function(ply, ent)
        if not ent.LegacyvFlushPoint then return end
        if engine.TickCount() - ent.CreationTime == 1 then -- if its not in the same tick, then dont do anything. this prevents players from spawning a spawnfixed prop and then physgunning it way after to teleport it
            print("moving")
            print("before: ", ent:GetPos(), "after: ", ent.LegacyvFlushPoint)
        end

        timer.Simple(0, function()
            ent:SetPos(ent.LegacyvFlushPoint)
            ent.CreationTime = nil
            ent.LegacyvFlushPoint = nil
        end)
    end)
    --]]
    local function GetvFlushPoint(tr, ent) -- https://github.com/Facepunch/garrysmod/blob/946ed9f101ad36a7ce601e1ea0ae2c9c64bc6e22/garrysmod/gamemodes/sandbox/gamemode/commands.lua#L367-L371
        local OnFlatGround = math.abs(vector_up.z) - math.abs(tr.HitNormal.z) < 0.05
        if OnFlatGround == true or not tr.Hit then -- revert to old method if the surface is flat enough downwards or it never hit anything
            print("ya")
            return GetLegacyvFlushPoint(tr, ent)
        end

        local ply = ent:GetCreator()
        local aimvec = ply:GetAimVector()
        local vFlushPoint = tr.HitPos - (tr.HitNormal * 512)
        vFlushPoint = ent:NearestCollisionPoint(vFlushPoint, aimvec)
        vFlushPoint = ent:GetPos() - vFlushPoint
        vFlushPoint = tr.HitPos + vFlushPoint * 0.97 -- * 0.97 moves it towards the player's physgun trace more, if we don't do this then if the player is moving away from the prop they won't grab it, even if they're holding left-click.
        print(vFlushPoint.z, "C")
        print("calculated" .. CurTime())
        print("eyetrace ", GetSpawnTrace(ply, ent).HitPos)
        print("trace pos", tr.HitPos)
        print("DDD")
        --trackedplayer = ply
        ent.LegacyvFlushPoint = GetLegacyvFlushPoint(tr, ent)
        ent.CreationTime = engine.TickCount()
        --[[
        -- this seems too expensive for what it is, and also half broken. maybe going to revisit later
        local obbmaxes = ent:OBBMaxs()
        local obbmins = ent:OBBMins()
        reusable_vec.x = 0
        reusable_vec.y = 0
        reusable_vec.z = obbmaxes.z
        local diff_up = math.abs(vFlushPoint.z - ent:LocalToWorld(reusable_vec).z)
        reusable_vec.x = 0
        reusable_vec.y = 0
        reusable_vec.z = obbmins.z
        local diff_down = math.abs(vFlushPoint.z - ent:LocalToWorld(reusable_vec).z)
        local flushpoint_nearest_obb_point_multiple = (diff_up < diff_down and 1) or -1 -- 1 = the flushpoint is closest to the top of the prop, -1 = the flushpoint is closest to the bottom of the prop
        local obbcenter = ent:OBBCenter()
        print(diff_up, diff_down, math.min(diff_up, diff_down) == diff_up)
        local obbtopcenter = obbcenter * 1 -- copy
        obbtopcenter.z = obbmaxes.z -- get top center 
        local bounding_radius = obbtopcenter.z - obbcenter.z -- this is used as bounding radius, we dont want the hypotenuse from obbmins to obbmaxes, we want the distance top to center
        tr = {
            startpos = vFlushPoint,
            endpos = vFlushPoint + vector_up * bounding_radius * flushpoint_nearest_obb_point_multiple -- vec_up * -bounding = can the ent be moved 
        }

        print(flushpoint_nearest_obb_point_multiple)
        local collision_tr = util.TraceHull(tr)
        if not collision_tr.Hit then -- if we didn't hit anything, we can afford to move the prop up or down such that it spawns at its center Z value. this looks nicer and should be more reliable to grab
            reusable_vec.z = bounding_radius
            vFlushPoint = vFlushPoint - reusable_vec * flushpoint_nearest_obb_point_multiple
        end
        --]]
        return vFlushPoint
    end

    --[[
    -- original function:
        function DoPropSpawnedEffect(e)
            if DisablePropCreateEffect then return end
            e:SetSpawnEffect(true)
        end
    --]]
    CreateConVar("pk_sv_spawnfix", "1", FCVAR_ARCHIVE, "Whether or not to allow players to enable pk_spawnfix for themselves", 0)
    local function AddSpawnFix()
        if not newDoPropSpawnedEffect then oldDoPropSpawnedEffect = DoPropSpawnedEffect end
        function newDoPropSpawnedEffect(e)
            print("hey")
            local ent = e
            local pk_spawnfix_enabled = GetConVar("pk_sv_spawnfix"):GetBool()
            local ply = ent:GetCreator()
            print(pk_spawnfix_enabled, "A")
            if pk_spawnfix_enabled == true and ply:GetInfo("pk_spawnfix") == "1" then
                print("runing")
                if ent:GetClass() ~= "prop_physics" then return end
                if ShouldMoveLastProp then return end
                ent:SetPos(GetvFlushPoint(GetSpawnTrace(ply, ent), ent))
                -- issue: if player is running too fast away from the prop (+speed) then it doesnt grab the prop
                --trackedplayer = nil
            end
        end

        --[[
        function DoPropSpawnedEffect(e)
            oldDoPropSpawnedEffect(e)
            newDoPropSpawnedEffect(e)
        end

        if not newGMODSpawnProp then oldGMODSpawnProp = GMODSpawnProp end
        function GMODSpawnProp(...)
            oldGMODSpawnProp({...})
            return
        end
        --]]
        util.AddNetworkString("PropRequest")
        util.AddNetworkString("PropPingPoll")
        net.Receive("PropRequest", function(len, ply)
            local modelname = net.ReadString()
            ply.RequestedPropModel = modelname
            print("rec" .. modelname)
            --net.Start("PropPingPoll")
            --net.Send(ply)
            ply.spawnQueue = ply.spawnQueue or {}
            ply.spawnQueue[#ply.spawnQueue + 1] = modelname
        end)

        local reusable_tbl = {}
        net.Receive("PropPingPoll", function(len, ply)
            --reusable_tbl[1] = ply.RequestedPropModel
            --CCSpawn(ply, "gm_spawn", reusable_tbl) -- gm_spawn supports 2 other args but it doesn't seem important enough to support.
        end)
    end

    if CurTime() > 10 then -- for testing
        AddSpawnFix()
    end

    hook.Add("PostGamemodeLoaded", CurrentFilePath .. "|Spawnfix", function()
        if GetConVar("pk_spawnfix") then -- PostGamemodeLoaded will always run after iced's version, so this should reliably catch conflicts
            error("Old pk_spawnfix convar found, this script will conflict with it.")
            return
        end

        AddSpawnFix()
    end)

    --[[
    if not newDoPlayerEntitySpawn then oldDoPlayerEntitySpawn = DoPlayerEntitySpawn end
    function newDoPlayerEntitySpawn(...)
    end

    function DoPlayerEntitySpawn(...)
        local args = {...}
        local mv = 
        local e = oldDoPlayerEntitySpawn(unpack(args))
        newDoPlayerEntitySpawn(e, mv)
        return e
    end
    --]]
    local ShouldMoveLastProp = false
    local LastMV = nil
    hook.Add("PlayerSpawnedProp", CurrentFilePath .. "SetPosNewProps", function(ply, model, ent)
        if not ShouldMoveLastProp then return end
        --
        print("YEAH!")
        --ent:SetPos(GetvFlushPoint(GetSpawnTrace(ply, ent, LastMV), ent))
        print(ply.LastMV)
        timer.Simple(0, function()
            local tr = util.TraceHull({
                start = ply:GetPos() + Vector(0, 0, 20),
                endpos = ply:GetPos(),
                maxs = ply:OBBMaxs(),
                mins = ply:OBBMins(),
                filter = ply
            })

            print(tr.Entity)
            --if tr.Entity == ent and not tr.AllSolid then
            print("YESSSS")
            print(tr.HitPos)
            print(ply:GetPos())
            --ply:SetPos(tr.HitPos)
            ply:SetPos(tr.HitPos)
            --end
            ply.LastMV = nil
        end)

        ent:SetPos(GetvFlushPoint(GetSpawnTrace(ply, ent), ent))
        ShouldMoveLastProp = false
    end)

    local reusable_tbl = {}
    hook.Add("SetupMove", "spawnprops", function(ply, mv, cmd)
        if not ply.spawnQueue then return end
        local success, err
        for _, modelname in ipairs(ply.spawnQueue) do
            --reusable_tbl[1] = modelname
            --success, err = pcall(GMODSpawnProp, ply, reusable_tbl, mv)
            --if not success then ErrorNoHaltWithStack(err) end
            ShouldMoveLastProp = true
            print(mv, "ehey")
            ply.LastMV = mv
            success, err = pcall(GMODSpawnProp, ply, modelname, 1, "")
            if not success then ErrorNoHaltWithStack(err) end
        end

        ply.spawnQueue = {}
    end)
end

hook.Remove("Think", "DrawPropOBBCrosses")
