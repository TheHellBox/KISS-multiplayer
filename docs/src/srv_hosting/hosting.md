# Hosting
Hosting a server with KissMP is very easy. 

- The server software was included in your download of KissMP, simply extract the "kissmp-server" directory to where you would like to set up your server.
- Run the kissmp-server executable, it will generate a config file that you can edit.
- Edit the config.json file to set the level, player limit, whether it's public, etc.
- That's basically all there is to it.

# How do I connect to my server?
If your server is running on your own PC, connect using 127.0.0.1 as the address. Otherwise, follow the steps below.

# How do others connect to my server?
First of all, make sure that the port specified in your config.json is forwarded ([How To Port Forward - General Guide to Multiple Router Brands](https://www.noip.com/support/knowledgebase/general-port-forwarding-guide/)).

If enabled in your config, your server will show up in the server list and others can just click the Connect button. Otherwise:
- If you're not using any networking software like Hamachi, people connect to your server with your public IP address ([https://www.whatismyip.com](https://www.whatismyip.com/)).
- If you're using networking software like Hamachi, use the IP address assigned to you by that software.

# How do i change the level/map?
To change what level the server is set on, simply specify your desired maps level path in your server configs  `map` field.

The easiest way to get the path of a level is by loading into the level in singeplayer and executing `print(getMissionFilename())` in the console.

If the map is modded, make sure to include it in your servers mods folder. See the instructions below on adding mods.
# How do i add mods or addons to my server?
See [Installing Mods and Addons](mods_and_addons.html).


---


Having issues with setting up your server? Have a look at [Troubleshooting](troubleshooting.html)