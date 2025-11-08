#[recursion_limit = "1024"]
use ipnetwork::Ipv4Network;
use quinn::IdleTimeout;
use shared::vehicle;

pub mod config;
pub mod events;
pub mod file_transfer;
pub mod incoming;
pub mod lua;
pub mod outgoing;
pub mod server_vehicle;

use incoming::IncomingEvent;
use server_vehicle::*;
use shared::{ClientInfoPrivate, ClientInfoPublic, ServerCommand};
use vehicle::*;

use anyhow::{Context, Error};
use futures::FutureExt;
use futures::{select, StreamExt, TryStreamExt};
use log::{error, info, warn, debug};
use std::collections::HashMap;
use std::convert::TryFrom;
use std::net::{IpAddr, Ipv4Addr, SocketAddr, UdpSocket};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;
use tokio_stream::wrappers::{IntervalStream, ReceiverStream};

#[derive(Clone)]
pub struct Connection {
    pub conn: quinn::Connection,
    pub ordered: mpsc::Sender<ServerCommand>,
    pub unreliable: mpsc::Sender<ServerCommand>,
    pub client_info_private: ClientInfoPrivate,
    pub client_info_public: ClientInfoPublic,
}

impl std::fmt::Debug for Connection {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Connection")
            .field("client_info", &self.client_info_private)
            .finish()
    }
}

impl Connection {
    pub async fn send_chat_message(&mut self, message: String) {
        let _ = self
            .ordered
            .send(ServerCommand::Chat(message.clone(), None))
            .await;
    }
    pub async fn send_player_chat_message(&mut self, message: String, player: u32) {
        let _ = self
            .ordered
            .send(ServerCommand::Chat(message.clone(), Some(player)))
            .await;
    }
    pub async fn send_lua(&mut self, lua: String) {
        let _ = self.ordered.send(ServerCommand::SendLua(lua.clone())).await;
    }
}

pub struct Server {
    connections: HashMap<u32, Connection>,
    vehicles: HashMap<u32, Vehicle>,
    // Client ID, game_id, server_id
    vehicle_ids: HashMap<u32, HashMap<u32, u32>>,
    chunk_buffers: HashMap<u32, HashMap<u32, Vec<String>>>,  // client_id -> (total_chunks -> chunks)
    reqwest_client: reqwest::Client,
    name: String,
    description: String,
    map: String,
    tickrate: u8,
    max_players: u8,
    max_vehicles_per_client: u8,
    port: u16,
    show_in_list: bool,
    lua: rlua::Lua,
    lua_watcher: notify::RecommendedWatcher,
    lua_watcher_rx: std::sync::mpsc::Receiver<notify::DebouncedEvent>,
    lua_commands: std::sync::mpsc::Receiver<lua::LuaCommand>,
    server_identifier: String,
    upnp_enabled: bool,
    upnp_port: Option<u16>,
    public_address: Option<String>,
    mods: Option<Vec<String>>,
    tick: u64,
}

