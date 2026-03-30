use tokio::io::AsyncReadExt;

async fn write_framed(stream: &mut quinn::SendStream, payload: &[u8]) -> anyhow::Result<()> {
    stream.write_all(&(payload.len() as u32).to_le_bytes()).await?;
    stream.write_all(payload).await?;
    Ok(())
}

// FIXME
pub async fn transfer_file(
    connection: quinn::Connection,
    path: &std::path::Path,
    chunk_size: usize,
) -> anyhow::Result<()> {
    let mut file = tokio::fs::File::open(path).await?;
    let metadata = file.metadata().await?;
    let file_length = metadata.len() as u32;
    let file_name = path.file_name().unwrap().to_str().unwrap();
    let mut buf = vec![0u8; chunk_size.max(64 * 1024)];
    let file_name = file_name.to_string();
    let mut chunk_n = 0;
    let mut stream = connection.open_uni().await?;

    loop {
        let n = file.read(&mut buf[..]).await?;
        if n == 0 {
            break;
        }
        let payload = bincode::serialize(&shared::ServerCommand::FilePart(
            file_name.clone(),
            buf[0..n].to_vec(),
            chunk_n,
            file_length,
            n as u32,
        ))
        .unwrap();
        write_framed(&mut stream, &payload).await?;

        chunk_n += 1;
    }

    stream.finish().await?;
    Ok(())
}
