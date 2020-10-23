use crate::*;

#[derive(Debug)]
pub enum IncomingEvent {
    ClientConnected,
    ConnectionLost,
    TransformUpdate(u32, Transform),
    VehicleData(VehicleData),
    ElectricsUpdate(Electrics),
    GearboxUpdate(Gearbox),
    RemoveVehicle(u32),
    ResetVehicle(u32),
    UpdateClientInfo(ClientInfo),
    Chat(String),
    RequestMods(Vec<String>),
}

impl Server {
    pub async fn handle_incoming_data(
        id: u32,
        data_type: u8,
        data: Vec<u8>,
        client_events_tx: &mut mpsc::Sender<(u32, IncomingEvent)>,
    ) -> anyhow::Result<()> {
        match data_type {
            0 => {
                let (transform_id, transform) = Transform::from_bytes(&data);
                let transform = IncomingEvent::TransformUpdate(transform_id, transform);
                client_events_tx.send((id, transform)).await.unwrap();
            }
            1 => {
                let data_str = String::from_utf8(data.to_vec()).unwrap();
                let vehicle_data: VehicleData = serde_json::from_str(&data_str).unwrap();
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
            4 => {}
            5 => {
                let vehicle_id = u32::from_le_bytes([data[0], data[1], data[2], data[3]]);
                client_events_tx
                    .send((id, IncomingEvent::RemoveVehicle(vehicle_id)))
                    .await
                    .unwrap();
            }
            6 => {
                let vehicle_id = u32::from_le_bytes([data[0], data[1], data[2], data[3]]);
                client_events_tx
                    .send((id, IncomingEvent::ResetVehicle(vehicle_id)))
                    .await
                    .unwrap();
            }
            7 => {
                let data_str = String::from_utf8(data.to_vec()).unwrap();
                let info = serde_json::from_str(&data_str);
                if let Ok(info) = info {
                    client_events_tx
                        .send((id, IncomingEvent::UpdateClientInfo(info)))
                        .await
                        .unwrap();
                }
            }
            8 => {
                let mut chat_message = String::from_utf8(data.to_vec()).unwrap();
                chat_message.truncate(256);
                client_events_tx
                    .send((id, IncomingEvent::Chat(chat_message)))
                    .await
                    .unwrap();
            }
            9 => {
                let data_str = String::from_utf8(data.to_vec()).unwrap();
                let files = serde_json::from_str(&data_str);
                if let Ok(files) = files {
                    client_events_tx
                        .send((id, IncomingEvent::RequestMods(files)))
                        .await
                        .unwrap();
                }
            }
            254 => {
                // heartbeat
            }
            _ => println!("Warning: Client sent unknown data type"),
        }
        Ok(())
    }
}
