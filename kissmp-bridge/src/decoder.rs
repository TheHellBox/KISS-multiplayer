pub async fn decode(data: &[u8], writer: tokio::sync::mpsc::Sender<Vec<u8>>) {
    let decoded = bincode::deserialize::<shared::ServerCommand>(data);
    if let Ok(decoded) = decoded {
        match decoded {
            _ => {
                let json = serde_json::to_string(&decoded);
                if let Ok(json) = json {
                    println!("{:?}", json);
                    let mut data = json.into_bytes();
                    let mut result = vec![];
                    result.append(&mut (data.len() as u32).to_le_bytes().to_vec());
                    result.append(&mut data);
                    writer.send(result).await.unwrap();
                }
                else{
                    println!("Error: {:?}", json);
                }
            }
        }
    }
    else{
        println!("Error bin: {:?}", decoded);
    }
}
