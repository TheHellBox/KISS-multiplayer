use crate::*;

impl Server {
    pub async fn on_client_event(&mut self, client_id: u32, event: IncomingEvent) {
        use shared::ClientCommand::*;
        use IncomingEvent::*;
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
                if let Some(public_address) = &self.public_address {
                    connection.send_chat_message(
                        format!(
                            "You're playing on a uPnP enabled server. Others can join you by the following address: \n{}.\nNo port forwarding is required",
                            public_address
                        )
                    ).await;
                }
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
                info!("Client has disconnected from the server");
            }
            ClientCommand(command) => {
                match command {
                    Chat(initial_message) => {
                        let mut initial_message = initial_message.clone();
                        initial_message.truncate(128);
                        let mut message = initial_message.clone();
                        info!(
                            "<{}> {}",
                            self.connections
                                .get(&client_id)
                                .unwrap()
                                .client_info_public
                                .name,
                            message
                        );
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
                                client
                                    .send_player_chat_message(message.clone(), client_id)
                                    .await;
                            }
                        }
                    }
                    TriggerEvent(event, data) => {
                        self.lua.context(|lua_ctx| {
                            let _ = crate::lua::run_hook::<(u32, String), ()>(
                                lua_ctx,
                                String::from(event),
                                (client_id, data),
                            );
                        });
                        
                    }
                    VehicleUpdate(data) => {
                        if let Some(server_id) =
                            self.get_server_id_from_game_id(client_id, data.vehicle_id)
                        {
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
                        if let Some(server_id) =
                            self.get_server_id_from_game_id(client_id, data.in_game_id)
                        {
                            self.remove_vehicle(server_id, Some(client_id)).await;
                        }
                        if let Some(client_vehicles) = self.vehicle_ids.get(&client_id) {
                            if (data.name != "unicycle")
                                && (client_vehicles.len() as u8 >= self.max_vehicles_per_client)
                            {
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
                    ResetVehicle(data) => {
                        if let Some(server_id) = self.get_server_id_from_game_id(client_id, data.vehicle_id) {
                            let mut data = data.clone();
                            data.vehicle_id = server_id;
                            self.reset_vehicle(data, Some(client_id)).await;
                        }
                    }
                    RequestMods(files) => {
                        let paths = crate::list_mods(self.mods.clone());
                        for path in paths.unwrap().1 {
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
                        if let Some(server_id) =
                            self.get_server_id_from_game_id(client_id, meta.vehicle_id)
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
                                    .send(ServerCommand::ElectricsUndefinedUpdate(
                                        server_id,
                                        undefined_update.clone(),
                                    ))
                                    .await;
                            }
                        }
                    }
                    Ping(ping) => {
                        let connection = self.connections.get_mut(&client_id).unwrap();
                        connection.client_info_public.ping = ping as u32;
                        let start = std::time::SystemTime::now();
                        let since_the_epoch = start.duration_since(std::time::UNIX_EPOCH).unwrap();
                        let data = bincode::serialize(&shared::ServerCommand::Pong(
                            since_the_epoch.as_secs_f64(),
                        ))
                        .unwrap();
                        let _ = connection.conn.send_datagram(data.into());
                    }
                    VehicleChanged(id) => {
                        if let Some(server_id) = self.get_server_id_from_game_id(client_id, id) {
                            self.set_current_vehicle(client_id, Some(server_id)).await;
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
                    VoiceChatPacket(data) => {
                        let connection = self.connections.get_mut(&client_id).unwrap();
                        let position = {
                            if let Some(vehicle_id) = &connection.client_info_public.current_vehicle {
                                if let Some(vehicle) = self.vehicles.get(vehicle_id) {
                                    vehicle.data.position
                                } else {
                                    [0.0, 0.0, 0.0]
                                }
                            } else {
                                [0.0, 0.0, 0.0]
                            }
                        };
                        let data = bincode::serialize(&shared::ServerCommand::VoiceChatPacket(
                            client_id, position, data,
                        ))
                        .unwrap();
                        // TODO: Check for distane
                        for (id, client) in &self.connections {
                            if client_id == *id {
                                continue;
                            }
                            let _ = client.conn.send_datagram(data.clone().into());
                        }
                    }
                    DataChunk { chunk_index, total_chunks, data } => {
                        // info!("Received chunk {}/{} from client {}", chunk_index + 1, total_chunks, client_id);
                        let chunks = self.chunk_buffers
                            .entry(client_id)
                            .or_insert_with(HashMap::new)
                            .entry(total_chunks)
                            .or_insert_with(|| vec![String::new(); total_chunks as usize]);
                        
                        chunks[chunk_index as usize] = data;

                        if chunks.iter().all(|c| !c.is_empty()) {
                            // info!("All {} chunks received, reassembling data", total_chunks);
                            let full_json = chunks.join("");
                            // Parse and recursively handle reassembled command
                            match serde_json::from_str::<shared::ClientCommand>(&full_json) {
                                Ok(original_command) => {
                                    // Box to avoid infinite type size
                                    Box::pin(self.on_client_event(
                                        client_id, 
                                        IncomingEvent::ClientCommand(original_command)
                                    )).await;
                                }
                                Err(e) => {
                                    error!("Failed to parse reassembled JSON: {}", e);
                                }
                            }
                            // Clear chunks for this client
                            self.chunk_buffers.get_mut(&client_id).unwrap().remove(&total_chunks);
                        }
                    }
                    _ => {}
                }
            }
        }
    }
}

//fn _distance_sqrt(a: [f32; 3], b: [f32; 3]) -> f32 {
//    return ((b[0].powi(2) - a[0].powi(2)) +  (b[1].powi(2) - a[1].powi(2)) +  (b[2].powi(2) - a[2].powi(2)))
//}
