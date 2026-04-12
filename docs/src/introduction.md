# Welcome to the KissMP Documentation!

KissMP is a high-performance, open-source multiplayer mod for BeamNG.drive.

As BeamNG does not natively support multiplayer network synchronisation, KissMP achieves this by using three separate components working together:

1. **The Client Mod (`KISSMultiplayer.zip`):** A standard BeamNG mod containing the user interface and Lua code that tracks vehicle physics and positions.
2. **The Bridge:** A lightweight local background application. BeamNG's Lua engine cannot make complex external network connections, so the Bridge acts as a secure proxy, connecting your game to the internet using QUIC protocols.
3. **The Server:** A standalone application that tracks all connected players, synchronises vehicle physics and handles custom mods and Lua scripts.

KissMP is actively maintained and continuously evolving, so consider it a work in progress. Feedback, suggestions and bug sightings are openly appreciated through Github issues or in the Discord server.