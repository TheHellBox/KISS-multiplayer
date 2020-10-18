pub mod electrics;
pub mod gearbox;
pub mod nodes;
pub mod transform;

use crate::electrics::*;
use crate::gearbox::*;
use crate::nodes::*;
use crate::transform::*;

use anyhow::Error;
use futures::{select, StreamExt, TryStreamExt};
use quinn::{Certificate, CertificateChain, PrivateKey};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::net::{SocketAddr, UdpSocket};
use tokio::sync::mpsc;

#[derive(Debug)]
enum IncomingEvent {
    ClientConnected,
    ConnectionLost,
    TransformUpdate(u32, Transform),
    VehicleData(VehicleData),
    ElectricsUpdate(Electrics),
    GearboxUpdate(Gearbox),
    NodesUpdate(Nodes),
    RemoveVehicle(u32),
    ResetVehicle(u32),
    UpdateClientInfo(ClientInfo),
    Chat(String)
}

#[derive(Debug)]
enum Outgoing {
    VehicleSpawn(VehicleData),
    PositionUpdate(u32, Transform),
    ElectricsUpdate(u32, Electrics),
    GearboxUpdate(u32, Gearbox),
    _NodesUpdate(u32, Nodes),
    RemoveVehicle(u32),
    ResetVehicle(u32),
    Chat(String)
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct VehicleData {
    parts_config: String,
    in_game_id: u32,
    color: [f32; 4],
    palete_0: [f32; 4],
    palete_1: [f32; 4],
    name: String,
    server_id: Option<u32>,
    owner: Option<u32>,
}

struct Connection {
    pub unordered: mpsc::Sender<Outgoing>,
    pub client_info: ClientInfo
}

#[derive(Serialize, Deserialize, Debug, Clone)]
struct ClientInfo {
    pub name: String
}

impl Default for ClientInfo {
    fn default() -> Self{
        Self{
            name: String::from("Unknown")
        }
    }
}

struct Server {
    connections: HashMap<u32, Connection>,
    transforms: HashMap<u32, Transform>,
    electrics: HashMap<u32, Electrics>,
    gearbox_states: HashMap<u32, Gearbox>,
    nodes: HashMap<u32, Nodes>,
    vehicle_data_storage: HashMap<u32, VehicleData>,
    reqwest_client: reqwest::Client,
    // Client ID, game_id, server_id
    vehicles: HashMap<u32, HashMap<u32, u32>>,
    name: &'static str,
    description: &'static str,
    tickrate: u8,
}

impl Server {
    async fn run(mut self) {
        let mut ticks =
            tokio::time::interval(std::time::Duration::from_secs(1) / self.tickrate as u32).fuse();
        let mut send_info_ticks =
            tokio::time::interval(std::time::Duration::from_secs(1)).fuse();

        let (certificate_chain, key) = generate_certificate();
        let addr = &"0.0.0.0:3698".parse::<SocketAddr>().unwrap();
        let mut server_config = quinn::ServerConfigBuilder::default();
        server_config.certificate(certificate_chain, key).unwrap();
        let mut endpoint = quinn::Endpoint::builder();
        endpoint.listen(server_config.build());
        let (_, incoming) = endpoint
            .with_socket(UdpSocket::bind(&addr).unwrap())
            .unwrap();
        let (client_events_tx, client_events_rx) = mpsc::channel(128);
        let mut client_events_rx = client_events_rx.fuse();
        let mut incoming = incoming
            .inspect(|_conn| println!("Client is trying to connect to the server"))
            .buffer_unordered(16);
        loop {
            select! {
                _ = ticks.next() => {
                    self.tick().await;
                },
                _ = send_info_ticks.next() => {
                    self.send_server_info().await.unwrap();
                }
                conn = incoming.select_next_some() => {
                    self.on_connect(conn.unwrap(), client_events_tx.clone()).await;
                },
                e = client_events_rx.select_next_some() => {
                    self.on_client_event(e.0, e.1).await;
                }
            }
        }
    }

