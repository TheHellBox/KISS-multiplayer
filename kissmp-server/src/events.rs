use crate::*;

impl Server {
    pub async fn on_client_event(&mut self, client_id: u32, event: IncomingEvent) {
        use IncomingEvent::*;
        use shared::ClientCommand::*;
        match event {
            ClientConnected(connection) => {
                let player_name = connection.client_info_public.name.clone();
                self.connections.insert(client_id, connection);
                // Kinda ugly, but idk how to deal with lifetimes otherwise
                let mut client_info_list = vec![];
                for (_, connection) in self.connections.clone() {
                    client_info_list.push(connection.client_info_public.clone())
                }
                let connection = self.connections.get_mut(&client_id).unwrap();
                for (_, vehicle) in &self.vehicles {
                    let _ = connection
                        .ordered
                        .send(ServerCommand::VehicleSpawn(vehicle.data.clone()))
                        .await;
                }
                for info in client_info_list {
                    let _ = connection
                        .ordered
                        .send(ServerCommand::PlayerInfoUpdate(info))
                        .await;
                }
                for (_, client) in &mut self.connections {
                    client
                        .send_chat_message(format!("Player {} has joined the server", player_name))
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
                    .client_info_public
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
                        .send(ServerCommand::PlayerDisconnected(client_id))
                        .await;
                }
                let _ = self.update_lua_connections();
                self.lua.context(|lua_ctx| {
                    let _ = crate::lua::run_hook::<u32, ()>(
                        lua_ctx,
                        String::from("OnPlayerDisconnected"),
                        client_id,
                    );
                });
                println!("Client has disconnected from the server");
            }
            ClientCommand(command) => {
                match command {
                    Chat(initial_message) => {
                        let mut initial_message = initial_message.clone();
                        initial_message.truncate(128);
                        let mut message = format!(
                            "{}: {}",
                            self.connections[&client_id].client_info_public.name,
                            initial_message.clone()
                        );
                        println!("{}", message);
                        self.lua.context(|lua_ctx| {
                            let results = crate::lua::run_hook::<(u32, String), Option<String>>(
                                lua_ctx,
                                String::from("OnChat"),
                                (client_id, initial_message.clone()),
                            );
                            for result in results {
                                if let Some(result) = result {
                                    message = result;
                                    break;
                                }
                            }
                        });
                        if message.len() > 0 {
                            for (_, client) in &mut self.connections {
                                client.send_chat_message(message.clone()).await;
                            }
                        }
                    }
                    VehicleUpdate(data) => {
                        if let Some(server_id) = self.get_server_id_from_game_id(client_id, data.vehicle_id) {
                            if let Some(vehicle) = self.vehicles.get_mut(&server_id) {
                                vehicle.data.position = data.transform.position;
                                vehicle.data.rotation = data.transform.rotation;
                                vehicle.transform = Some(data.transform);
                                vehicle.electrics = Some(data.electrics);
                                vehicle.gearbox = Some(data.gearbox);
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
                        self.spawn_vehicle(Some(client_id), data).await;
                    }
                    RemoveVehicle(id) => {
                        if let Some(server_id) = self.get_server_id_from_game_id(client_id, id) {
                            self.remove_vehicle(server_id, Some(client_id)).await;
                        }
                    }
                    ResetVehicle(id) => {
                        if let Some(server_id) = self.get_server_id_from_game_id(client_id, id) {
                            self.reset_vehicle(server_id, Some(client_id)).await;
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
                                .send(ServerCommand::TransferFile(path))
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
                                        .send(ServerCommand::VehicleMetaUpdate(meta.clone()))
                                        .await;
                                }
                            }
                        }
                    }
                    ElectricsUndefinedUpdate(vehicle_id, undefined_update) => {
                        if let Some(server_id) =
                            self.get_server_id_from_game_id(client_id, vehicle_id)
                        {
                           /* if let Some(vehicle) = self.vehicles.get_mut(&server_id) {
                                for (key, value) in &undefined_update.diff {
                                    if let Some(electrics) = &mut vehicle.electrics {
                                        electrics.undefined.insert(key.clone(), *value);
                                    }
                                }
                            }*/
                            for (_, client) in &mut self.connections {
                                let _ = client
                                    .ordered
                                    .send(ServerCommand::ElectricsUndefinedUpdate(server_id, undefined_update.clone()))
                                    .await;
                            }
                        }
                    }
                    Ping(ping) => {
                        let connection = self.connections
                            .get_mut(&client_id)
                            .unwrap();
                        connection
                            .client_info_public
                            .ping = ping as u32;
                        let start = std::time::SystemTime::now();
                        let since_the_epoch = start.duration_since(std::time::UNIX_EPOCH).unwrap();
                        let data = bincode::serialize(&shared::ServerCommand::Pong(since_the_epoch.as_secs_f64())).unwrap();
                        let _ = connection.conn.send_datagram(data.into());
                    }
                    VehicleChanged(id) => {
                        if let Some(server_id) = self.get_server_id_from_game_id(client_id, id) {
                            self.connections
                                .get_mut(&client_id)
                                .unwrap()
                                .client_info_public
                                .current_vehicle = server_id;
                        }
                    }
                    CouplerAttached(event) => {
                        for (_, client) in &mut self.connections {
                            let _ = client
                                .ordered
                                .send(ServerCommand::CouplerAttached(event.clone()))
                                .await;
                        }
                    }
                    CouplerDetached(event) => {
                        for (_, client) in &mut self.connections {
                            let _ = client
                                .ordered
                                .send(ServerCommand::CouplerDetached(event.clone()))
                                .await;
                        }
                    }
                    _ => {}
                }
            }
        }
    }
}
