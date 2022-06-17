# Time Sync
This example shows the basics of syncing time

Some utility and helper functions
```lua
-- Created by Dummiesman
-- this function is used to parse a command into its parts, it also makes sure it's safe.
local function cmd_parse(cmd)
    local parts = {}
    local len = cmd:len()
    local escape_sequence_stack = 0
    local in_quotes = false

    local cur_part = ""
    for i=1,len,1 do
        local char = cmd:sub(i,i)
        if escape_sequence_stack > 0 then escape_sequence_stack = escape_sequence_stack + 1 end
        local in_escape_sequence = escape_sequence_stack > 0
        if char == "\\" then
            escape_sequence_stack = 1
        elseif char == " " and not in_quotes then
            table.insert(parts, cur_part)
            cur_part = ""
        elseif char == '"'and not in_escape_sequence then
            in_quotes = not in_quotes
        else
            cur_part = cur_part .. char
        end
        if escape_sequence_stack > 1 then escape_sequence_stack = 0 end
    end
    if cur_part:len() > 0 then
        table.insert(parts, cur_part)
    end
    return parts
end

-- variables
local time = {
    hour = 12,
    minute = 0,
    second = 0
}

-- this is a simple helper function to set the time for a client
local function set_time(client, time)
    client:sendLua("extensions.core_environment.setTimeOfDay({time = " .. time .. "})")
end

-- this function converts hour, min, sec to game time
local function convert_time(h, m, s)
    -- create variables for the time, the arguments are optional because we also want to use this function in "on_chat"
    local hour = h or time.hour -- h or time.hour, if h is not set then it will use time.hour.
    local minute = m or time.minute -- same goes for this one and the one below.
    local second = s or time.second -- screw it, here's another comment for ya.

    -- do the good ol' time conversion so the same is happy with us
    return (((hour * 3600 + minute * 60 + second) / 86400) + 0.5) % 1
end

local function on_chat(client_id, message)
    client = connections[client_id]

    -- split the message by spaces
    local args = cmd_parse(message, " ")
    if args[1] ~= "/set_time" then return end

    -- we have the time command!
    local time_args = {}
    for num in string.gmatch(args[2], "[^:]+") do
        table.insert(time_args, tonumber(num))
    end
    
    time.hour = tonumber(time_args[1]) or time.hour
    time.minute = tonumber(time_args[2]) or time.minute
    time.second = tonumber(time_args[3]) or time.second

    local game_time = convert_time(time.hour, time.minute, time.second)
    for _, client in pairs(connections) do
        set_time(client, game_time)
    end

    print("Time set to " .. time.hour .. ":" .. time.minute .. ":" .. time.second)
    return ""
end

local last_time = 0
local function on_tick()
    -- update the time every second
    if os.time() - last_time > 1 then
        time.second = time.second + 1

        -- if the second is 60, then we need to reset it to 0 and increment the minute
        if time.second == 60 then
            time.second = 0
            time.minute = time.minute + 1

            -- if the minute is 60, then we need to reset it to 0 and increment the hour
            if time.minute == 60 then
                time.minute = 0
                time.hour = time.hour + 1

                -- if the hour is 24, then we need to reset it to 0. unless you want to have 25 hours in a day 🤔
                if time.hour == 24 then
                    time.hour = 0
                end
            end
        end
        last_time = os.time()

        -- update the time for all clients
        local time = convert_time()
        for _, client in pairs(connections) do
            set_time(client, time)
        end
    end
end

-- we now need to register the hooks in order for it to work
hooks.register("OnChat", "on_chat", on_chat)
hooks.register("Tick", "on_tick", on_tick)

-- if you're wondering why we don't use "OnPlayerConnected", it's because this is called when they've not actually loaded in so it won't work.
```

There you have it! A fully functional time sync for your server, enjoy!