    async fn send_server_info(&self) -> anyhow::Result<()>{
        let server_info = serde_json::json!({
            "name": self.name.clone(),
            "player_count": self.connections.len(),
            "max_players": 16,
            "description": self.description.clone(),
            "port": 3698
        }).to_string();
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
    ) {
        let connection = new_connection.connection.clone();
        // Should be strong enough for our targets. TODO: Check for collisions
        let id = rand::random::<u32>();
        let (ordered_tx, mut ordered_rx) = mpsc::channel(128);
        let client_connection = Connection {
            unordered: ordered_tx,
            client_info: ClientInfo::default()
        };
        self.connections.insert(id, client_connection);
        println!("Client has connected to the server");
        // Receiver
        tokio::spawn(async move {
            client_events_tx
                .send((id, IncomingEvent::ClientConnected))
                .await
                .unwrap();
            if let Err(_e) = Self::drive_receive(id, new_connection.uni_streams, client_events_tx.clone()).await {
                 client_events_tx
                    .send((id, IncomingEvent::ConnectionLost))
                    .await
                    .unwrap();
            }
        });

        let mut stream = connection.open_uni().await.unwrap();
        let server_info = serde_json::json!({
            "name": self.name.clone(),
            "player_count": self.connections.len(),
            "client_id": id
        })
        .to_string()
        .into_bytes();
        send(&mut stream, 3, &server_info).await.unwrap();
        stream.finish().await.unwrap();

        // Sender
        tokio::spawn(async move {
            while let Some(command) = ordered_rx.recv().await {
                use Outgoing::*;
                let mut stream = connection.open_uni().await.unwrap();
                let data_type = get_data_type(&command);
                let _ = match command {
                    PositionUpdate(vehicle_id, transform) => {
                        let data = transform.to_bytes(vehicle_id);
                        send(&mut stream, data_type, &data).await
                    }
                    VehicleSpawn(data) => {
                        let data = serde_json::to_string(&data).unwrap().into_bytes();
                        send(&mut stream, data_type, &data).await
                    }
                    ElectricsUpdate(vehicle_id, electrics_data) => {
                        let mut electrics_data = electrics_data.clone();
                        electrics_data.vehicle_id = vehicle_id;
                        let data = electrics_data.to_bytes();
                        send(&mut stream, data_type, &data).await
                    }
                    GearboxUpdate(vehicle_id, gearbox_state) => {
                        let mut gearbox_state = gearbox_state.clone();
                        gearbox_state.vehicle_id = vehicle_id;
                        let data = gearbox_state.to_bytes();
                        send(&mut stream, data_type, &data).await
                    }
                    _NodesUpdate(vehicle_id, nodes) => {
                        let mut nodes = nodes.clone();
                        nodes.vehicle_id = vehicle_id;
                        let data = nodes.to_bytes();
                        send(&mut stream, data_type, &data).await
                    },
                    RemoveVehicle(id) => {
                        let data = id.to_le_bytes();
                        send(&mut stream, data_type, &data).await
                    },
                    ResetVehicle(id) => {
                        let data = id.to_le_bytes();
                        send(&mut stream, data_type, &data).await
                    }
                    Chat(message) => {
                        let data = message.into_bytes();
                        send(&mut stream, data_type, &data).await
                    }
                };
            }
        });
    }
    async fn drive_receive(id: u32, streams: quinn::IncomingUniStreams, mut client_events_tx: mpsc::Sender<(u32, IncomingEvent)>) -> anyhow::Result<()>{
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
        while let Some((data_type, data)) = cmds.try_next().await? {
            match data_type {
                0 => {
                    let (transform_id, transform) = Transform::from_bytes(&data);
                    let transform = IncomingEvent::TransformUpdate(transform_id, transform);
                    client_events_tx.send((id, transform)).await.unwrap();
                }
                1 => {
                    let data_str = String::from_utf8(data.to_vec()).unwrap();
                    let vehicle_data: VehicleData =
                        serde_json::from_str(&data_str).unwrap();
                    client_events_tx
                        .send((id, IncomingEvent::VehicleData(vehicle_data)))
                        .await
                        .unwrap();
                }
                2 => {
                    let electrics = Electrics::from_bytes(&data);
                    if let Ok(electrics) = electrics {
                        client_events_tx
                            .send((id, IncomingEvent::ElectricsUpdate(electrics)))
                            .await
                            .unwrap();
                    }
                }
                3 => {
                    let gearbox_state = Gearbox::from_bytes(&data);
                    if let Ok(gearbox_state) = gearbox_state {
                        client_events_tx
                            .send((id, IncomingEvent::GearboxUpdate(gearbox_state)))
                            .await
                            .unwrap();
                    }
                }
                4 => {
                    let nodes = Nodes::from_bytes(&data);
                    client_events_tx
                        .send((id, IncomingEvent::NodesUpdate(nodes)))
                        .await
                        .unwrap();
                },
                5 => {
                    let vehicle_id = u32::from_le_bytes([data[0], data[1], data[2], data[3]]);
                    client_events_tx
                        .send((id, IncomingEvent::RemoveVehicle(vehicle_id)))
                        .await
                        .unwrap();
                },
                6 => {
                    let vehicle_id = u32::from_le_bytes([data[0], data[1], data[2], data[3]]);
                    client_events_tx
                        .send((id, IncomingEvent::ResetVehicle(vehicle_id)))
                        .await
                        .unwrap();
                },
                7 => {
                    let data_str = String::from_utf8(data.to_vec()).unwrap();
                    let info: ClientInfo =
                        serde_json::from_str(&data_str).unwrap();
                     client_events_tx
                        .send((id, IncomingEvent::UpdateClientInfo(info)))
                        .await
                        .unwrap();
                },
                8 => {
                    let mut chat_message = String::from_utf8(data.to_vec()).unwrap();
                    chat_message.truncate(256);
                    client_events_tx
                        .send((id, IncomingEvent::Chat(chat_message)))
                        .await
                        .unwrap();
                }
                254 => {
                    // heartbeat
                }
                _ => println!("Warning: Client sent unknown data type"),
            }
        }
        Ok(())
    }
    async fn tick(&mut self) {
        for (_, client) in &mut self.connections {
            for (vehicle_id, transform) in &self.transforms {
                client
                    .unordered
                    .send(Outgoing::PositionUpdate(*vehicle_id, transform.clone()))
                    .await
                    .unwrap();
            }
            for (vehicle_id, electrics_data) in &self.electrics {
                client
                    .unordered
                    .send(Outgoing::ElectricsUpdate(
                        *vehicle_id,
                        electrics_data.clone(),
                    ))
                    .await
                    .unwrap();
            }
            for (vehicle_id, gearbox_state) in &self.gearbox_states {
                client
                    .unordered
                    .send(Outgoing::GearboxUpdate(*vehicle_id, gearbox_state.clone()))
                    .await
                    .unwrap();
            }
        }
    }

