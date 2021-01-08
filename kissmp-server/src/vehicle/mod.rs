pub mod electrics;
pub mod gearbox;
pub mod transform;
pub mod vehicle_meta;

pub use electrics::*;
pub use gearbox::*;
pub use transform::*;
pub use vehicle_meta::*;

use serde::{Deserialize, Serialize};

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct VehicleData {
    pub parts_config: String,
    pub in_game_id: u32,
    pub color: [f32; 4],
    pub palette_0: [f32; 4],
    pub palette_1: [f32; 4],
    pub plate: Option<String>,
    pub name: String,
    #[serde(skip_deserializing)]
    pub server_id: u32,
    #[serde(skip_deserializing)]
    pub owner: Option<u32>,
    pub position: [f32; 3],
    pub rotation: [f32; 4],
}

#[derive(Clone)]
pub struct Vehicle {
    pub transform: Option<Transform>,
    pub electrics: Option<Electrics>,
    pub gearbox: Option<Gearbox>,
    pub data: VehicleData,
}

impl crate::Server {
    pub async fn remove_vehicle(&mut self, id: u32, client_id: Option<u32>) {
        let vehicle = self.vehicles.get(&id);
        if let Some(client_id) = client_id {
            if let Some(client_vehicles) = self.vehicle_ids.get_mut(&client_id) {
                if let Some(vehicle) = vehicle {
                    client_vehicles.remove(&vehicle.data.in_game_id);
                }
            }
        }

        self.vehicles.remove(&id);
        for (cid, client) in &mut self.connections {
            if Some(*cid) == client_id {
                continue;
            }
            let _ = client
                .ordered
                .send(crate::Outgoing::RemoveVehicle(id))
                .await;
        }
        self.lua.context(|lua_ctx| {
            let _ = crate::lua::run_hook::<(u32, Option<u32>), ()>(
                lua_ctx,
                String::from("OnVehicleRemoved"),
                (id, client_id),
            );
        });
    }
    pub async fn reset_vehicle(&mut self, server_id: u32, client_id: Option<u32>) {
        for (cid, client) in &mut self.connections {
            if client_id.is_some() && *cid == client_id.unwrap() {
                continue;
            }
            let _ = client
                .ordered
                .send(crate::Outgoing::ResetVehicle(server_id))
                .await;
        }
        self.lua.context(|lua_ctx| {
            let _ = crate::lua::run_hook::<(u32, Option<u32>), ()>(
                lua_ctx,
                String::from("OnVehicleResetted"),
                (server_id, client_id),
            );
        });
    }

    pub async fn set_current_vehicle(&mut self, client_id: u32, vehicle_id: u32) {
        let connection = self.connections.get_mut(&client_id).unwrap();
        connection.client_info.current_vehicle = vehicle_id;
        let _ = self.update_lua_connections();
    }

    pub fn get_server_id_from_game_id(&self, client_id: u32, game_id: u32) -> Option<u32> {
        if let Some(client_vehicles) = self.vehicle_ids.get(&client_id) {
            if let Some(server_id) = client_vehicles.get(&game_id) {
                Some(*server_id)
            } else {
                None
            }
        } else {
            None
        }
    }

    pub async fn spawn_vehicle(&mut self, owner: Option<u32>, data: VehicleData) {
        let server_id = rand::random::<u16>() as u32;
        let mut data = data.clone();
        data.server_id = server_id;
        data.owner = owner;
        for (_, client) in &mut self.connections {
            let _ = client
                .ordered
                .send(crate::Outgoing::VehicleSpawn(data.clone()))
                .await;
        }
        if let Some(owner) = owner {
            if self.vehicle_ids.get(&owner).is_none() {
                self.vehicle_ids
                    .insert(owner, std::collections::HashMap::with_capacity(16));
            }
            self.vehicle_ids
                .get_mut(&owner)
                .unwrap()
                .insert(data.in_game_id, server_id);
        }
        self.vehicles.insert(
            server_id,
            Vehicle {
                data,
                gearbox: None,
                electrics: None,
                transform: None,
            },
        );
        let _ = self.update_lua_vehicles();
        if let Some(owner) = owner {
            self.set_current_vehicle(owner, server_id).await;
            self.lua.context(|lua_ctx| {
                let _ = crate::lua::run_hook::<(u32, u32), ()>(
                    lua_ctx,
                    String::from("OnVehicleSpawned"),
                    (server_id, owner),
                );
            });
        }
    }
}

#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
pub struct CouplerAttached {
    obj_a: u32,
    obj_b: u32,
    node_a_id: u32,
    node_b_id: u32,
}

#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
pub struct CouplerDetached {
    obj_a: u32,
    obj_b: u32,
    node_a_id: u32,
    node_b_id: u32,
}

impl CouplerAttached {
    pub fn from_bytes(data: &[u8]) -> Result<Self, rmp_serde::decode::Error> {
        rmp_serde::decode::from_read_ref(data)
    }
    pub fn to_bytes(&self) -> Vec<u8> {
        rmp_serde::encode::to_vec(self).unwrap()
    }
}

impl CouplerDetached {
    pub fn from_bytes(data: &[u8]) -> Result<Self, rmp_serde::decode::Error> {
        rmp_serde::decode::from_read_ref(data)
    }
    pub fn to_bytes(&self) -> Vec<u8> {
        rmp_serde::encode::to_vec(self).unwrap()
    }
}
