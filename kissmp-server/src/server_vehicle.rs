use crate::*;

#[derive(Clone)]
pub struct Vehicle {
    pub transform: Option<Transform>,
    pub electrics: Option<Electrics>,
    pub gearbox: Option<Gearbox>,
    pub data: VehicleData,
}

impl crate::Server {
    pub async fn remove_vehicle(&mut self, id: u32, client_id: Option<u32>) {
        if let Some(vehicle) = self.vehicles.get(&id) {
            if let Some(owner_id) = vehicle.data.owner {
                if let Some(client_vehicles) = self.vehicle_ids.get_mut(&owner_id) {
                    client_vehicles.remove(&vehicle.data.in_game_id);
                    if client_vehicles.len() == 0 {
                        self.set_current_vehicle(owner_id, None).await;
                    }
                }
            }
        }

        self.vehicles.remove(&id);
        for (cid, client) in &mut self.connections {
            if Some(*cid) == client_id {
                continue;
            }
            let _ = client.ordered.send(ServerCommand::RemoveVehicle(id)).await;
        }

        self.lua.context(|lua_ctx| {
            let _ = crate::lua::run_hook::<(u32, Option<u32>), ()>(
                lua_ctx,
                String::from("OnVehicleRemoved"),
                (id, client_id),
            );
        });
    }    
    pub async fn reset_vehicle(&mut self, data: VehicleReset, client_id: Option<u32>) {
        for (cid, client) in &mut self.connections {
            if client_id.is_some() && *cid == client_id.unwrap() {
                continue;
            }
            let _ = client
                .ordered
                .send(ServerCommand::ResetVehicle(data.clone()))
                .await;
        }

        if let Some(vehicle) = self.vehicles.get_mut(&data.vehicle_id) {
            vehicle.data.position = data.position;
            vehicle.data.rotation = data.rotation;
            vehicle.transform = Some(Transform {
                position: data.position,
                rotation:  data.rotation,
                angular_velocity: [0.0, 0.0, 0.0],
                velocity: [0.0, 0.0, 0.0]
            });
        }

        let _ = self.update_lua_vehicles();
        self.lua.context(|lua_ctx| {
            let _ = crate::lua::run_hook::<(u32, Option<u32>), ()>(
                lua_ctx,
                String::from("OnVehicleResetted"),
                (data.vehicle_id, client_id),
            );
        });
    }

    pub async fn set_current_vehicle(&mut self, client_id: u32, vehicle_id: Option<u32>) {
        if let Some(connection) = self.connections.get_mut(&client_id) {
            connection.client_info_public.current_vehicle = vehicle_id;
            let _ = self.update_lua_connections();
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

    pub async fn spawn_vehicle(&mut self, owner: Option<u32>, data: VehicleData) {
        let server_id = rand::random::<u16>() as u32;
        let mut data = data.clone();
        data.server_id = server_id;
        data.owner = owner;
        for (_, client) in &mut self.connections {
            let _ = client
                .ordered
                .send(ServerCommand::VehicleSpawn(data.clone()))
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
            self.set_current_vehicle(owner, Some(server_id)).await;
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
