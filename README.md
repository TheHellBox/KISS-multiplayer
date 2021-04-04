# KissMP
![alt text](https://i.imgur.com/kxocgKD.png)

[KISS](https://en.wikipedia.org/wiki/KISS_principle) Multiplayer mod for BeamNG.drive ([Discord Channel](https://discord.gg/ANPsDkeVVF))

## Main features
- Cross platform, open source & free server written in Rust
- QUIC-based networking (with help of quinn and tokio for async)
- Server list with search and ability to save favorites
- Automatic synchronization of your mods with the server
- High overall performance which allows for more players to play on the same server
- Low traffic usage
- Lag compensation
- In-game text
- In-game **voice chat**
- Lua API for creating server-side addons
- Cross platform bridge (less Wine applications for Linux users)
- Builtin server list

## Contributors
- Dummiesman (most of the UI code, huge contributions to the core code)

## Installation
- Drop KISSMultiplayer.zip into the /Documents/BeamNG.drive/mods folder. The archive name HAS to be named KISSMultiplayer.zip in order 
for the mod to work.
- You can drop the bridge .exe file to any place you want.

## Usage
- Launch the bridge. If everything is correct, it'll show you the text "Bridge is running!" in the console window.
- Launch the game. After the launch, you should be able to see server list and chat windows. Select a server in the server list
and hit the connect button.
- Enjoy playing!

## Server installation
Just launch the kissmp-server for your platform and you're ready to go.
More detailed guide on server configuration can be found on this [wiki page](https://github.com/TheHellBox/KISS-multiplayer/wiki/Server-installation).


## Building
First, download and install a [Rust toolchain](https://rustup.rs/)

After, clone the repository
```sh
git clone https://github.com/TheHellBox/KISS-multiplayer.git
cd KISS-multiplayer
```
Now you are ready to build server and bridge.
### Server
```sh
cd kissmp-server
cargo run -p kissmp-server --release
```
or
```sh
cargo run -p kissmp-server --release
```
### Bridge
```sh
cd kissmp-bridge
cargo run --release
```
or
```sh
cargo run -p kissmp-bridge --release
```