    async fn on_client_event(&mut self, client_id: u32, event: IncomingEvent) {
        use IncomingEvent::*;
        match event {
            ClientConnected => {
                for (_, vehicle) in &self.vehicle_data_storage {
                    self.connections.get_mut(&client_id).unwrap()
                        .unordered
                        .send(Outgoing::VehicleSpawn(vehicle.clone()))
                        .await
                        .unwrap();
                }
            }
            ConnectionLost => {
                self.connections.remove(&client_id);
                if let Some(client_vehicles) = self.vehicles.get(&client_id) {
                    for (_, id) in client_vehicles {
                        self.vehicle_data_storage.remove(&id);
                        self.transforms.remove(&id);
                        self.electrics.remove(&id);
                        self.gearbox_states.remove(&id);
                        self.nodes.remove(&id);
                        for (_, client) in &mut self.connections {
                            client
                                .unordered
                                .send(Outgoing::RemoveVehicle(*id))
                                .await
                                .unwrap();
                        }
                    }
                }
                self.vehicles.remove(&client_id);
                println!("Client has disconnected from the server");
            }
            UpdateClientInfo(info) => {
                if let Some(connection) = self.connections.get_mut(&client_id) {
                    connection.client_info = info;
                }
            },
            Chat(message) => {
                for (_, client) in &mut self.connections {
                    let message = format!("{}: {}", client.client_info.name, message);
                    client
                        .unordered
                        .send(Outgoing::Chat(message))
                        .await
                        .unwrap();
                }
            }
            TransformUpdate(vehicle_id, transform) => {
                if let Some(client_vehicles) = self.vehicles.get(&client_id) {
                    if let Some(server_id) = client_vehicles.get(&vehicle_id) {
                        //if self.client_owns_vehicle(client_id, *server_id) {
                        self.transforms.insert(*server_id, transform);
                        //}
                    }
                }
            }
            VehicleData(data) => {
                let server_id = rand::random::<u16>() as u32;
                let mut data = data.clone();
                data.server_id = Some(server_id);
                data.owner = Some(client_id);
                for (_, client) in &mut self.connections {
                    client
                        .unordered
                        .send(Outgoing::VehicleSpawn(data.clone()))
                        .await
                        .unwrap();
                }
                if self.vehicles.get(&client_id).is_none() {
                    self.vehicles.insert(client_id, HashMap::with_capacity(16));
                }
                self.vehicles
                    .get_mut(&client_id)
                    .unwrap()
                    .insert(data.in_game_id, server_id);
                self.vehicle_data_storage.insert(server_id, data);
                println!("Vehicle {} spawned!", server_id);
            }
            ElectricsUpdate(data) => {
                if let Some(client_vehicles) = self.vehicles.get(&client_id) {
                    if let Some(server_id) = client_vehicles.get(&data.vehicle_id) {
                        self.electrics.insert(*server_id, data);
                    }
                }
            }
            GearboxUpdate(gearbox_state) => {
                if let Some(client_vehicles) = self.vehicles.get(&client_id) {
                    if let Some(server_id) = client_vehicles.get(&gearbox_state.vehicle_id) {
                        self.gearbox_states.insert(*server_id, gearbox_state);
                    }
                }
            }
            NodesUpdate(nodes) => {
                if let Some(client_vehicles) = self.vehicles.get(&client_id) {
                    if let Some(server_id) = client_vehicles.get(&nodes.vehicle_id) {
                        self.nodes.insert(*server_id, nodes.clone());
                    }
                }
            }
            RemoveVehicle(id) => {
                if let Some(client_vehicles) = self.vehicles.get(&client_id) {
                    if let Some(server_id) = client_vehicles.get(&id) {
                        self.vehicle_data_storage.remove(&server_id);
                        self.transforms.remove(&server_id);
                        self.electrics.remove(&server_id);
                        self.gearbox_states.remove(&server_id);
                        self.nodes.remove(&server_id);
                        println!("Vehicle {} removed!", server_id);
                        for (cid, client) in &mut self.connections {
                            if *cid == client_id { continue; }
                            client
                                .unordered
                                .send(Outgoing::RemoveVehicle(*server_id))
                                .await
                                .unwrap();
                        }
                    }
                }
            },
            ResetVehicle(id) => {
                if let Some(client_vehicles) = self.vehicles.get(&client_id) {
                    if let Some(server_id) = client_vehicles.get(&id) {
                        println!("Vehicle {} resseted!", server_id);
                        for (cid, client) in &mut self.connections {
                            if *cid == client_id { continue; }
                            client
                                .unordered
                                .send(Outgoing::ResetVehicle(*server_id))
                                .await
                                .unwrap();
                        }
                    }
                }
            }
        }
    }

