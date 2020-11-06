# KissMP
![alt text](https://i.imgur.com/kxocgKD.png)

[KISS](https://en.wikipedia.org/wiki/KISS_principle) Multiplayer mod for BeamNG.drive

## Main features:
- Cross platform, open source & free server written on Rust
- QUIC based networking(With help of quinn and tokio for async)
- Server list with search and ability to save favorites
- Automatic synchronization of your mods with the server
- High overall performace of modification, which allows for more players to play at the same server
- Low network traffic usage
- Lag compensation
- In-game text chat(Voice chat is planned!)
- Lua API for creating server-side addons
- Cross platform bridge(Less wine applications for linux users!)
- Built in server list

## Contributiors:
- Dummiesman(Most of the UI code, huge contributions to the core code)

## Installation:
- Drop KISSMultiplayer.zip into the /Documents/BeamNG.drive/mods folder. The archive name HAS to be named KISSMultiplayer.zip in order 
for mod to work
- You can drop the bridge .exe file to any place you want.

## Usage:
- Launch the bridge. If everything is correct, it'll show you the text "Bridge is running!" in a console window
- Launch the game. After the launch, you should be able to see server list and chat windows. Select a server in the server list
and hit connect button
- Enjoy playing!

## Server installation(Windows):
Just launch kissmp-server.exe file and you're ready to go.
More detailed guide on server configuration can be found on this wiki page (Insert link)


## Building:
First, download and install a [Rust toolchain](https://rustup.rs/)

After, clone the repository
```sh
git clone https://github.com/TheHellBox/KISS-multiplayer.git
cd KISSMultiplayer
```
Now you are ready to build server and bridge.
### Server
```sh
cd kissmp-server
cargo run --release
```
### Bridge
```sh
cd kissmp-bridge
cargo run --release
```
