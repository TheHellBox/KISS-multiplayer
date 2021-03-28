pub mod http_proxy;
pub mod discord;
pub mod decoder;
pub mod encoder;

use futures::{StreamExt, TryStreamExt};
use std::net::{IpAddr, Ipv4Addr, SocketAddr, ToSocketAddrs};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

#[derive(Debug, Clone)]
pub struct DiscordState {
    pub server_name: Option<String>,
}

#[tokio::main]
async fn main() {
    let (discord_tx, discord_rx) = tokio::sync::mpsc::channel(10);
    let discord_tx_clone = discord_tx.clone();
    discord::spawn_discord_rpc(discord_rx);
    http_proxy::spawn_http_proxy(discord_tx.clone());

    let addr = &"0.0.0.0:7894".parse::<SocketAddr>().unwrap();
    let mut listener = TcpListener::bind(addr).await.unwrap();
    println!("Bridge is running!");
    while let Ok(conn) = listener.accept().await {
        println!("Attempt to connect to a server");
        let mut discord_tx = discord_tx_clone.clone();
        let stream = conn.0;
        tokio::spawn(async move {
            let (mut reader, mut writer) = tokio::io::split(stream);
            // Receive addr from client
            let mut addr_len = [0; 4];
            reader.read_exact(&mut addr_len).await.unwrap();
            let addr_len = u32::from_le_bytes(addr_len) as usize;
            let mut addr_buffer = vec![0; addr_len];
            reader.read_exact(&mut addr_buffer).await.unwrap();
            let addr_str = String::from_utf8(addr_buffer).unwrap();

            let addr = {
                if let Ok(mut socket_addrs) = addr_str.to_socket_addrs() {
                    socket_addrs.next().unwrap()
                } else {
                    println!("Failed to parse address!");
                    return;
                }
            };
            println!("addr {:?}", addr);
            let mut endpoint = quinn::Endpoint::builder();
            let mut client_cfg = quinn::ClientConfig::default();

            let mut transport = quinn::TransportConfig::default();
            transport
                .max_idle_timeout(Some(std::time::Duration::from_secs(20)))
                .unwrap();
            client_cfg.transport = std::sync::Arc::new(transport);

            let tls_cfg = std::sync::Arc::get_mut(&mut client_cfg.crypto).unwrap();
            tls_cfg
                .dangerous()
                .set_certificate_verifier(std::sync::Arc::new(AcceptAnyCertificate));
            endpoint.default_client_config(client_cfg);
            let (endpoint, _) = endpoint
                .bind(&SocketAddr::new(IpAddr::from(Ipv4Addr::UNSPECIFIED), 0))
                .unwrap();
            let connection = endpoint.connect(&addr, "kissmp").unwrap().await;
            if connection.is_err() {
                // Send connection failed message to the client
                let _ = writer.write_all(&[0]).await;
                println!("Failed to connect to the server");
                return;
            }
            println!("Connection!");
            // Confirm that connection is established
            let _ = writer.write_all(&[1]).await;

            let connection = connection.unwrap();
            // That's some stupid naming
            let stream_connection = connection.connection.clone();
            tokio::spawn(async move {
                let mut buffer = [0; 1];
                while let Ok(_) = reader.read_exact(&mut buffer).await {
                    let reliable = buffer[0] == 1;
                    let mut len_buf = [0; 4];
                    let _ = reader.read_exact(&mut len_buf).await;
                    let len = i32::from_le_bytes(len_buf) as usize;
                    let mut data = vec![0; len];
                    let _ = reader.read_exact(&mut data).await;
                    let mut data = encoder::encode(&data);
                    if !reliable {
                        let _ = stream_connection.send_datagram(data.into());
                        continue;
                    }
                    let len_buf = (data.len() as u32).to_le_bytes();
                    let mut buffer = vec![];
                    buffer.append(&mut len_buf.to_vec());
                    buffer.append(&mut data);
                    if let Ok(mut stream) = stream_connection.open_uni().await {
                        let _ = stream.write_all(&buffer).await;
                    }
                }
                println!("Connection with game is closed");
                stream_connection.close(0u32.into(), b"Client has left the game.");
                discord_tx
                    .send(DiscordState { server_name: None })
                    .await
                    .unwrap();
            });
            if let Err(r) = drive_receive(connection, writer).await {
                let reason = r.to_string();
                println!("Disconnected! Reason: {}", reason);
                //let reason_bytes = reason.into_bytes();
                // Send message type 10(Disconnected) to the game
                /*let _ = writer.write_all(&[10]).await;
                let _ = writer
                    .write_all(&(reason_bytes.len() as u32).to_le_bytes())
                    .await;
                let _ = writer.write_all(&reason_bytes).await;*/
            }
        });
    }
}

pub async fn drive_receive(
    mut connection: quinn::NewConnection,
    mut writer: tokio::io::WriteHalf<tokio::net::TcpStream>,
) -> anyhow::Result<()> {
    let (writer_tx, mut writer_rx) = tokio::sync::mpsc::channel::<Vec<u8>>(10);
    tokio::spawn(async move {
        loop {
            let next = writer_rx.recv().await;
            if let Some(next) = next {
                //println!("Write!");
                writer.write_all(&next).await.unwrap();
            }
            else{
                break;
            }
        }
    });

    let mut datagrams = connection
        .datagrams
        .map(|data| async {
            let mut data: Vec<u8> = data?.to_vec();
            let mut result = vec![];
            let data_len = (data.len() as u32).to_le_bytes();
            result.append(&mut data_len.to_vec());
            result.append(&mut data);
            Ok::<_, anyhow::Error>(result)
        })
        .buffer_unordered(1024);
    loop {
        tokio::select! {
            stream = connection.uni_streams.try_next() => {
                let mut stream = stream?;
                if let Some(stream) = &mut stream {
                    println!("New stream!");
                    let writer_tx = writer_tx.clone();
                    let mut len_buf = [0; 4];
                    stream.read_exact(&mut len_buf).await?;
                    let len = u32::from_le_bytes(len_buf);
                    let mut buffer = vec![0; len as usize];
                    stream.read_exact(&mut buffer).await?;
                    println!("Finished");
                    decoder::decode(&buffer, writer_tx).await;
                }
                else{
                    return Err(anyhow::Error::msg("Connection lost"));
                }
            },
            data = datagrams.select_next_some() => {
                let writer_tx = writer_tx.clone();
                let data = data?;
                //println!("data {:?}", data);
                decoder::decode(&data[4..], writer_tx).await;
            }
        };
    }
}

struct AcceptAnyCertificate;

impl rustls::ServerCertVerifier for AcceptAnyCertificate {
    fn verify_server_cert(
        &self,
        _roots: &rustls::RootCertStore,
        _presented_certs: &[rustls::Certificate],
        _dns_name: webpki::DNSNameRef,
        _ocsp_response: &[u8],
    ) -> Result<rustls::ServerCertVerified, rustls::TLSError> {
        Ok(rustls::ServerCertVerified::assertion())
    }
}
