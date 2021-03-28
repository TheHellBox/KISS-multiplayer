use crate::*;

impl Server {
    pub fn handle_outgoing_data(command: shared::ServerCommand) -> Vec<u8> {
        bincode::serialize(&command).unwrap()
    }
}
