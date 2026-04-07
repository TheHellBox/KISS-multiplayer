use crate::*;
use tokio::io::AsyncReadExt;

const CHUNK_SIZE: usize = 262144;

pub async fn transfer_file(
    connection: quinn::Connection,
    path: &std::path::Path,
) -> anyhow::Result<()> {
    let mut file = tokio::fs::File::open(path).await?;
    let metadata = file.metadata().await?;
    let file_length = metadata.len() as u32;
    let file_name = path.file_name().unwrap().to_str().unwrap();
    let mut buf = [0; CHUNK_SIZE];
    let mut chunk_n = 0;
    
    let mut stream = connection.open_uni().await?;
    
    while let Ok(n) = file.read(&mut buf).await {
        if n == 0 {
            break;
        }
        let data = bincode::serialize(&shared::ServerCommand::FilePart(
            file_name.to_string(),
            buf[0..n].to_vec(),
            chunk_n,
            file_length,
            n as u32,
        )).unwrap();

        stream.write_all(&(data.len() as u32).to_le_bytes()).await?;
        stream.write_all(&data).await?;
        chunk_n += 1;
    }
    
    let _ = stream.finish().await;
    Ok(())
}