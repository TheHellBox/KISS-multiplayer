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
use futures::{select, StreamExt};
use quinn::{Certificate, CertificateChain, PrivateKey};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::net::{IpAddr, Ipv4Addr, SocketAddr, UdpSocket};
use tokio::sync::mpsc;

#[derive(Clone)]
struct Connection {
    pub conn: quinn::Connection,
    pub ordered: mpsc::Sender<Outgoing>,
    pub unreliable: mpsc::Sender<Outgoing>,
    pub client_info: ClientInfo,
}

impl Connection {
    pub async fn send_chat_message(&mut self, message: String) {
        self.ordered
            .send(Outgoing::Chat(message.clone()))
            .await
            .unwrap();
    }
    pub async fn send_lua(&mut self, lua: String) {
        self.ordered
            .send(Outgoing::SendLua(lua.clone()))
            .await
            .unwrap();
    }
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct ClientInfo {
    pub name: String,
    #[serde(skip_deserializing)]
    pub id: u32,
    #[serde(skip_deserializing)]
    pub current_vehicle: u32,
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
    port: u16,
    show_in_list: bool,
    lua: rlua::Lua,
    lua_commands: std::sync::mpsc::Receiver<lua::LuaCommand>,
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
            .max_idle_timeout(Some(std::time::Duration::from_secs(120)))
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
                }
                conn = incoming.select_next_some() => {
                    if let Ok(conn) = conn {
                        if let Err(e) = self.on_connect(conn, client_events_tx.clone()).await {
                            println!("Client has failed to connect to the server");
                        }
                    }
                },
                stdin_input = reader.next() => {
                    self.on_console_input(stdin_input.unwrap().unwrap()).await;
                },
                e = client_events_rx.select_next_some() => {
                    self.on_client_event(e.0, e.1).await;
                }
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
        self.reqwest_client
            .post("http://185.87.49.206:3692")
            .body(server_info)
            .send()
            .await?;
        Ok(())
    }

    async fn on_connect(
        &mut self,
        new_connection: quinn::NewConnection,
        mut client_events_tx: mpsc::Sender<(u32, IncomingEvent)>,
    ) -> anyhow::Result<()> {
        let connection = new_connection.connection.clone();
        if self.connections.len() >= self.max_players.into() {
            connection.close(0u32.into(), b"Server is full");
            return Err(anyhow::Error::msg("Server is full"));
        }
        // Should be strong enough for our targets. TODO: Check for collisions anyway
        let id = rand::random::<u32>();
        let (ordered_tx, ordered_rx) = mpsc::channel(128);
        let (unreliable_tx, unreliable_rx) = mpsc::channel(128);
        let client_connection = Connection {
            conn: connection.clone(),
            ordered: ordered_tx,
            unreliable: unreliable_tx,
            client_info: ClientInfo::new(id),
        };
        self.connections.insert(id, client_connection);
        println!("Client has connected to the server");
        // Receiver
        tokio::spawn(async move {
            client_events_tx
                .send((id, IncomingEvent::ClientConnected))
                .await
                .unwrap();
            if let Err(_e) = Self::drive_receive(
                id,
                new_connection.uni_streams,
                new_connection.datagrams,
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

        let mut stream = connection.open_uni().await?;
        let server_info = serde_json::json!({
            "name": self.name.clone(),
            "player_count": self.connections.len(),
            "client_id": id,
            "map": self.map.clone(),
            "tickrate": self.tickrate,
            "mods": list_mods().unwrap_or(vec![])
        })
        .to_string()
        .into_bytes();
        send(&mut stream, 3, &server_info).await?;
        stream.finish().await?;

        // Sender
        tokio::spawn(async move {
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
                    let mut stream = connection.open_uni().await?;
                    // Kinda ugly and hacky tbh
                    match command {
                        Outgoing::TransferFile(file) => {
                            file_transfer::transfer_file(&mut stream, std::path::Path::new(&file)).await?;
                            continue;
                        }
                        _ => {}
                    }
                    let data_type = outgoing::get_data_type(&command);
                    send(&mut stream, data_type, &Self::handle_outgoing_data(command)).await?;
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
        Ok(())
    }

    async fn drive_receive(
        id: u32,
        streams: quinn::IncomingUniStreams,
        datagrams: quinn::generic::Datagrams<quinn::crypto::rustls::TlsSession>,
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
            .buffer_unordered(16);

        let mut datagrams = datagrams
            .map(|data| async {
                let mut data: Vec<u8> = data?.to_vec();
                let data_type = data.remove(0);
                Ok::<_, Error>((data_type, data))
            })
            .buffer_unordered(32);
        loop {
            select! {
                data = cmds.select_next_some() => {
                    let (data_type, data) = data?;
                    Self::handle_incoming_data(id, data_type, data, &mut client_events_tx).await?;
                }
                data = datagrams.select_next_some() => {
                    let (data_type, data) = data?;
                    Self::handle_incoming_data(id, data_type, data, &mut client_events_tx).await?;
                }
            }
        }
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

    pub fn _client_owns_vehicle(&self, client_id: u32, vehicle_id: u32) -> bool {
        if let Some(vehicles) = self.vehicle_ids.get(&client_id) {
            // FIXME: I think that can be optimized
            for (_, server_id) in vehicles {
                if *server_id == vehicle_id {
                    return true;
                }
            }
            false
        } else {
            false
        }
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
    let config = config::Config::load(std::path::Path::new("./config.json"));
    let (lua, receiver) = lua::setup_lua();
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
        show_in_list: config.show_in_server_list,
        lua: lua,
        lua_commands: receiver,
    };
    server.run().await;
}

fn list_mods() -> anyhow::Result<Vec<(String, u32)>> {
    let mut result = vec![];
    let paths = std::fs::read_dir("./mods/")?;
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
