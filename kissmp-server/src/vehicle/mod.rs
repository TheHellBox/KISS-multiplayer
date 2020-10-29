pub mod vehicle_meta;
pub mod electrics;
pub mod gearbox;
pub mod transform;

pub use vehicle_meta::*;
pub use electrics::*;
pub use gearbox::*;
pub use transform::*;

use serde::{Deserialize, Serialize};

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct VehicleData {
    pub parts_config: String,
    pub in_game_id: u32,
    pub color: [f32; 4],
    pub palete_0: [f32; 4],
    pub palete_1: [f32; 4],
    pub plate: String,
    pub name: String,
    #[serde(skip_deserializing)]
    pub server_id: Option<u32>,
    #[serde(skip_deserializing)]
    pub owner: Option<u32>,
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
        self.vehicles.remove(&id);
        for (cid, client) in &mut self.connections {
            if Some(*cid) == client_id {
                continue;
            }
            client
                .ordered
                .send(crate::Outgoing::RemoveVehicle(id))
                .await
                .unwrap();
        }
    }
    pub async fn reset_vehicle(&mut self, server_id: u32, client_id: Option<u32>) {
        for (cid, client) in &mut self.connections {
            if client_id.is_some() && *cid == client_id.unwrap() {
                continue;
            }
            client
                .ordered
                .send(crate::Outgoing::ResetVehicle(server_id))
                .await
                .unwrap();
        }
    }

    pub async fn set_current_vehicle(&mut self, client_id: u32, vehicle_id: u32) {
        {
            let connection = self.connections.get_mut(&client_id).unwrap();
            connection.client_info.current_vehicle = vehicle_id;
        }
        let client_info = self
            .connections
            .get(&client_id)
            .unwrap()
            .client_info
            .clone();
        for (_cid, client) in &mut self.connections {
            client
                .ordered
                .send(crate::Outgoing::PlayerInfoUpdate(client_info.clone()))
                .await
                .unwrap();
        }
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
}
