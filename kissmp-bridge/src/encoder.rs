pub fn encode(data: &[u8]) -> Vec<u8> {
    let decoded = serde_json::from_slice::<shared::ClientCommand>(data);
    if let Ok(decoded) = decoded {
        let binary = bincode::serialize::<shared::ClientCommand>(&decoded);
        if let Ok(binary) = binary {
            return binary;
        } else {
            println!("e {:?}", binary);
        }
    } else {
        println!("e j {:?}", decoded);
    }
    vec![]
}
