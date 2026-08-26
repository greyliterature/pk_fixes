This script will (eventually) fix multiple issues with propspawn when it comes to Propkill, and also adds some things (1 thing currently). <br/>
Currently it only has 1 fix. <br/>
I had other fixes in the script, but those have been moved to experimental-branch, since they became more complex (and broken) than I had expected. <br/>
Iced Coffee had the original idea for these fixes, as well as most of the code, I just wanted to implement it in a different way that would work for general sandbox servers <br/>
Iced Coffee's version: https://gist.github.com/IcedCoffeee/971abeec986e2786ce05f4dee0a17473 <br/>

# Fixes: 
## pk_spawnfix
Whether or not to enable spawn-fix for yourself. <br/>
Tries to fix propspawn issue where spawning props on slopes / walls will not spawn directly under the crosshair. </br>

<br/>
Enabled client-side by Convar pk_spawnfix (default=0) <br/>
Allowed server-side by Convar pk_sv_enable_spawnfix (default=0), and <br/>

## pk_tryfix: 
Whether or not to disable TryFixPropPosition() from running by gm_spawn_pk. <br/>
TryFixPropPosition() is a flawed function that tries to make the prop spawn inside the world (?), but usually it just makes prop spawning more annoying and sometimes causes props to spawn in other rooms / the other side of walls.

<br/>
Enabled server-side by Convar pk_sv_enable_tryfix (default=1)
## pk_grabfix: 
Whether or not to enable grab-fix for yourself. <br/>
Tries to fix propspawn issue where grabbing props in air / at high velocity is unreliable <br/>

<br/>
Enabled client-side by Convar pk_grabfix (default=1) <br/>

> [!NOTE]
> Problem this solves: <br/>
> By default gm_spawn is not aware of the player's predicted position (?). <br/>
> By blocking the player from running gm_spawn (if they have pk_grabfix enabled), we can force the player to run gm_spawn_pk instead. <br/>
> gm_spawn_pk exists solely to add props to the player's spawnqueue (ply.spawnQueue) <br/>
> This queue is iterated through in the callback of SetUpMove, which runs: <br/>
>    ply.LastMV = mv <br/>
>    success, err = pcall(fixedCCSpawn, ply, "gm_spawn", reusable_tbl) <br/>
> fixedCCSpawn is a local duplicate of the original function that gm_spawn runs, CCSpawn. <br/>
> The only practical and major difference of fixedCCSpawn() and the original CCSpawn() is that fixedCCSpawn() takes into account the player's movedata (declared by SetUpMove as ply.LastMV) <br/>
> This basically means that pk_grabfix defers gm_spawn's CCSpawn() until SetUpMove is run, so that the entity spawn traces are run with accurate data of where the player thinks they are (?). <br/>

> [!IMPORTANT]
> Limitations: <br/>
> This does not reliably work if the player is looking around between the angles of pitch -0.25 0.25 (possibly a bit more) <br/>
> Also does not reliably work with very small props (like moped wheel)

# Additions:
## pk_spawndist:
Controls the distance you spawn props at. <br/>
<br/>
Changed client-side by Convar pk_spawndist (default=2048) <br/>
Allowed server-side by Convar pk_sv_spawndist (default=0), and <br/>
Clamped server-side by Convar pk_sv_maxspawndist (default=4096) <br/>

## pk_maxsize
Controls the max size a prop can be until it does no physgun damage <br/>
This is calculated by the prop's bounding radius (distance from bounding box center to furthest bounding box corner) <br/>
This tracks if it was last punted or grabbed by a grav-gun, so it shouldn't affect regular grav-gun propkill <br/>
<br/>
Enabled server-side by Convar pk_sv_enable_maxsize (default=0) <br/>
Changed server-side by Convar pk_sv_maxsize (default=136 [tide's gate size]) <br/>
