use crate::*;

#[derive(Debug)]
pub enum IncomingEvent {
    ClientConnected(Connection),
    ConnectionLost,
    TransformUpdate(u32, Transform),
    VehicleData(VehicleData),
    ElectricsUpdate(Electrics),
    GearboxUpdate(Gearbox),
    RemoveVehicle(u32),
    ResetVehicle(u32),
    Chat(String),
    RequestMods(Vec<String>),
    VehicleMetaUpdate(VehicleMeta),
    ElectricsUndefinedUpdate(ElectricsUndefined),
    PingUpdate(u32),
    VehicleChanged(u32),
    CouplerAttached(CouplerAttached),
    CouplerDetached(CouplerDetached),
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
                client_events_tx.send((id, transform)).await?;
            }
            1 => {
                let data_str = String::from_utf8(data.to_vec()).unwrap();
                let vehicle_data: VehicleData = serde_json::from_str(&data_str).unwrap();
                client_events_tx
                    .send((id, IncomingEvent::VehicleData(vehicle_data)))
                    .await?;
            }
            2 => {
                let electrics = Electrics::from_bytes(&data);
                if let Ok(electrics) = electrics {
                    client_events_tx
                        .send((id, IncomingEvent::ElectricsUpdate(electrics)))
                        .await?;
                }
            }
            3 => {
                let gearbox_state = Gearbox::from_bytes(&data);
                if let Ok(gearbox_state) = gearbox_state {
                    client_events_tx
                        .send((id, IncomingEvent::GearboxUpdate(gearbox_state)))
                        .await?;
                }
            }
            4 => {}
            5 => {
                if data.len() < 4 {
                    return Ok(());
                }
                let vehicle_id = u32::from_le_bytes([data[0], data[1], data[2], data[3]]);
                client_events_tx
                    .send((id, IncomingEvent::RemoveVehicle(vehicle_id)))
                    .await?;
            }
            6 => {
                if data.len() < 4 {
                    return Ok(());
                }
                let vehicle_id = u32::from_le_bytes([data[0], data[1], data[2], data[3]]);
                client_events_tx
                    .send((id, IncomingEvent::ResetVehicle(vehicle_id)))
                    .await?;
            }
            8 => {
                let mut chat_message = String::from_utf8(data.to_vec())?;
                chat_message.truncate(256);
                client_events_tx
                    .send((id, IncomingEvent::Chat(chat_message)))
                    .await?;
            }
            9 => {
                let data_str = String::from_utf8(data.to_vec())?;
                let files = serde_json::from_str(&data_str);
                if let Ok(files) = files {
                    client_events_tx
                        .send((id, IncomingEvent::RequestMods(files)))
                        .await?;
                }
            }
            14 => {
                let meta = VehicleMeta::from_bytes(&data);
                if let Ok(meta) = meta {
                    client_events_tx
                        .send((id, IncomingEvent::VehicleMetaUpdate(meta)))
                        .await?;
                }
            }
            15 => {
                let electrics_undefined = ElectricsUndefined::from_bytes(&data);
                if let Ok(electrics_undefined) = electrics_undefined {
                    client_events_tx
                        .send((
                            id,
                            IncomingEvent::ElectricsUndefinedUpdate(electrics_undefined),
                        ))
                        .await?;
                }
            }
            18 => {
                if data.len() < 4 {
                    return Ok(());
                }
                let new_vehicle = u32::from_le_bytes([data[0], data[1], data[2], data[3]]);
                client_events_tx
                    .send((id, IncomingEvent::VehicleChanged(new_vehicle)))
                    .await?;
            }
            19 => {
                let event = CouplerAttached::from_bytes(&data);
                if let Ok(event) = event {
                    client_events_tx
                        .send((id, IncomingEvent::CouplerAttached(event)))
                        .await?;
                }
            }
            20 => {
                let event = CouplerDetached::from_bytes(&data);
                if let Ok(event) = event {
                    client_events_tx
                        .send((id, IncomingEvent::CouplerDetached(event)))
                        .await?;
                }
            }
            254 => {
                if data.len() < 4 {
                    return Ok(());
                }
                let ping = u32::from_le_bytes([data[0], data[1], data[2], data[3]]);
                client_events_tx
                    .send((id, IncomingEvent::PingUpdate(ping)))
                    .await?;
            }
            _ => println!("Warning: Client sent unknown data type"),
        }
        Ok(())
    }
}
