use crate::*;

impl Server{
    pub fn handle_outgoing_data(command: Outgoing) -> Vec<u8> {
        use Outgoing::*;
        match command {
            PositionUpdate(vehicle_id, transform) => {
                transform.to_bytes(vehicle_id)
            }
            VehicleSpawn(data) => {
                serde_json::to_string(&data).unwrap().into_bytes()
            }
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
            _NodesUpdate(vehicle_id, nodes) => {
                let mut nodes = nodes.clone();
                nodes.vehicle_id = vehicle_id;
                nodes.to_bytes()
            },
            RemoveVehicle(id) => {
                id.to_le_bytes().to_vec()
            },
            ResetVehicle(id) => {
                id.to_le_bytes().to_vec()
            }
            Chat(message) => {
                message.into_bytes()
            }
        }
    }
}