impl Server {
    pub fn from_config(config: config::Config) -> Self {
        let (lua, receiver) = lua::setup_lua();
        let (watcher_tx, watcher_rx) = std::sync::mpsc::channel();
        let lua_watcher =
            notify::Watcher::new(watcher_tx, std::time::Duration::from_secs(2)).unwrap();
        Self {
            connections: HashMap::with_capacity(8),
            reqwest_client: reqwest::Client::new(),
            vehicles: HashMap::with_capacity(64),
            vehicle_ids: HashMap::with_capacity(64),
            chunk_buffers: HashMap::new(),
            name: config.server_name,
            description: config.description,
            map: config.map,
            tickrate: config.tickrate,
            port: config.port,
            upnp_port: None,
            max_players: config.max_players,
            max_vehicles_per_client: config.max_vehicles_per_client,
            show_in_list: config.show_in_server_list,
            lua: lua,
            lua_watcher,
            lua_watcher_rx: watcher_rx,
            lua_commands: receiver,
            server_identifier: config.server_identifier,
            upnp_enabled: config.upnp_enabled,
            public_address: None,
            mods: config.mods,
            tick: 0,
        }
    }
    pub async fn run(
        mut self,
        enable_lua: bool,
        destroyer: tokio::sync::oneshot::Receiver<()>,
        setup_result: Option<tokio::sync::oneshot::Sender<ServerSetupResult>>,
    ) {
        let addr = SocketAddr::new(IpAddr::V4(Ipv4Addr::new(0, 0, 0, 0)), self.port);
        info!("Server is starting on {}", addr);
        if self.upnp_enabled {
            if let Some(port) = upnp_pf(self.port) {
                info!("uPnP mapping succeeded. Port: {}", port);
                self.upnp_port = Some(port);
                info!("Fetching public IP address...");
                let socket = UdpSocket::bind(&addr).unwrap();
                socket.connect("kissmp.online:3691");
                let mut i = 0;
                while i < 5 {
                    let _ = socket.send(b"hi");
                    let mut buf = [0; 1024];
                    let r = socket.recv(&mut buf);
                    if let Ok(n) = r {
                        let addr = String::from_utf8(buf[0..n].to_vec()).unwrap();
                        info!("IP: {}", addr);
                        self.public_address = Some(addr);
                        break;
                    } else {
                        warn!("Failed to receive public IP, retrying...");
                    }
                    i += 1;
                }
            } else {
                warn!("uPnP mapping failed.");
            }
        }
        let mut ticks = IntervalStream::new(tokio::time::interval(
            std::time::Duration::from_secs(1) / self.tickrate as u32,
        ))
        .fuse();
        let mut send_info_ticks =
            IntervalStream::new(tokio::time::interval(std::time::Duration::from_secs(5))).fuse();

        let (cert, key) = generate_certificate();

        let mut server_crypto = rustls::ServerConfig::builder()
            .with_safe_defaults()
            .with_no_client_auth()
            .with_single_cert(vec![cert], key)
            .unwrap();
        server_crypto.alpn_protocols.push(b"kissmp".to_vec());

        let mut server_config = quinn::ServerConfig::with_crypto(Arc::new(server_crypto));

        let mut transport = quinn::TransportConfig::default();
        transport.max_idle_timeout(Some(
            IdleTimeout::try_from(std::time::Duration::from_secs(60)).unwrap(),
        ));
        transport.keep_alive_interval(Some(std::time::Duration::from_secs(2)));
        server_config.transport = std::sync::Arc::new(transport);

        let (_endpoint, incoming) = quinn::Endpoint::server(server_config, addr).unwrap();
        info!("Server is listening on {}", addr);

        let (client_events_tx, client_events_rx) = mpsc::channel(128);
        let mut client_events_rx = ReceiverStream::new(client_events_rx).fuse();
        let mut incoming = incoming
            .inspect(|_conn| info!("Client is trying to connect to the server"))
            .buffer_unordered(16);

        let stdin = tokio::io::stdin();
        let reader =
            tokio_util::codec::FramedRead::new(stdin, tokio_util::codec::LinesCodec::new());
        let mut destroyer = destroyer.fuse();
        let mut reader = reader.fuse();
        if enable_lua {
            self.load_lua_addons();
            let _ = self.update_lua_connections();
        }
        info!("Server is running!");
        if let Some(setup_result) = setup_result {
            setup_result.send(ServerSetupResult {
                addr: addr.to_string(),
                port: self.port,
                is_upnp: self.upnp_port.is_some(),
            });
        }
        'main: loop {
            select! {
                _ = ticks.next() => {
                    self.tick().await;
                },
                _ = send_info_ticks.next() => {
                    let _ = self.send_server_info().await;
                    self.send_players_info().await;
                }
                conn = incoming.select_next_some() => {
                    if let Ok(conn) = conn {
                        info!("New connection attempt from {:?}", conn.connection.remote_address());
                        if let Err(e) = self.on_connect(conn, client_events_tx.clone()).await {
                            warn!("Client has failed to connect to the server: {}", e);
                        }
                    } else {
                        warn!("Failed to accept incoming connection: {:?}", conn);
                    }
                },
                stdin_input = reader.next() => {
                    if let Some(stdin_input) = stdin_input {
                        self.on_console_input(stdin_input.unwrap_or(String::from(""))).await;
                    }
                },
                e = client_events_rx.select_next_some() => {
                    self.on_client_event(e.0, e.1).await;
                },
                _ = destroyer => {
                    info!("Server shutdown requested. Shutting down");
                    break 'main;
                },
            }
        }
    }
    async fn send_players_info(&mut self) {
        let mut client_infos = vec![];
        for (_, client) in &self.connections {
            client_infos.push(client.client_info_public.clone());
        }
        for (_, client) in &mut self.connections {
            for client_info in &client_infos {
                let _ = client
                    .ordered
                    .send(ServerCommand::PlayerInfoUpdate(client_info.clone()))
                    .await;
            }
        }
    }
    async fn send_server_info(&self) -> anyhow::Result<()> {
        if (!self.show_in_list) {
            return Ok(());
        }
        let server_info = serde_json::json!({
            "name": self.name.clone(),
            "player_count": self.connections.len(),
            "max_players": self.max_players,
            "description": self.description.clone(),
            "map": self.map.clone(),
            "port": self.port,
            "version": shared::VERSION
        })
        .to_string();

        let client = self.reqwest_client.clone();
        tokio::spawn(async move {
            let _ = client
                .post("http://kissmp.online:3692")
                .body(server_info)
                .send()
                .await;
        });

        Ok(())
    }

    async fn on_connect(
        &mut self,
        mut new_connection: quinn::NewConnection,
        client_events_tx: mpsc::Sender<(u32, IncomingEvent)>,
    ) -> anyhow::Result<()> {
        info!("Connection handshake starting...");

        info!("Connection stats: {:?}", new_connection.connection.stats());

        // timeout for receiving client info
        let client_info = tokio::time::timeout(
            std::time::Duration::from_secs(5),
            async {
                let mut stream = new_connection.uni_streams.try_next().await?;
                if let Some(stream) = &mut stream {
                    info!("Receiving client info stream...");
                    let mut buf = [0; 4];
                    stream.read_exact(&mut buf[0..4]).await?;
                    let len = u32::from_le_bytes(buf).min(16384) as usize;
                    info!("Expected client info length: {}", len);
                    let mut buf: Vec<u8> = vec![0; len];
                    stream.read_exact(&mut buf).await?;
                    info!("Received client info bytes: {} bytes", buf.len());
                    Ok(buf)
                } else {
                    Err(anyhow::Error::msg("No client info stream received"))
                }
            }
        ).await;

        let connection = new_connection.connection.clone();
        if self.connections.len() >= self.max_players.into() {
            connection.close(0u32.into(), b"Server is full");
            return Err(anyhow::Error::msg("Server is full"));
        }
        // Should be strong enough for our targets. TODO: Check for collisions anyway
        let id = rand::random::<u32>();

        info!("Client connected with ID: {}", id);

        let (ordered_tx, ordered_rx) = mpsc::channel(128);
        let (unreliable_tx, unreliable_rx) = mpsc::channel(128);
        async fn receive_client_data(
            new_connection: &mut quinn::NewConnection,
        ) -> anyhow::Result<ClientInfoPrivate> {
            let mut stream = new_connection.uni_streams.try_next().await?;
            if let Some(stream) = &mut stream {
                info!("Attempting to receive client info...");
                let mut buf = [0; 4];
                stream.read_exact(&mut buf[0..4]).await?;
                let len = u32::from_le_bytes(buf).min(16384) as usize;
                info!("Client info length: {}", len);
                let mut buf: Vec<u8> = vec![0; len];
                stream.read_exact(&mut buf).await?;
                info!("Received raw client info data");
                let info: shared::ClientCommand =
                    bincode::deserialize::<shared::ClientCommand>(&buf)?;
                info!("Deserialized client info");
                info!("[DEBUG] Received client command: {:?}", info);
                if let shared::ClientCommand::ClientInfo(info) = info {
                    info!("Got client info: {:?}", info);
                    Ok(info)
                } else {
                    Err(anyhow::Error::msg("Failed to fetch client info - wrong command type"))
                }
            } else {
                Err(anyhow::Error::msg("Failed to fetch client info - no stream"))
            }
        }

        let connection_clone = connection.clone();
        // Receiver
        tokio::spawn(async move {
            info!("[CONNECT_TASK] Starting connection task for {}", id);
            let client_info = {
                if let Ok(client_data) = receive_client_data(&mut new_connection).await {
                    client_data
                } else {
                    connection_clone.close(
                        0u32.into(),
                        b"Failed to fetch client info. Client version mismatch?",
                    );
                    return;
                }
            };
            if client_info.client_version != shared::VERSION {
                connection_clone.close(
                    0u32.into(),
                    format!(
                        "Client version mismatch.\nClient version: {:?}\nServer version: {:?}",
                        client_info.client_version,
                        shared::VERSION
                    )
                    .as_bytes(),
                );
                return;
            }
            let client_info_public = ClientInfoPublic {
                name: client_info.name.clone(),
                id: id,
                current_vehicle: None,
                ping: 0,
                hide_nametag: false,
            };
            let client_connection = Connection {
                conn: connection_clone.clone(),
                ordered: ordered_tx,
                unreliable: unreliable_tx,
                client_info_private: client_info,
                client_info_public: client_info_public,
            };
            client_events_tx
                .send((id, IncomingEvent::ClientConnected(client_connection)))
                .await
                .unwrap();
            info!("[CONNECT_TASK] Starting drive_receive for {}", id);
            if let Err(_e) = Self::drive_receive(
                id,
                new_connection.uni_streams,
                new_connection.datagrams,
                client_events_tx.clone(),
            )
            .await
            {
                let _ = client_events_tx
                    .send((id, IncomingEvent::ConnectionLost))
                    .await;
            }
        });

        let server_info =
            bincode::serialize(&shared::ServerCommand::ServerInfo(shared::ServerInfo {
                name: self.name.clone(),
                player_count: self.connections.len() as u8,
                client_id: id,
                map: self.map.clone(),
                tickrate: self.tickrate,
                max_vehicles_per_client: self.max_vehicles_per_client,
                mods: list_mods(self.mods.clone()).unwrap().0,
                server_identifier: self.server_identifier.clone(),
            }))
            .unwrap();
        // Sender
        tokio::spawn(async move {
            let mut stream = match connection.open_uni().await {
                Ok(stream) => stream,
                Err(e) => {
                    error!("Failed to open server info stream: {}", e);
                    return;
                }
            };
            info!("[DEBUG] Sender task started for {}", id);
            if let Err(e) = send(&mut stream, &server_info).await {
                error!("Failed to send server info: {}", e);
                return;
            }
            info!("[DEBUG] Server info sent to {}", id);
            // debug!("Sent server info to client");

            // Start driving connection
            if let Err(e) = Self::drive_send(connection, ordered_rx, unreliable_rx).await {
                error!("Connection drive_send error: {}", e);
            }
        });
        Ok(())
    }

    async fn drive_send(
        connection: quinn::Connection,
        ordered: mpsc::Receiver<ServerCommand>,
        unreliable: mpsc::Receiver<ServerCommand>,
    ) -> anyhow::Result<()> {
        let mut ordered = ReceiverStream::new(ordered).fuse();
        let mut unreliable = ReceiverStream::new(unreliable).fuse();
        loop {
            select! {
                command = ordered.select_next_some() => {
                    let connection = connection.clone();
                    tokio::spawn(async move {
                        // Kinda ugly and hacky tbh
                        match command {
                            ServerCommand::TransferFile(file) => {
                                //println!("Transfer");
                                let _ = file_transfer::transfer_file(connection.clone(), std::path::Path::new(&file)).await;
                            }
                            _ => {
                                let mut stream = connection.open_uni().await;
                                if let Ok(stream) = &mut stream {
                                    let _ = send(stream, &Self::handle_outgoing_data(command)).await;
                                }
                            }
                        }
                    });
                }
                command = unreliable.select_next_some() => {
                    let data = Self::handle_outgoing_data(command);
                    connection.send_datagram(data.into())?;
                }
                complete => {
                    break;
                }
            }
        }
        Err(anyhow::Error::msg("Disconnected"))
    }

    async fn drive_receive(
        id: u32,
        streams: quinn::IncomingUniStreams,
        datagrams: quinn::Datagrams,
        mut client_events_tx: mpsc::Sender<(u32, IncomingEvent)>,
    ) -> anyhow::Result<()> {
        info!("[DEBUG] Starting drive_receive for {}", id);
        let mut cmds = streams
            .map(|stream| async {
                let mut stream = stream?;
                let mut buf = [0; 4];
                stream.read_exact(&mut buf[0..4]).await?;
                let len = u32::from_le_bytes(buf).min(65536) as usize;
                let mut buf: Vec<u8> = vec![0; len];
                stream.read_exact(&mut buf).await?;
                Ok::<_, Error>(buf)
            })
            .buffered(256)
            .fuse();

        let mut datagrams = datagrams
            .map(|data| async {
                let data: Vec<u8> = data?.to_vec();
                Ok::<_, Error>(data)
            })
            .buffered(256)
            .fuse();

        loop {
            let data = select! {
                data = cmds.try_next() => {
                    if let Some(data) = data? {
                        data
                    }
                    else{
                       return Err(anyhow::Error::msg("Disconnected"))
                    }
                }
                data = datagrams.try_next() => {
                    if let Some(data) = data? {
                        data
                    }
                    else{
                        return Err(anyhow::Error::msg("Disconnected"))
                    }
                }
                complete => break
            };
            let _ = Self::handle_incoming_data(id, data, &mut client_events_tx).await;
        }
        Err(anyhow::Error::msg("Disconnected"))
    }

    async fn tick(&mut self) {
        self.tick += 1;
        for (_, client) in &mut self.connections {
            for (vehicle_id, vehicle) in &self.vehicles {
                if let (Some(transform), Some(electrics), Some(gearbox)) =
                    (&vehicle.transform, &vehicle.electrics, &vehicle.gearbox)
                {
                    let _ = client
                        .unreliable
                        .send(ServerCommand::VehicleUpdate(VehicleUpdate {
                            transform: transform.clone(),
                            electrics: electrics.clone(),
                            gearbox: gearbox.clone(),
                            vehicle_id: vehicle_id.clone(),
                            generation: self.tick,
                            sent_at: 0.0,
                        }))
                        .await;
                }
            }
        }
        self.lua_tick().await.unwrap();
    }

    async fn on_console_input(&self, input: String) {
        self.lua.context(|lua_ctx| {
            let _ = lua::run_hook::<String, ()>(lua_ctx, String::from("OnStdIn"), input);
        });
    }

    fn cleanup(&mut self) {
        info!("Server is shutting down");
        let gateway = igd::search_gateway(Default::default());
        if let Ok(gateway) = gateway {
            if let Some(port) = self.upnp_port {
                let _ = gateway.remove_port(igd::PortMappingProtocol::UDP, port);
            }
        }
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        self.cleanup();
    }
}

