pub mod vehicle;
use vehicle::*;
use serde::{Serialize, Deserialize};

pub const VERSION: (u32, u32) = (0, 3);

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct ClientInfoPrivate {
    pub name: String,
    pub secret: String,
    pub client_version: (u32, u32),
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct ClientInfoPublic {
    pub name: String,
    pub id: u32,
    pub current_vehicle: u32,
    pub ping: u32,
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct ServerInfo {
    pub name: String,
    pub player_count: u8,
    pub client_id: u32,
    pub map: String,
    pub tickrate: u8,
    pub max_vehicles_per_client: u8,
    pub mods: Vec<(String, u32)>,
    pub server_identifier: String
}

impl ClientInfoPublic {
    pub fn new(id: u32) -> Self {
        Self {
            id,
            ..Default::default()
        }
    }
}

impl Default for ClientInfoPublic {
    fn default() -> Self {
        Self {
            name: String::from("Unknown"),
            id: 0,
            current_vehicle: 0,
            ping: 0,
        }
    }
}

#[derive(Debug, Serialize, Deserialize)]
pub enum ClientCommand {
    ClientInfo(ClientInfoPrivate),
    VehicleUpdate(VehicleUpdate),
    VehicleData(VehicleData),
    GearboxUpdate(Gearbox),
    RemoveVehicle(u32),
    ResetVehicle(u32),
    Chat(String),
    RequestMods(Vec<String>),
    VehicleMetaUpdate(VehicleMeta),
    VehicleChanged(u32),
    CouplerAttached(CouplerAttached),
    CouplerDetached(CouplerDetached),
    ElectricsUndefinedUpdate(u32, ElectricsUndefined),
    Ping(u16)
}

#[derive(Debug, Serialize, Deserialize)]
pub enum ServerCommand {
    VehicleUpdate(VehicleUpdate),
    VehicleSpawn(VehicleData),
    RemoveVehicle(u32),
    ResetVehicle(u32),
    Chat(String),
    TransferFile(String),
    SendLua(String),
    PlayerInfoUpdate(ClientInfoPublic),
    VehicleMetaUpdate(VehicleMeta),
    PlayerDisconnected(u32),
    VehicleLuaCommand(u32, String),
    CouplerAttached(CouplerAttached),
    CouplerDetached(CouplerDetached),
    ElectricsUndefinedUpdate(u32, ElectricsUndefined),
    ServerInfo(ServerInfo),
    FilePart(String, Vec<u8>, u32, u32, u32),
    Pong(f64)
}
