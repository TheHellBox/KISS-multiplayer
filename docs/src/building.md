# Building
First, download and install [a Rust toolchain](https://rustup.rs/)

After, clone the KissMP repository
```sh
git clone https://github.com/TheHellBox/KISS-multiplayer.git
cd KISS-multiplayer
```
Now you are ready to build the server and bridge.
## Server
```sh
cd kissmp-server
cargo run --release
```
or
```sh
cargo run -p kissmp-server --release
```
## Bridge
```sh
cd kissmp-bridge
cargo run --release
```
or
```sh
cargo run -p kissmp-bridge --release
```