fn generate_certificate() -> (rustls::Certificate, rustls::PrivateKey) {
    info!("Generating certificate...");
    let cert = rcgen::generate_simple_self_signed(vec!["kissmp".into()]).unwrap();
    let key = cert.serialize_private_key_der();
    let cert = cert.serialize_der().unwrap();
    (rustls::Certificate(cert), rustls::PrivateKey(key))
}

async fn send(stream: &mut quinn::SendStream, message: &[u8]) -> anyhow::Result<()> {
    stream.write_all(&(message.len() as u32).to_le_bytes()).await?;
    stream.write_all(message).await?;
    stream.finish().await?;
    Ok(())
}

pub fn list_mods(
    mods: Option<Vec<String>>,
) -> anyhow::Result<(Vec<(String, u32)>, Vec<std::path::PathBuf>)> {
    let mut paths = vec![];

    if let Some(mods) = mods {
        for path in mods {
            paths.push(std::path::PathBuf::from(&path));
        }
    } else {
        let mods_path = std::path::Path::new("./mods/");
        if !mods_path.exists() {
            std::fs::create_dir(mods_path).unwrap();
        }

        for entry in std::fs::read_dir(mods_path)? {
            let path = entry.unwrap().path();
            if let Some(extension) = path.extension() {
                if extension.to_string_lossy().to_lowercase() == "zip" {
                    paths.push(path);
                }
            }
        }
    }

    let mut result = vec![];
    let mut raw = vec![];
    for path in paths {
        let mut path = path.clone();
        if path.is_dir() {
            continue;
        }
        if !path.exists() {
            #[cfg(not(unix))]
            continue;
            #[cfg(unix)]
            {
                use std::path::{Path, PathBuf};
                use steamlocate::SteamDir;

                info!("Could not find {:?}, must be inside a Proton prefix", path);
                let r: anyhow::Result<PathBuf> = {
                    Ok(SteamDir::locate()
                        .context("Could not find Steam installation")?
                        .app(&284160)
                        .context("Could not find BeamNG.Drive installation")?
                        // /steamapps/common/BeamNG.drive/
                        .path
                        // /steamapps/common
                        .parent()
                        .context("Could not navigate to steamapps/common")?
                        // /steamapps
                        .parent()
                        .context("Could not navigate to steamapps")?
                        .join(Path::new("compatdata/284160/pfx/drive_c/"))
                        .join(
                            path.to_str()
                                .unwrap()
                                .to_string()
                                .replace(r#"C:\"#, "")
                                .replace(r#"\"#, "/"),
                        ))
                };
                match r {
                    Ok(p) => {
                        if (!p.exists()) {
                            error!("Mod file {:?} not found", p);
                            continue;
                        }
                    }
                    Err(e) => {
                        error!("{}", e);
                        continue;
                    }
                }
            }
        }
        let file_name = path.file_name().unwrap().to_str().unwrap().to_string();
        let file = std::fs::File::open(path.clone())?;
        let metadata = file.metadata()?;
        result.push((file_name, metadata.len() as u32));
        raw.push(path);
    }
    Ok((result, raw))
}

#[cfg(not(windows))]
fn get_bind_addr() -> Result<SocketAddr, std::io::Error> {
    Ok(([0, 0, 0, 0], 0).into())
}

#[cfg(windows)]
// from https://github.com/jakobhellermann/ssdp-client/blob/776c3576ab43efb62b5e24ee768c296a62b22b12/src/search.rs#L44
fn get_bind_addr() -> Result<SocketAddr, std::io::Error> {
    // Windows 10 is multihomed so that the address that is used for the broadcast send is not guaranteed to be your local ip address, it can be any of the virtual interfaces instead.
    // Thanks to @dheijl for figuring this out <3 (https://github.com/jakobhellermann/ssdp-client/issues/3#issuecomment-687098826)
    let any: SocketAddr = ([0, 0, 0, 0], 0).into();
    let socket = UdpSocket::bind(any)?;
    let googledns: SocketAddr = ([8, 8, 8, 8], 80).into();
    let _ = socket.connect(googledns);
    let bind_addr = socket.local_addr()?;

    Ok(bind_addr)
}

pub fn upnp_pf(port: u16) -> Option<u16> {
    let bind_addr = match get_bind_addr() {
        Ok(addr) => addr,
        Err(_error) => ([0, 0, 0, 0], 0).into(),
    };

    let opts = igd::SearchOptions {
        timeout: Some(Duration::from_secs(10)),
        bind_addr: bind_addr,
        ..Default::default()
    };

    match igd::search_gateway(opts) {
        Ok(gateway) => {
            let ifs = match ifcfg::IfCfg::get() {
                Ok(ifs) => ifs,
                Err(e) => {
                    error!("could not get interfaces: {}", e);
                    return None;
                }
            };

            let mut valid_ips = Vec::new();
            for interface in ifs {
                for iface_addr in interface.addresses.iter() {
                    match iface_addr.mask {
                        Some(SocketAddr::V4(ipv4_mask)) => {
                            let ipv4_addr = match iface_addr.address {
                                Some(SocketAddr::V4(ipv4_addr)) => ipv4_addr,
                                _ => continue,
                            };

                            if ipv4_addr.ip().is_private() {
                                valid_ips.push(ipv4_addr);
                            } else {
                                continue;
                            }
                        }
                        // v6 Addresses are not compatible with uPnP
                        _ => continue,
                    }
                }
            }

            info!(
                "uPnP: We are going to try the following IPs: {:#?}",
                valid_ips
            );

            if valid_ips.is_empty() {
                error!("uPnP: No interfaces have a valid IP.");
                return None;
            }

            for mut ip in valid_ips {
                ip.set_port(port);
                info!("uPnP: Trying {}", ip);
                match gateway.add_port(
                    igd::PortMappingProtocol::UDP,
                    port,
                    SocketAddr::V4(ip),
                    0,
                    "KissMP Server",
                ) {
                    Ok(()) => return Some(port),
                    Err(e) => match e {
                        igd::AddPortError::PortInUse => {
                            gateway.remove_port(igd::PortMappingProtocol::UDP, port);
                            gateway.add_port(
                                igd::PortMappingProtocol::UDP,
                                port,
                                SocketAddr::V4(ip),
                                0,
                                "KissMP Server",
                            );
                            return Some(port);
                        }
                        _ => {
                            error!("uPnP Error: {:?}", e);
                        }
                    },
                }
            }
            return None;
        }
        Err(e) => {
            error!("uPnP: Failed to find gateway: {}", e);
            None
        }
    }
}
