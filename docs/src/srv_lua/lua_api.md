# Introduction
**KissMP** server uses **lua** as language used for creating addons.

Keep in mind that server in KissMP doesn't do much, most of the stuff is done by clients.
Server just passes some data between clients.

However, it doesn't mean that server can't do something. You can still control quite a lot of things,
mostly by dictating clients what they should do.

For this reason, lots of stuff can be done with `connection:sendLua()` command. For example, built in
`vehicle:setPositionRotation` function uses sendLua as backend.
You can display UI, messages, modify input and change time by just sending small lua commands.

# Creating an addon
Create new folder in /addons/ directory with any name. Place `main.lua` file in there, this file will get executed when server starts.

Server also support hot-reloading, so file will reload automatically without need to restart the server
