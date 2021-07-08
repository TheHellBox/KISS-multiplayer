use log::{error};

pub async fn decode(
    data: &[u8],
    writer: tokio::sync::mpsc::Sender<Vec<u8>>,
    vc_pb_writer: Option<std::sync::mpsc::Sender<crate::voice_chat::VoiceChatPlaybackEvent>>,
) {
    let decoded = bincode::deserialize::<shared::ServerCommand>(data);
    if let Ok(decoded) = decoded {
        match decoded {
            shared::ServerCommand::FilePart(name, data, chunk_n, file_size, data_left) => {
                let name_b = name.as_bytes();
                let mut result = vec![0];
                result.append(&mut (name_b.len() as u32).to_le_bytes().to_vec());
                result.append(&mut name_b.to_vec());
                result.append(&mut chunk_n.to_le_bytes().to_vec());
                result.append(&mut file_size.to_le_bytes().to_vec());
                result.append(&mut data_left.to_le_bytes().to_vec());
                result.append(&mut data.clone());
                writer.send(result).await.unwrap();
            }
            shared::ServerCommand::VoiceChatPacket(client, pos, data) => {
                if let Some(vc_pb_writer) = vc_pb_writer {
                    let _ = vc_pb_writer
                        .send(crate::voice_chat::VoiceChatPlaybackEvent::Packet(
                            client, pos, data,
                        ))
                        .unwrap();
                }
            }
            _ => {
                let json = serde_json::to_string(&decoded);
                if let Ok(json) = json {
                    //println!("{:?}", json);
                    let mut data = json.into_bytes();
                    let mut result = vec![1];
                    result.append(&mut (data.len() as u32).to_le_bytes().to_vec());
                    result.append(&mut data);
                    writer.send(result).await.unwrap();
                } else {
                    error!("Error: {:?}", json);
                }
            }
        }
    } else {
        error!("Error bin: {:?}", decoded);
    }
}
