# Installing Mods and Addons
## Mods
Mods add additional content to the game and are downloaded for all players connecting to the server.
A mod could for example add a new level or vehicle.

#### Installation
Your server will automatically create a `mods` folder after you run it, in there, simply place all of the mods you want your players to download when they join your server.

If you prefer the speed of pre-downloading your servers mods through an external service like Google Drive, simply put your pre-downloaded mods into the `kissmp_mods` folder.\
The `kissmp_mods` folder can be found in the same directory as your BeamNGs mods folder.

## Addons
Addons are scripts that run on the server and are not downloaded to any players.\
With addons, servers are able to do all kinds of things (like gamemodes, commands, etc).\

If you would like to get started with creating Addons for KissMP, see [Server side Lua API](../srv_lua/lua_api.html).\
A community mantained collection of addons is available [here](https://github.com/AsciiJakob/Awesome-KissMP).

#### Installation
Just like with the `mods` folder, the `addons` folder is created automatically by your server.\
Most of the time you should just be able to drag addons into your addons folder, but if that doesn't work, make sure that the folder structure matches the structure below.\
KissMP addons use `main.lua` as their entrypoint and addons should follow the structure of:\
`/addons/ADDON_NAME/main.lua`