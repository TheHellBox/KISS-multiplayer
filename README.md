# KissMP
![alt text](https://i.imgur.com/kxocgKD.png)

[KISS](https://en.wikipedia.org/wiki/KISS_principle) Multiplayer mod for BeamNG.drive

# How to use (Linux / WSL):
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

Copy KISSMultiplayer.zip in your game's mod folder, for example, if you have the game installed with proton: `~/.steam/steam/steamapps/compatdata/284160/pfx/drive_c/users/steamuser/My Documents/BeamNG.drive/mods/`

## Play:
First, download and install a [Rust toolchain](https://rustup.rs/)

After you have installed the rust toolchain, compile the bridge and run it.
```sh
cd kissmp-bridge/
cargo run --release
```
Then open the game with the mod installed
/
