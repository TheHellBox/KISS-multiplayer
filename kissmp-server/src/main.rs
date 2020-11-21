#![recursion_limit = "256"]

pub mod config;
pub mod events;
pub mod file_transfer;
pub mod incoming;
pub mod lua;
pub mod outgoing;
pub mod vehicle;

use incoming::IncomingEvent;
use outgoing::Outgoing;
use vehicle::*;

use anyhow::Error;
use futures::{select, StreamExt, TryStreamExt};
use quinn::{Certificate, CertificateChain, PrivateKey};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::net::{IpAddr, Ipv4Addr, SocketAddr, UdpSocket};
use tokio::sync::mpsc;

const SERVER_VERSION: (u32, u32) = (0, 2);

#[derive(Clone)]
struct Connection {
    pub conn: quinn::Connection,
    pub ordered: mpsc::Sender<Outgoing>,
    pub unreliable: mpsc::Sender<Outgoing>,
    pub client_info: ClientInfo,
}

impl Connection {
    pub async fn send_chat_message(&mut self, message: String) {
        let _ = self.ordered
            .send(Outgoing::Chat(message.clone()))
            .await;
    }
    pub async fn send_lua(&mut self, lua: String) {
        let _ = self.ordered
            .send(Outgoing::SendLua(lua.clone()))
            .await;
    }
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct ClientInfo {
    pub name: String,
    #[serde(skip_deserializing)]
    pub id: u32,
    #[serde(skip_deserializing)]
    pub current_vehicle: u32,
    #[serde(skip_deserializing)]
    pub ping: u32,
    #[serde(skip_serializing)]
    pub secret: String,
     #[serde(skip_serializing)]
    pub client_version: (u32, u32)
}

impl ClientInfo {
    pub fn new(id: u32) -> Self {
        Self {
            id,
            ..Default::default()
        }
    }
    pub fn to_bytes(&self) -> Vec<u8> {
        rmp_serde::encode::to_vec(self).unwrap()
    }
}

impl Default for ClientInfo {
    fn default() -> Self {
        Self {
            name: String::from("Unknown"),
            id: 0,
            current_vehicle: 0,
            ping: 0,
            secret: String::from("Unknown"),
            client_version: SERVER_VERSION
        }
    }
}

struct Server {
    connections: HashMap<u32, Connection>,
    vehicles: HashMap<u32, Vehicle>,
    // Client ID, game_id, server_id
    vehicle_ids: HashMap<u32, HashMap<u32, u32>>,
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
    server_identifier: String
}

impl Server {
    async fn run(mut self) {
        let mut ticks =
            tokio::time::interval(std::time::Duration::from_secs(1) / self.tickrate as u32).fuse();
        let mut send_info_ticks = tokio::time::interval(std::time::Duration::from_secs(1)).fuse();

        let (certificate_chain, key) = generate_certificate();
        let addr = SocketAddr::new(IpAddr::V4(Ipv4Addr::new(0, 0, 0, 0)), self.port);

        let mut server_config = quinn::ServerConfigBuilder::default();
        server_config.certificate(certificate_chain, key).unwrap();
        let mut server_config = server_config.build();

        let mut transport = quinn::TransportConfig::default();
        transport
            .max_idle_timeout(Some(std::time::Duration::from_secs(60)))
            .unwrap();
        server_config.transport = std::sync::Arc::new(transport);

        let mut endpoint = quinn::Endpoint::builder();
        endpoint.listen(server_config);
        let (_, incoming) = endpoint
            .with_socket(UdpSocket::bind(&addr).unwrap())
            .unwrap();

        let (client_events_tx, client_events_rx) = mpsc::channel(128);
        let mut client_events_rx = client_events_rx.fuse();
        let mut incoming = incoming
            .inspect(|_conn| println!("Client is trying to connect to the server"))
            .buffer_unordered(16);

        let stdin = tokio::io::stdin();
        let reader =
            tokio_util::codec::FramedRead::new(stdin, tokio_util::codec::LinesCodec::new());
        let mut reader = reader.fuse();
        self.load_lua_addons();

        println!("Server is running!");

        loop {
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
                        if let Err(e) = self.on_connect(conn, client_events_tx.clone()).await {
                            println!("Client has failed to connect to the server");
                        }
                    }
                },
                stdin_input = reader.next() => {
                    if let Some(stdin_input) = stdin_input {
                        self.on_console_input(stdin_input.unwrap_or(String::from(""))).await;
                    }
                },
                e = client_events_rx.select_next_some() => {
                    self.on_client_event(e.0, e.1).await;
                }
            }
        }
    }
    async fn send_players_info(&mut self) {
        let mut client_infos = vec![];
        for (_, client) in &self.connections {
            client_infos.push(client.client_info.clone());
        }
        for (_, client) in &mut self.connections {
            for client_info in &client_infos {
                let _ = client
                    .ordered
                    .send(Outgoing::PlayerInfoUpdate(client_info.clone()))
                    .await;
            }
        }
    }
    async fn send_server_info(&self) -> anyhow::Result<()> {
        if !self.show_in_list {
            return Ok(());
        }
        let server_info = serde_json::json!({
            "name": self.name.clone(),
            "player_count": self.connections.len(),
            "max_players": self.max_players,
            "description": self.description.clone(),
            "map": self.map.clone(),
            "port": self.port
        })
            .to_string();
       
        let client = self.reqwest_client.clone();
        tokio::spawn(async move {
            let _ = client
                .post("http://51.210.135.45:3692")
                .body(server_info)
                .send()
                .await;
        });
       
        Ok(())
    }

    async fn on_connect(
        &mut self,
        mut new_connection: quinn::NewConnection,
        mut client_events_tx: mpsc::Sender<(u32, IncomingEvent)>,
    ) -> anyhow::Result<()> {
        let connection = new_connection.connection.clone();
        if self.connections.len() >= self.max_players.into() {
            connection.close(0u32.into(), b"Server is full");
            return Err(anyhow::Error::msg("Server is full"));
        }
        // Should be strong enough for our targets. TODO: Check for collisions anyway
        let id = rand::random::<u32>();
        let (ordered_tx, ordered_rx) = mpsc::channel(256);
        let (unreliable_tx, unreliable_rx) = mpsc::channel(512);
        let client_connection = Connection {
            conn: connection.clone(),
            ordered: ordered_tx,
            unreliable: unreliable_tx,
            client_info: ClientInfo::new(id),
        };
        self.connections.insert(id, client_connection);

        async fn receive_client_data(new_connection: &mut quinn::NewConnection) -> anyhow::Result<ClientInfo> {
            let mut stream = new_connection.uni_streams.try_next().await?;
            if let Some(stream) = &mut stream {
                let mut buf = [0; 4];
                stream.read_exact(&mut buf[0..1]).await?;
                stream.read_exact(&mut buf[0..4]).await?;
                let len = u32::from_le_bytes(buf) as usize;
                let mut buf: Vec<u8> = vec![0; len];
                stream.read_exact(&mut buf).await?;
                let data_str = String::from_utf8(buf.to_vec())?;
                let info: ClientInfo = serde_json::from_str(&data_str)?;
                Ok(info)
            }
            else{
                Err(anyhow::Error::msg("Failed to fetch client info"))
            }
        }
       
        let connection_clone = connection.clone();
        // Receiver
        tokio::spawn(async move {
            let client_data = {
                if let Ok(client_data) = receive_client_data(&mut new_connection).await {
                    client_data
                }
                else{
                    connection_clone.close(0u32.into(), b"Failed to fetch client info. Client version mismatch?");
                    return
                }
            };
            if client_data.client_version != SERVER_VERSION {
                connection_clone.close(0u32.into(), b"Client version mismatch");
                return
            }
            client_events_tx
                .send((id, IncomingEvent::ClientConnected(client_data)))
                .await
                .unwrap();
            if let Err(_e) = Self::drive_receive(
                id,
                new_connection.uni_streams,
                new_connection.datagrams,
                connection_clone,
                client_events_tx.clone(),
            )
            .await
            {
                client_events_tx
                    .send((id, IncomingEvent::ConnectionLost))
                    .await
                    .unwrap();
            }
        });

        let server_info = serde_json::json!({
            "name": self.name.clone(),
            "player_count": self.connections.len(),
            "client_id": id,
            "map": self.map.clone(),
            "tickrate": self.tickrate,
            "max_vehicles_per_client": self.max_vehicles_per_client,
            "mods": list_mods().unwrap_or(vec![]),
            "server_identifier": self.server_identifier.clone()
        })
        .to_string()
        .into_bytes();

        // Sender
        tokio::spawn(async move {
            let mut stream = connection.open_uni().await;
            if let Ok(stream) = &mut stream {
                let _ = send(stream, 3, &server_info).await;
                let _ = stream.finish().await;
            }
            let _ = Self::drive_send(connection, ordered_rx, unreliable_rx).await;
        });
        Ok(())
    }

    async fn drive_send(
        connection: quinn::Connection,
        ordered: mpsc::Receiver<Outgoing>,
        unreliable: mpsc::Receiver<Outgoing>,
    ) -> anyhow::Result<()> {
        let mut ordered = ordered.fuse();
        let mut unreliable = unreliable.fuse();
        loop {
            select! {
                command = ordered.select_next_some() => {
                    let connection = connection.clone();
                    tokio::spawn(async move {
                        let mut stream = connection.open_uni().await;
                        if let Ok(stream) = &mut stream {
                            // Kinda ugly and hacky tbh
                            match command {
                                Outgoing::TransferFile(file) => {
                                    let _ = file_transfer::transfer_file(stream, std::path::Path::new(&file)).await;
                                }
                                _ => {
                                    let data_type = outgoing::get_data_type(&command);
                                    let _ = send(stream, data_type, &Self::handle_outgoing_data(command)).await;
                                }
                            }
                        }
                    });
                }
                command = unreliable.select_next_some() => {
                    let mut data = vec![outgoing::get_data_type(&command)];
                    data.append(&mut Self::handle_outgoing_data(command));
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
        datagrams: quinn::generic::Datagrams<quinn::crypto::rustls::TlsSession>,
        connection: quinn::Connection,
        mut client_events_tx: mpsc::Sender<(u32, IncomingEvent)>,
    ) -> anyhow::Result<()> {
        let mut cmds = streams
            .map(|stream| async {
                let mut stream = stream?;
                let mut data_type = [0; 1];
                stream.read_exact(&mut data_type).await?;
                let data_type = data_type[0];
                let mut buf = [0; 4];
                stream.read_exact(&mut buf[0..4]).await?;
                let len = u32::from_le_bytes(buf) as usize;
                let mut buf: Vec<u8> = vec![0; len];
                stream.read_exact(&mut buf).await?;
                Ok::<_, Error>((data_type, buf))
            })
            .buffered(512).fuse();

        let mut datagrams = datagrams
            .map(|data| async {
                let mut data: Vec<u8> = data?.to_vec();
                let data_type = data.remove(0);
                Ok::<_, Error>((data_type, data))
            })
            .buffered(512).fuse();

        loop {
            let (data_type, data) = select! {
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
            // React to ping with pong. Quite hacky
            if data_type == 254 {
                let start = std::time::SystemTime::now();
                let since_the_epoch = start
                    .duration_since(std::time::UNIX_EPOCH).unwrap();
                let mut header = vec![254];
                header.append(&mut since_the_epoch.as_secs_f64().to_le_bytes().to_vec());
                let _ = connection.send_datagram(header.into());
            }
            Self::handle_incoming_data(id, data_type, data, &mut client_events_tx).await?;
        }
        Err(anyhow::Error::msg("Disconnected"))
    }

    async fn tick(&mut self) {
        for (_, client) in &mut self.connections {
            for (vehicle_id, vehicle) in &self.vehicles {
                if let Some(transform) = &vehicle.transform {
                    let _ = client
                        .unreliable
                        .send(Outgoing::PositionUpdate(*vehicle_id, transform.clone()))
                        .await;
                }
                if let Some(electrics) = &vehicle.electrics {
                    let _ = client
                        .unreliable
                        .send(Outgoing::ElectricsUpdate(*vehicle_id, electrics.clone()))
                        .await;
                }
                if let Some(gearbox) = &vehicle.gearbox {
                    let _ = client
                        .unreliable
                        .send(Outgoing::GearboxUpdate(*vehicle_id, gearbox.clone()))
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
}

async fn send(stream: &mut quinn::SendStream, data_type: u8, message: &[u8]) -> anyhow::Result<()> {
    stream.write_all(&[data_type]).await?;
    stream
        .write_all(&(message.len() as u32).to_le_bytes())
        .await?;
    stream.write_all(&message).await?;
    Ok(())
}

fn generate_certificate() -> (CertificateChain, PrivateKey) {
    println!("Generating certificate...");
    let cert = rcgen::generate_simple_self_signed(vec!["kissmp".into()]).unwrap();
    let key = cert.serialize_private_key_der();
    let cert = cert.serialize_der().unwrap();
    (
        CertificateChain::from_certs(Certificate::from_der(&cert)),
        PrivateKey::from_der(&key).unwrap(),
    )
}

#[tokio::main]
async fn main() {
    println!("Gas, Gas, Gas!");
    let _ = list_mods(); // Dirty hack to create /mods/ folder

    let config = config::Config::load(std::path::Path::new("./config.json"));
    let (lua, receiver) = lua::setup_lua();
    let (watcher_tx, watcher_rx) = std::sync::mpsc::channel();
    let lua_watcher = notify::Watcher::new(watcher_tx, std::time::Duration::from_secs(2)).unwrap();
    let server = Server {
        connections: HashMap::with_capacity(8),
        reqwest_client: reqwest::Client::new(),
        vehicles: HashMap::with_capacity(64),
        vehicle_ids: HashMap::with_capacity(64),
        name: config.server_name,
        description: config.description,
        map: config.map,
        tickrate: config.tickrate,
        port: config.port,
        max_players: config.max_players,
        max_vehicles_per_client: config.max_vehicles_per_client,
        show_in_list: config.show_in_server_list,
        lua: lua,
        lua_watcher,
        lua_watcher_rx: watcher_rx,
        lua_commands: receiver,
        server_identifier: config.server_identifier
    };
    server.run().await;
}

fn list_mods() -> anyhow::Result<Vec<(String, u32)>> {
    let path = std::path::Path::new("./mods/");
    if !path.exists() {
        std::fs::create_dir(path).unwrap();
    }
    let mut result = vec![];
    let paths = std::fs::read_dir(path)?;
    for path in paths {
        let path = path?.path();
        if path.is_dir() {
            continue;
        }
        let file_name = path.file_name().unwrap().to_str().unwrap().to_string();
        let file = std::fs::File::open(path)?;
        let metadata = file.metadata()?;
        result.push((file_name, metadata.len() as u32))
    }
    Ok(result)
}
