# Introduction
**KissMP** server uses **lua** as its language for creating addons.

Keep in mind that the server in KissMP doesn't do much, most of the stuff is done by clients.
Server just passes some data between clients.

However, that doesn't mean that the server is limited to what it's able to do. You can still control quite a lot of things, mostly by dictating what clients should do.

For this reason, lots of stuff can be done with the `connection:sendLua()` method. For example, the built in
`vehicle:setPositionRotation` method uses sendLua as its backend.\
You can display UI, messages, modify input and change time just by sending small lua commands.

# Creating an addon
Create new folder in the /addons/ directory with any name. Create a file called `main.lua` in there, this file will get executed when the server starts.

Server also supports hot-reloading, so lua addons will reload automatically when saved without needing to restart the server.