# KissMP
![alt text](https://i.imgur.com/kxocgKD.png)

[KISS](https://en.wikipedia.org/wiki/KISS_principle) Multiplayer mod for BeamNG.drive ([Discord Channel](https://discord.gg/ANPsDkeVVF))

## Main features
- Cross platform, open source & free server written in Rust
- QUIC-based networking (with help of quinn and tokio for async)
- Built-in server browser with search and favourites
- Automatic synchronisation of your mods with the server
- High overall performance which allows for more players to play on the same server
- Low traffic usage and lag compensation
- In-game text chat and **voice chat**
- Lua API for creating server-side addons
- Client-side security settings to prevent unwanted scripts or downloads
- Cross-platform, native binaries (Windows, Linux-x86, Linux-ARM)

## Contributors
KissMP was originally created by [**TheHellBox**](https://github.com/TheHellBox); with huge contributions to the core code and UI by [**Dummiesman**](https://github.com/Dummiesman) and to the backend by [**WhiteHusky**](https://github.com/WhiteHusky).

The project is currently led and maintained by [**Vlad**](https://github.com/Vlad118); alongside core developers [**Zeit**](https://github.com/DaddelZeit) (Lua physics and UI), [**Florin**](https://github.com/florinm03) (Lua and support), and other wonderful contributors and testers from the [Discord](https://discord.gg/ANPsDkeVV).

## Repository Structure
If you are looking to contribute to the codebase, here is how the project is organised:

```text
├── .github/             # GitHub Actions workflows
├── docs/                # Markdown documentation files
├── kissmp-bridge/       # Rust source: Local proxy connecting the game to servers
├── kissmp-master/       # Rust source: The master server list backend
├── kissmp-server/       # Rust source: The dedicated multiplayer server
├── KISSMultiplayer/     # Lua/UI source: The BeamNG.drive client mod
├── shared/              # Rust source: Shared networking protocols and structs
├── Cargo.toml           # Rust workspace configuration
└── README.md
```

## Release Structure

When downloading a compiled release from the [Releases page](https://github.com/TheHellBox/KISS-multiplayer/releases/latest), the zip file contains the following structure. You only need the OS folder matching your system and the mod zip.

```text
KissMP_vX.X.X.zip
├── linux/               # Server and bridge binaries for Linux
├── linux-arm/           # Server binary for ARM hosts
├── windows/             # Server and bridge executables for Windows
└── KISSMultiplayer.zip  # The client mod (Place in your BeamNG mods folder)
```

## Installation
Make sure to use the latest version from the [Releases page](https://github.com/TheHellBox/KISS-multiplayer/releases/latest).
- Drop `KISSMultiplayer.zip` into your BeamNG user `mods` folder (default on Windows: `%LOCALAPPDATA%\BeamNG\BeamNG.drive\current\mods`). The archive *has* to be named `KISSMultiplayer.zip` for the mod to work.
- Extract and drop the bridge/server `.exe` files anywhere you want.

## Usage
1. Launch the bridge. If everything is correct, it will say "Bridge is running!" in the console.
2. Launch the game. You should be able to open the KissMP UI, see the server list and hit connect.
3. Enjoy playing!

## Hosting a server
If you are hosting and connecting on the same PC:
1. Run the bridge and the server executables.
2. In the game, select Direct Connect and type `127.0.0.1`.

For a friend to connect over the internet:
1. Ensure they have access to your network (via port-forwarding port `3698` UDP; a VPN like Hamachi/Tailscale; or any other means).
2. Ensure you have allowed the server through your Windows or Linux Firewall.
3. They launch the bridge, open the game and Direct Connect using your public/VPN IPv4 address.

More detailed guides on server configuration and addons can be found on our [Docs](https://github.com/TheHellBox/KISS-multiplayer/blob/master/docs/src/SUMMARY.md).

## Building
First, download and install a [Rust toolchain](https://rustup.rs/)

After, clone the repository
```sh
git clone https://github.com/TheHellBox/KISS-multiplayer.git
cd KISS-multiplayer
```
Now you are ready to build the server and bridge.
### Server
```sh
cd kissmp-server
cargo run --release
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
