local function addSpawnFix()
	include("pk_fixes/pk_fixes_script.lua")
end

if SERVER then
	AddCSLuaFile("pk_fixes/pk_fixes_script.lua")
	hook.Add("PostGamemodeLoaded", "spawnfix", addSpawnFix)
	hook.Add("OnReloaded", "spawnfix", addSpawnFix)
elseif CLIENT then
	addSpawnFix()
end
