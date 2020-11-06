use crate::*;

impl Server {
    pub async fn on_client_event(&mut self, client_id: u32, event: IncomingEvent) {
        use IncomingEvent::*;
        match event {
            ClientConnected => {
                // Kinda ugly, but idk how to deal with lifetimes otherwise
                let mut client_info_list = vec![];
                for (_, connection) in self.connections.clone() {
                    client_info_list.push(connection.client_info.clone())
                }
                let connection = self.connections.get_mut(&client_id).unwrap();
                let _ = connection
                    .ordered
                    .send(Outgoing::PlayerInfoUpdate(connection.client_info.clone()))
                    .await;
                for (_, vehicle) in &self.vehicles {
                    let _ = connection
                        .ordered
                        .send(Outgoing::VehicleSpawn(vehicle.data.clone()))
                        .await;
                }
                for info in client_info_list {
                    let _ = connection
                        .ordered
                        .send(Outgoing::PlayerInfoUpdate(info))
                        .await;
                }
                let _ = self.update_lua_connections();
                self.lua.context(|lua_ctx| {
                    let _ = crate::lua::run_hook::<u32, ()>(
                        lua_ctx,
                        String::from("OnPlayerConnected"),
                        client_id,
                    );
                });
            }
            ConnectionLost => {
                let player_name = self
                    .connections
                    .get(&client_id)
                    .unwrap()
                    .client_info
                    .name
                    .clone();
                self.connections
                    .get_mut(&client_id)
                    .unwrap()
                    .conn
                    .close(0u32.into(), b"");
                self.connections.remove(&client_id);
                if let Some(client_vehicles) = self.vehicle_ids.clone().get(&client_id) {
                    for (_, id) in client_vehicles {
                        self.remove_vehicle(*id, Some(client_id)).await;
                    }
                }
                for (_, client) in &mut self.connections {
                    client
                        .send_chat_message(format!("Player {} has left the server", player_name))
                        .await;
                    let _ = client
                        .ordered
                        .send(Outgoing::PlayerDisconnected(client_id))
                        .await;
                }
                self.lua.context(|lua_ctx| {
                    let _ = crate::lua::run_hook::<u32, ()>(
                        lua_ctx,
                        String::from("OnPlayerDisconnected"),
                        client_id,
                    );
                });
                println!("Client has disconnected from the server");
            }
            UpdateClientInfo(info) => {
                if let Some(connection) = self.connections.get_mut(&client_id) {
                    let mut info = info.clone();
                    if info.name == String::from("") {
                        info.name = String::from("Unknown");
                    }
                    connection.client_info.name = info.name;
                    connection.client_info.current_vehicle = info.current_vehicle;
                }
            }
            Chat(initial_message) => {
                let mut message = format!(
                    "{}: {}",
                    self.connections[&client_id].client_info.name,
                    initial_message.clone()
                );
                println!("{}", message);
                self.lua.context(|lua_ctx| {
                    if let Some(Some(result)) = crate::lua::run_hook::<(u32, String), Option<String>>(
                        lua_ctx,
                        String::from("OnChat"),
                        (client_id, initial_message.clone()),
                    ) {
                        message = result;
                    }
                });
                if message.len() > 0 {
                    for (_, client) in &mut self.connections {
                        client.send_chat_message(message.clone()).await;
                    }
                }
            }
            TransformUpdate(vehicle_id, transform) => {
                if let Some(server_id) = self.get_server_id_from_game_id(client_id, vehicle_id) {
                    if let Some(vehicle) = self.vehicles.get_mut(&server_id) {
                        vehicle.data.position = transform.position;
                        vehicle.data.rotation = transform.rotation;
                        vehicle.transform = Some(transform);
                    }
                }
            }
            VehicleData(data) => {
                // Remove old vehicle with the same ID
                if let Some(server_id) = self.get_server_id_from_game_id(client_id, data.in_game_id)
                {
                    self.remove_vehicle(server_id, Some(client_id)).await;
                }
                if let Some(client_vehicles) = self.vehicle_ids.get(&client_id) {
                    if client_vehicles.len() as u8 >= self.max_vehicles_per_client {
                        return;
                    }
                }
                self.spawn_vehicle(client_id, data).await;
            }
            ElectricsUpdate(electrics) => {
                if let Some(server_id) =
                    self.get_server_id_from_game_id(client_id, electrics.vehicle_id)
                {
                    if let Some(vehicle) = self.vehicles.get_mut(&server_id) {
                        if let Some(veh_electrics) = &mut vehicle.electrics {
                            veh_electrics.throttle_input = electrics.throttle_input;
                            veh_electrics.brake_input = electrics.brake_input;
                            veh_electrics.clutch = electrics.clutch;
                            veh_electrics.parkingbrake = electrics.parkingbrake;
                            veh_electrics.steering_input = electrics.steering_input;
                        } else {
                            vehicle.electrics = Some(electrics);
                        }
                    }
                }
            }
            GearboxUpdate(gearbox) => {
                if let Some(server_id) =
                    self.get_server_id_from_game_id(client_id, gearbox.vehicle_id)
                {
                    if let Some(vehicle) = self.vehicles.get_mut(&server_id) {
                        vehicle.gearbox = Some(gearbox);
                    }
                }
            }
            RemoveVehicle(id) => {
                if let Some(server_id) = self.get_server_id_from_game_id(client_id, id) {
                    self.remove_vehicle(server_id, Some(client_id)).await;
                    self.lua.context(|lua_ctx| {
                        let _ = crate::lua::run_hook::<(u32, u32), ()>(
                            lua_ctx,
                            String::from("OnVehicleRemoved"),
                            (client_id, server_id),
                        );
                    });
                }
            }
            ResetVehicle(id) => {
                if let Some(server_id) = self.get_server_id_from_game_id(client_id, id) {
                    self.reset_vehicle(server_id, Some(client_id)).await;
                    self.lua.context(|lua_ctx| {
                        let _ = crate::lua::run_hook::<(u32, u32), ()>(
                            lua_ctx,
                            String::from("OnVehicleReset"),
                            (client_id, server_id),
                        );
                    });
                }
            }
            RequestMods(files) => {
                let paths = std::fs::read_dir("./mods/").unwrap();
                for path in paths {
                    let path = path.unwrap().path();
                    if path.is_dir() {
                        continue;
                    }
                    let file_name = path.file_name().unwrap().to_str().unwrap().to_string();
                    let path = path.to_str().unwrap().to_string();
                    if !files.contains(&file_name) {
                        continue;
                    }
                    let _ = self
                        .connections
                        .get_mut(&client_id)
                        .unwrap()
                        .ordered
                        .send(Outgoing::TransferFile(path))
                        .await;
                }
            }
            VehicleMetaUpdate(meta) => {
                if let Some(server_id) = self.get_server_id_from_game_id(client_id, meta.vehicle_id)
                {
                    if let Some(vehicle) = self.vehicles.get_mut(&server_id) {
                        vehicle.data.color = meta.colors_table[0];
                        vehicle.data.palete_0 = meta.colors_table[1];
                        vehicle.data.palete_1 = meta.colors_table[2];
                        vehicle.data.plate = meta.plate.clone();
                        let mut meta = meta.clone();
                        meta.vehicle_id = server_id;
                        for (_, client) in &mut self.connections {
                            let _ = client
                                .ordered
                                .send(Outgoing::VehicleMetaUpdate(meta.clone()))
                                .await;
                        }
                    }
                }
            }
            ElectricsUndefinedUpdate(undefined_update) => {
                if let Some(server_id) =
                    self.get_server_id_from_game_id(client_id, undefined_update.vehicle_id)
                {
                    if let Some(vehicle) = self.vehicles.get_mut(&server_id) {
                        for (key, value) in &undefined_update.diff {
                            if let Some(electrics) = &mut vehicle.electrics {
                                electrics.undefined.insert(key.clone(), *value);
                            }
                        }
                    }
                    let mut undefined_update = undefined_update.clone();
                    undefined_update.vehicle_id = server_id;
                    for (_, client) in &mut self.connections {
                        let _ = client
                            .ordered
                            .send(Outgoing::ElectricsUndefinedUpdate(undefined_update.clone()))
                            .await;
                    }
                }
            }
            PingUpdate(ping) => {
                self.connections.get_mut(&client_id).unwrap().client_info.ping = ping;
            }
            VehicleChanged(id) => {
                if let Some(server_id) =
                    self.get_server_id_from_game_id(client_id, id)
                {
                    self.connections.get_mut(&client_id).unwrap().client_info.current_vehicle = server_id;
                }
            }
        }
    }
}
