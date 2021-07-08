use log::{error};

pub fn encode(data: &shared::ClientCommand) -> Vec<u8> {
    let binary = bincode::serialize::<shared::ClientCommand>(data);
    if let Ok(binary) = binary {
        return binary;
    } else {
        error!("e {:?}", binary);
    }
    vec![]
}