    pub fn client_owns_vehicle(&self, client_id: u32, vehicle_id: u32) -> bool {
        if let Some(vehicles) = self.vehicles.get(&client_id) {
            vehicles.get(&vehicle_id).is_some()
        } else {
            false
        }
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
    let server = Server {
        connections: HashMap::with_capacity(8),
        reqwest_client: reqwest::Client::new(),
        transforms: HashMap::with_capacity(64),
        vehicles: HashMap::with_capacity(64),
        electrics: HashMap::with_capacity(64),
        nodes: HashMap::with_capacity(64),
        gearbox_states: HashMap::with_capacity(64),
        vehicle_data_storage: HashMap::with_capacity(64),
        name: "KissMP Vanilla Server",
        description: "Vanilla KissMP server. Nothing fancy.",
        tickrate: 66,
    };
    server.run().await;
}

fn get_data_type(data: &Outgoing) -> u8 {
    use Outgoing::*;
    match data {
        PositionUpdate(_, _) => 0,
        VehicleSpawn(_) => 1,
        ElectricsUpdate(_, _) => 2,
        GearboxUpdate(_, _) => 3,
        _NodesUpdate(_, _) => 4,
        RemoveVehicle(_) => 5,
        ResetVehicle(_) => 6,
        Chat(_) => 8,
    }
}
