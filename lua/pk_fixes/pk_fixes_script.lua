--[[
    heavily based on iced coffee's pk fixes https://gist.github.com/IcedCoffeee/971abeec986e2786ce05f4dee0a17473 
--]]
local CurrentFilePath = debug.getinfo(function() end).short_src
--[[----------------------------------------------------------------
        convars
------------------------------------------------------------------]]
local function StandardizeConVarValue(convarvalue)
	convarvaluetonumber = tonumber(convarvalue) -- :GetInt() :GetFloat()
	convarvalue = convarvaluetonumber or convarvalue
	return convarvalue
end

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
		return StandardizeConVarValue(ConvarCache[convarname])
	end

	-- this hopefully will never happen, the cache hopefully will always work
	local convarvalue = GetConVar(convarname):GetString()
	return StandardizeConVarValue(convarvalue)
end

if CLIENT then
	CreateClientConVar_Cached("pk_grabfix", "0", true, true, "Whether or not to enable grabfix for yourself")
	CreateClientConVar_Cached("pk_spawndist", "2048", true, true, "Distance to spawn props")
	CreateClientConVar_Cached("pk_spawnfix", "0", true, true, "Whether or not to enable spawnfix for yourself")
elseif SERVER then
	CreateConVar_Cached("pk_sv_spawndist", "0", FCVAR_ARCHIVE, "Whether or not to allow players to set the distance they spawn props", 0)
	CreateConVar_Cached("pk_sv_maxspawndist", "4096", FCVAR_ARCHIVE, "Max spawn distance for people using pk_spawndist", 0)
	CreateConVar_Cached("pk_sv_enable_maxsize", "0", FCVAR_ARCHIVE, "Whether or not to use value from pk_sv_maxsize", 0)
	CreateConVar_Cached("pk_sv_maxsize", "136", FCVAR_ARCHIVE, "The maximum bounding radius (center to furthest corner) a prop can be to do damage. Used to restrict overly large props (8x8 cubes) from propkill. \nREFERENCE: tide = 136, frige = 49, moped = 28", 0)
	CreateConVar_Cached("pk_sv_enable_tryfix", "1", FCVAR_ARCHIVE, "Whether or not to use TryFixPropPosition in gm_spawn_pk. This is used in the original method for prop spawn positioning, but is flawed (props can spawn across entire walls and be ungrabbable). Recommended to turn this off, unless you really like the legacy gmod behavior.", 0)
	CreateConVar_Cached("pk_sv_enable_spawnfix", "0", FCVAR_ARCHIVE, "Whether or not to allow players to use pk_spawnfix", 0)
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

