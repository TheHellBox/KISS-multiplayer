use crate::*;
use std::io::Read;

const CHUNK_SIZE: usize = 4096;

pub async fn transfer_file(
    stream: &mut quinn::SendStream,
    path: &std::path::Path,
) -> anyhow::Result<()> {
    let mut file = std::fs::File::open(path)?;
    let metadata = file.metadata()?;

    let file_name = path.file_name().unwrap().to_str().unwrap();
    let mut header = vec![];
    header.append(&mut (metadata.len() as u32).to_le_bytes().to_vec());
    header.append(&mut file_name.as_bytes().to_vec());
    send(stream, 9, &header).await?;

    let mut buf = [0; CHUNK_SIZE];
    while let Ok(n) = file.read(&mut buf) {
        if n == 0 {
            break;
        }
        stream.write_all(&buf[0..n]).await?;
        // Should limit download speed
        std::thread::sleep(std::time::Duration::from_millis(1));
    }
    Ok(())
}
