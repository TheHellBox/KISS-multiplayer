# KISS-multiplayer
[KISS](https://en.wikipedia.org/wiki/KISS_principle) Multiplayer mod for BeamNG.drive

# How to use (Linux):
## Download:

```sh
git clone https://github.com/TheHellBox/KISS-multiplayer.git
cd KISS-multiplayer
```

## Mod Installation:
```sh
cd KISSMultiplayer
zip KISSMultiplayer.zip -r *
```

Copy KISSMultiplayer.zip in your game's mod folder, for example `~/.steam/steam/steamapps/compatdata/284160/pfx/drive_c/users/steamuser/My Documents/BeamNG.drive/mods/`

## Play:
First, download and install a Rust toolchain

```sh
cd kissmp-bridge/
cargo run --release
```
Then open the game with the mod installed
