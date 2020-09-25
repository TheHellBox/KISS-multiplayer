use anyhow::Error;
use futures::{select, StreamExt, TryStreamExt};
use quinn::{Certificate, CertificateChain, PrivateKey};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::net::{SocketAddr, UdpSocket};
use tokio::sync::mpsc;

#[derive(Debug)]
enum IncomingEvent {
    TransformUpdate(u32, Transform),
    VehicleData(VehicleData),
}

#[derive(Debug)]
enum Outgoing {
    VehicleSpawn(VehicleData),
    PositionUpdate(u32, Transform),
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

#[derive(Debug, Clone)]
pub struct Transform {
    position: [f32; 3],
    rotation: [f32; 4],
    generation: u32
}

struct Connection {
    pub ordered: mpsc::Sender<Outgoing>,
}

struct Server {
    connections: HashMap<u32, Connection>,
    transforms: HashMap<u32, Transform>,
    vehicle_data_storage: HashMap<u32, VehicleData>,
    // Client ID, game_id, server_id
    vehicles: HashMap<u32, HashMap<u32, u32>>,
    name: &'static str,
    tickrate: u8,
}

impl Server {
    async fn run(mut self) {
        let mut ticks =
            tokio::time::interval(std::time::Duration::from_secs(1) / self.tickrate as u32).fuse();
        let (certificate_chain, key) = generate_certificate();
        let addr = &"0.0.0.0:1234".parse::<SocketAddr>().unwrap();
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
                conn = incoming.select_next_some() => {
                    self.on_connect(conn.unwrap(), client_events_tx.clone()).await;
                },
                e = client_events_rx.select_next_some() => {
                    self.on_client_event(e.0, e.1).await;
                }
            }
        }
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
            ordered: ordered_tx,
        };
        self.connections.insert(id, client_connection);
        println!("Client has connected to the server");
        // Receiver
        tokio::spawn(async move {
            let mut cmds = new_connection
                .uni_streams
                .map(|stream| async {
                    let mut stream = stream.unwrap();
                    let mut data_type = [0; 1];
                    stream.read_exact(&mut data_type).await.unwrap();
                    let data_type = data_type[0];
                    let mut buf = [0; 4];
                    stream.read_exact(&mut buf[0..4]).await.unwrap();
                    let len = u32::from_le_bytes(buf) as usize;
                    let mut buf: Vec<u8> = vec![0; len];
                    stream.read_exact(&mut buf).await.unwrap();
                    Ok::<_, Error>((data_type, buf))
                })
                .buffer_unordered(16);
            loop {
                while let Some((data_type, data)) = cmds.try_next().await.unwrap() {
                    match data_type {
                        0 => {
                            let result: [f32; 9] = bincode::deserialize(&data).unwrap();
                            //println!("{}", result[0]);
                            let transform = IncomingEvent::TransformUpdate(
                                result[0] as u32,
                                Transform {
                                    position: [result[1], result[2], result[3]],
                                    rotation: [result[4], result[5], result[6], result[7]],
                                    generation: result[8] as u32
                                },
                            );
                            client_events_tx.send((id, transform)).await.unwrap();
                        }
                        1 => {
                            let data_str = String::from_utf8(data.to_vec()).unwrap();
                            let vehicle_data: VehicleData =
                                serde_json::from_str(&data_str).unwrap();
                            client_events_tx
                                .send((id, IncomingEvent::VehicleData(vehicle_data)))
                                .await
                                .unwrap()
                        }
                        254 => {
                            // heartbeat
                        }
                        _ => println!("Warning: Client sent unknown data type"),
                    }
                }
            }
            println!(":(");
        });

        let mut stream = connection.open_uni().await.unwrap();
        let server_info = serde_json::json!({
            "name": self.name.clone(),
            "player_count": self.connections.len(),
            "client_id": id
        }).to_string().into_bytes();
        send(&mut stream, 3, &server_info).await;
        for (_, vehicle) in &self.vehicle_data_storage{
            let data = serde_json::to_string(&vehicle).unwrap().into_bytes();
            send(&mut stream, 1, &data);
        }

        // Sender
        tokio::spawn(async move {
            while let Some(command) = ordered_rx.recv().await {
                use Outgoing::*;
                let data_type = get_data_type(&command);
                match command {
                    PositionUpdate(vehicle_id, transform) => {
                        let data = [
                            transform.position[0],
                            transform.position[1],
                            transform.position[2],
                            transform.rotation[0],
                            transform.rotation[1],
                            transform.rotation[2],
                            transform.rotation[3],
                            vehicle_id as f32,
                            transform.generation as f32,
                        ];
                        let data = bincode::serialize(&data).unwrap();
                        send(&mut stream, data_type, &data).await;
                    }
                    VehicleSpawn(data) => {
                        let data = serde_json::to_string(&data).unwrap().into_bytes();
                        send(&mut stream, data_type, &data).await;
                    }
                }
            }
        });
    }
    async fn tick(&mut self) {
        for (_, client) in &mut self.connections {
            for (vehicle_id, transform) in &self.transforms {
                client
                    .ordered
                    .send(Outgoing::PositionUpdate(*vehicle_id, transform.clone()))
                    .await
                    .unwrap();
            }
        }
    }

    async fn on_client_event(&mut self, client_id: u32, event: IncomingEvent) {
        use IncomingEvent::*;
        match event {
            TransformUpdate(vehicle_id, transform) => {
                if let Some(client_vehicles) = self.vehicles.get(&client_id) {
                    if let Some(server_id) = client_vehicles.get(&vehicle_id) {
                        self.transforms.insert(*server_id, transform);
                    }
                }
            }
            VehicleData(data) => {
                let server_id = rand::random::<u16>() as u32;
                println!("Server ID {}", server_id);
                let mut data = data.clone();
                data.server_id = Some(server_id);
                data.owner = Some(client_id);

                for (_, client) in &mut self.connections {
                    client
                        .ordered
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
            }
        }
    }
}

async fn send(stream: &mut quinn::SendStream, data_type: u8, message: &[u8]) {
    stream.write_all(&[data_type]).await.unwrap();
    stream.write_all(&(message.len() as u32).to_le_bytes()).await.unwrap();
    stream.write_all(&message).await.unwrap();
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
        connections: HashMap::with_capacity(16),
        transforms: HashMap::with_capacity(64),
        vehicles: HashMap::with_capacity(64),
        vehicle_data_storage: HashMap::with_capacity(64),
        name: "KissMP BeanNG Server",
        tickrate: 30,
    };
    server.run().await;
}

fn get_data_type(data: &Outgoing) -> u8 {
    use Outgoing::*;
    match data {
        PositionUpdate(_, _) => 0,
        VehicleSpawn(_) => 1,
    }
}
