use crate::*;

#[derive(Debug)]
pub enum Outgoing {
    VehicleSpawn(VehicleData),
    PositionUpdate(u32, Transform),
    ElectricsUpdate(u32, Electrics),
    GearboxUpdate(u32, Gearbox),
    RemoveVehicle(u32),
    ResetVehicle(u32),
    Chat(String),
    TransferFile(String),
    SendLua(String),
    PlayerInfoUpdate(ClientInfo),
    ColorsUpdate(Colors),
}

impl Server {
    pub fn handle_outgoing_data(command: Outgoing) -> Vec<u8> {
        use Outgoing::*;
        match command {
            PositionUpdate(vehicle_id, transform) => transform.to_bytes(vehicle_id),
            VehicleSpawn(data) => serde_json::to_string(&data).unwrap().into_bytes(),
            ElectricsUpdate(vehicle_id, electrics_data) => {
                let mut electrics_data = electrics_data.clone();
                electrics_data.vehicle_id = vehicle_id;
                electrics_data.to_bytes()
            }
            GearboxUpdate(vehicle_id, gearbox_state) => {
                let mut gearbox_state = gearbox_state.clone();
                gearbox_state.vehicle_id = vehicle_id;
                gearbox_state.to_bytes()
            }
            RemoveVehicle(id) => id.to_le_bytes().to_vec(),
            ResetVehicle(id) => id.to_le_bytes().to_vec(),
            Chat(message) => message.into_bytes(),
            SendLua(lua) => lua.into_bytes(),
            PlayerInfoUpdate(player_info) => player_info.to_bytes(),
            ColorsUpdate(colors) => colors.to_bytes(),
            TransferFile(_) => vec![], // Covered in other place, unused here
        }
    }
}

pub fn get_data_type(data: &Outgoing) -> u8 {
    use Outgoing::*;
    match data {
        PositionUpdate(_, _) => 0,
        VehicleSpawn(_) => 1,
        ElectricsUpdate(_, _) => 2,
        GearboxUpdate(_, _) => 3,
        RemoveVehicle(_) => 5,
        ResetVehicle(_) => 6,
        Chat(_) => 8,
        TransferFile(_) => 9,
        SendLua(_) => 11,
        PlayerInfoUpdate(_) => 12,
        ColorsUpdate(_) => 14,
    }
}
