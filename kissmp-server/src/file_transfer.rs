use crate::*;
use tokio::io::AsyncReadExt;

const CHUNK_SIZE: usize = 65536;

// FIXME
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
    while let Ok(n) = file.read(&mut buf).await {
        if n == 0 {
            break;
        }
        let mut stream = connection.open_uni().await?;
        send(&mut stream, &bincode::serialize(&shared::ServerCommand::FilePart(
            file_name.to_string(),
            buf[0..n].to_vec(),
            chunk_n,
            file_length,
            n as u32
        )).unwrap()).await?;
        stream.finish();
        chunk_n += 1;
    }
    Ok(())
}
