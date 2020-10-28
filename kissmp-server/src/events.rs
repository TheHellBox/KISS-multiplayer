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
                connection
                    .ordered
                    .send(Outgoing::PlayerInfoUpdate(connection.client_info.clone()))
                    .await
                    .unwrap();

                for (_, vehicle) in &self.vehicles {
                    connection
                        .ordered
                        .send(Outgoing::VehicleSpawn(vehicle.data.clone()))
                        .await
                        .unwrap();
                }

                for info in client_info_list {
                    connection
                        .ordered
                        .send(Outgoing::PlayerInfoUpdate(info))
                        .await
                        .unwrap();
                }
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
                }
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

                    connection
                        .ordered
                        .send(Outgoing::PlayerInfoUpdate(connection.client_info.clone()))
                        .await
                        .unwrap();
                }
            }
            Chat(initial_message) => {
                let mut message = format!(
                    "{}: {}",
                    self.connections[&client_id].client_info.name,
                    initial_message.clone()
                );

                self.lua.context(|lua_ctx| {
                    if let Some(result) = crate::lua::run_hook::<(u32, String), String>(
                        lua_ctx,
                        String::from("OnChat"),
                        (client_id, initial_message.clone()),
                    ) {
                        message = result;
                    }
                });

                for (_, client) in &mut self.connections {
                    client.send_chat_message(message.clone()).await;
                }
            }
            TransformUpdate(vehicle_id, transform) => {
                if let Some(server_id) = self.get_server_id_from_game_id(client_id, vehicle_id) {
                    if let Some(vehicle) = self.vehicles.get_mut(&server_id) {
                        vehicle.transform = Some(transform);
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
                        .ordered
                        .send(Outgoing::VehicleSpawn(data.clone()))
                        .await
                        .unwrap();
                }
                if self.vehicle_ids.get(&client_id).is_none() {
                    self.vehicle_ids
                        .insert(client_id, HashMap::with_capacity(16));
                }

                if let Some(server_id) = self.get_server_id_from_game_id(client_id, data.in_game_id)
                {
                    self.remove_vehicle(server_id, Some(client_id)).await;
                }

                self.vehicle_ids
                    .get_mut(&client_id)
                    .unwrap()
                    .insert(data.in_game_id, server_id);
                self.vehicles.insert(
                    server_id,
                    Vehicle {
                        data,
                        gearbox: None,
                        electrics: None,
                        transform: None,
                    },
                );
                self.set_current_vehicle(client_id, server_id).await;
            }
            ElectricsUpdate(electrics) => {
                if let Some(server_id) =
                    self.get_server_id_from_game_id(client_id, electrics.vehicle_id)
                {
                    if let Some(vehicle) = self.vehicles.get_mut(&server_id) {
                        vehicle.electrics = Some(electrics);
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
                    self.connections
                        .get_mut(&client_id)
                        .unwrap()
                        .ordered
                        .send(Outgoing::TransferFile(path))
                        .await
                        .unwrap();
                }
            }
            VehicleDataUpdate(data) => {
                if let Some(server_id) = self.get_server_id_from_game_id(client_id, data.in_game_id)
                {
                    if let Some(vehicle) = self.vehicles.get_mut(&server_id) {
                        vehicle.data.color = data.color;
                        vehicle.data.palete_0 = data.palete_0;
                        vehicle.data.palete_1 = data.palete_1;
                        vehicle.data.parts_config = data.parts_config;
                    }
                }
            }
            ColorsUpdate(colors) => {
                if let Some(server_id) = self.get_server_id_from_game_id(client_id, (colors.0).0) {
                    if let Some(vehicle) = self.vehicles.get_mut(&server_id) {
                        let colors_table = (colors.0).1;
                        vehicle.data.color = colors_table[0];
                        vehicle.data.palete_0 = colors_table[1];
                        vehicle.data.palete_1 = colors_table[2];
                        let mut colors = colors.clone();
                        (colors.0).0 = server_id;
                        for (_, client) in &mut self.connections {
                            client
                                .ordered
                                .send(Outgoing::ColorsUpdate(colors))
                                .await
                                .unwrap();
                        }
                    }
                }
            }
        }
    }
}