local ENTMETA = FindMetaTable("Entity")
function ENTMETA:NearestCollisionPoint(origin, direction_vec) -- returns the physgun vector such that hitpos - physgun vector = closest point to which the prop can be moved and be hit by a trace
	-- this fixes ent:NearestPoint() not working with physguns, because the physgun uses the collision mesh for its traces instead of the bounding box (which ent:NearestPoint() uses)
	-- visually: https://files.catbox.moe/wb1hrj.PNG 
	local center = self:GetPos()
	local tocenter = origin - center
	local perp = tocenter - direction_vec * tocenter:Dot(direction_vec)
	local physobj = self:GetPhysicsObject()
	local bestdist = math.huge
	local nearestpos = nil
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

	nearestpos = nearestpos - perp:GetNormalized() * 0.5 -- nudge it towards the trace just by a little bit, helps with precision issues where the client thinks the physgun can grab it, but it can't
	return nearestpos
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
		if GetConVar_Cached("pk_grabfix") ~= 1 and GetConVar_Cached("pk_spawndist") == DefaultSpawnDist then return end
		local alias = input.TranslateAlias(bind)
		if not string.find(alias or bind, "gm_spawn") then return end
		firsttimepressed = not firsttimepressed
		if firsttimepressed == false then return end
		local args = string.Split(alias or bind, " ")
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
		local vStart = ply:GetShootPos()
		local vForward = ply:EyeAngles():Forward() -- Ignores world clicker
		if ply.LastMV and ply:GetInfoNum("pk_grabfix", 0) == 1 then
			local mv = ply.LastMV
			local origin = mv:GetOrigin()
			local eyeheight = ply:GetShootPos().z - ply:GetPos().z
			origin.z = origin.z + eyeheight
			vStart = origin + mv:GetVelocity() / (1 / engine.TickInterval())
			vForward = mv:GetAngles():Forward()
		end

		local trace = {}
		trace.start = vStart
		--
		local PlayerSpawnDist = DefaultSpawnDist
		local pk_spawndist_enabled = GetConVar_Cached("pk_sv_spawndist") == 1
		if pk_spawndist_enabled == true then
			local MaxSpawnDist = GetConVar_Cached("pk_sv_maxspawndist")
			PlayerSpawnDist = math.Clamp(ply:GetInfoNum("pk_spawndist", 2048), 0, MaxSpawnDist)
		end

		trace.endpos = vStart + vForward * PlayerSpawnDist
		trace.filter = {ply, ply:GetVehicle()}
		return util.TraceLine(trace)
	end

	local Coasters = {
		["models/XQM/CoasterTrack/slope_225_2.mdl"] = true,
		["models/XQM/CoasterTrack/slope_225_3.mdl"] = true,
		["models/xqm/coastertrack/slope_225_4.mdl"] = true,
	}
	-- No longer the same method as the legacy vFlushPoint. This now accounts for slopes and collision meshes instead of using bounding boxes
	local function GetvFlushPoint(tr, ent)
		local InOpenAir = tr.Hit == false
		local OnFlatWall = tr.HitNormal.z == 0
		local OnFlatGround = tr.HitNormal.z > 0.996 or tr.HitNormal.z < -0.996 and OnFlatWall == false
		--
		local ply = ent:GetCreator()
		local pk_spawnfix_enabled = GetConVar_Cached("pk_sv_enable_spawnfix") == 1 and ply:GetInfoNum("pk_spawnfix", 0) == 1
		local isModelCoaster = Coasters[ent:GetModel()] == true and OnFlatGround == false and OnFlatWall == false -- coasters work fine on slopes almost no matter what, so whitelist them
		local shouldUseCollisionPoint = pk_spawnfix_enabled == true and InOpenAir == false and OnFlatGround == false and isModelCoaster == false
		local NormalMultiple = tr.HitNormal * 512
		local vFlushPoint = tr.HitPos - NormalMultiple
		vFlushPoint = ((shouldUseCollisionPoint == true) and ent:NearestCollisionPoint(vFlushPoint, tr.Normal)) or ent:NearestPoint(vFlushPoint)
		vFlushPoint = ent:GetPos() - vFlushPoint
		vFlushPoint = tr.HitPos + vFlushPoint
		vFlushPoint = vFlushPoint - tr.Normal * 5 -- move it towards the player so it doesn't spawn inside the slope or wall
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
		local vFlushPoint = GetvFlushPoint(tr, ent)
		ent:SetPos(vFlushPoint)
		ply:SendLua("achievements.SpawnedProp()")
		if GetConVar_Cached("pk_sv_enable_tryfix") == 1 then -- This function is incredibly painful to deal with. Please turn it off.
			TryFixPropPosition(ply, ent, tr.HitPos)
		end
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

--[[----------------------------------------------------------------
    pk_maxsize
------------------------------------------------------------------]]
if SERVER then
	hook.Add("PlayerSpawnedProp", CurrentFilePath .. "|pk_maxsize", function(_, _, ent)
		if GetConVar_Cached("pk_sv_enable_maxsize") ~= 1 then return end
		if ent:BoundingRadius() > tonumber(GetConVar_Cached("pk_sv_maxsize")) then
			ent.pk_RestrictPlayerDamage = true
			return
		end
		return
	end)

	hook.Add("OnPhysgunPickup", CurrentFilePath .. "|pk_maxsize", function(_, ent)
		if not ent.pk_RestrictPlayerDamage then return end
		ent.pk_LastPickedUpByPhysgun = true -- track
	end)

	hook.Add("GravGunOnPickedUp", CurrentFilePath .. "|pk_maxsize", function(_, ent)
		if not ent.pk_RestrictPlayerDamage then return end
		ent.pk_LastPickedUpByPhysgun = nil -- untrack to allow people to grav gun propkill
	end)

	hook.Add("GravGunPunt", CurrentFilePath .. "|pk_maxsize", function(_, ent)
		if not ent.pk_RestrictPlayerDamage then return end
		ent.pk_LastPickedUpByPhysgun = nil -- untrack to allow people to grav gun puntkill
	end)

	hook.Add("EntityTakeDamage", CurrentFilePath .. "|pk_maxsize", function(target, dmginfo)
		if GetConVar_Cached("pk_sv_enable_maxsize") ~= 1 then return end
		if not target:IsPlayer() then return end
		local ent = dmginfo:GetInflictor()
		if ent:GetClass() ~= "prop_physics" then return end
		if not IsValid(ent:GetCreator()) then -- World props can do whatever they want 
			return
		end

		if not IsValid(ent:GetPhysicsAttacker()) then -- If the physicsattacker is invalid the player just got crushed by a falling prop. They should have just dodged it. Too bad. 
			return
		end

		if not ent.pk_LastPickedUpByPhysgun then -- If it was not last picked up by a physgun then it was picked up by a grav gun. Allow grav guns to deal damage like normal 
			return
		end

		dmginfo:SetDamage(0)
		return true
	end)
end
-- todo: 
-- There should be feedback to inform the player that the prop wont do damage somehow.
-- I cannot think of a way that follows basic game design principles to do this.
-- A chatprint on spawn to the player would be the easy way, but it is too ugly. So for now I will not attempt to find a way.
