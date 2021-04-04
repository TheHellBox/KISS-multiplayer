pub mod decoder;
pub mod discord;
pub mod encoder;
pub mod http_proxy;
pub mod voice_chat;

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
    let (discord_tx, discord_rx) = std::sync::mpsc::channel();
    let discord_tx_clone = discord_tx.clone();
    discord::spawn_discord_rpc(discord_rx).await;
    tokio::spawn(async move {
        http_proxy::spawn_http_proxy(discord_tx).await;
    });
    let addr = &"0.0.0.0:7894".parse::<SocketAddr>().unwrap();
    let listener = TcpListener::bind(addr).await.unwrap();
    println!("Bridge is running!");
    while let Ok(conn) = listener.accept().await {
        println!("Attempt to connect to a server");
        let discord_tx = discord_tx_clone.clone();
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
            let mut endpoint = quinn::Endpoint::builder();
            let mut client_cfg = quinn::ClientConfig::default();

            let mut transport = quinn::TransportConfig::default();
            transport
                .max_idle_timeout(Some(std::time::Duration::from_secs(120)))
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
            let stream_connection = connection.connection.clone();
            let (sender_tx, mut sender_rx) =
                tokio::sync::mpsc::unbounded_channel::<(bool, shared::ClientCommand)>();
            tokio::spawn(async move {
                while let Some((reliable, next)) = sender_rx.recv().await {
                    let mut data = encoder::encode(&next);
                    if !reliable {
                        let _ = stream_connection.send_datagram(data.into());
                        continue;
                    }
                    let len_buf = (data.len() as u32).to_le_bytes();
                    let mut buffer = vec![];
                    buffer.append(&mut len_buf.to_vec());
                    buffer.append(&mut data);
                    if let Ok(mut stream) = stream_connection.open_uni().await {
                        stream.write_all(&buffer).await.unwrap();
                    } else {
                        break;
                    }
                }
            });
            let stream_connection = connection.connection.clone();
            let (vc_rc_writer, vc_rc_reader) = std::sync::mpsc::channel();
            let _ = voice_chat::run_vc_recording(sender_tx.clone(), vc_rc_reader);
            let (vc_pb_writer, vc_pb_reader) = std::sync::mpsc::channel();
            voice_chat::run_vc_playback(vc_pb_reader);
            let vc_pb_writer_c = vc_pb_writer.clone();
            tokio::spawn(async move {
                let mut buffer = [0; 1];
                while let Ok(_) = reader.read_exact(&mut buffer).await {
                    let reliable = buffer[0] == 1;
                    let mut len_buf = [0; 4];
                    let _ = reader.read_exact(&mut len_buf).await;
                    let len = i32::from_le_bytes(len_buf) as usize;
                    let mut data = vec![0; len];
                    let _ = reader.read_exact(&mut data).await;
                    let decoded = serde_json::from_slice::<shared::ClientCommand>(&data);
                    if let Ok(decoded) = decoded {
                        match decoded {
                            shared::ClientCommand::SpatialUpdate(left_ear, right_ear) => {
                                let _ = vc_pb_writer_c.send(
                                    voice_chat::VoiceChatPlaybackEvent::PositionUpdate(
                                        left_ear, right_ear,
                                    ),
                                );
                            }
                            shared::ClientCommand::StartTalking => {
                                let _ =
                                    vc_rc_writer.send(voice_chat::VoiceChatRecordingEvent::Start);
                            }
                            shared::ClientCommand::EndTalking => {
                                let _ = vc_rc_writer.send(voice_chat::VoiceChatRecordingEvent::End);
                            }
                            _ => sender_tx.send((reliable, decoded)).unwrap(),
                        };
                    } else {
                        println!("error decoding json {:?}", decoded);
                        println!("{:?}", String::from_utf8(data));
                    }
                }
                println!("Connection with game is closed");
                stream_connection.close(0u32.into(), b"Client has left the game.");
                discord_tx.send(DiscordState { server_name: None }).unwrap();
            });
            let (writer_tx, writer_rx) = tokio::sync::mpsc::channel::<Vec<u8>>(128);
            if let Err(r) = drive_receive(
                connection,
                writer,
                writer_tx.clone(),
                writer_rx,
                vc_pb_writer,
            )
            .await
            {
                let reason = r.to_string();
                println!("Disconnected! Reason: {}", reason);
                let reason_bytes = reason.into_bytes().to_vec();
                let mut result = vec![2];
                result.append(&mut (reason_bytes.len() as u32).to_le_bytes().to_vec());
                result.append(&mut reason_bytes.to_vec());
                let _ = writer_tx.send(result).await.unwrap();
            }
        });
    }
}

pub async fn drive_receive(
    mut connection: quinn::NewConnection,
    mut writer: tokio::io::WriteHalf<tokio::net::TcpStream>,
    writer_tx: tokio::sync::mpsc::Sender<Vec<u8>>,
    mut writer_rx: tokio::sync::mpsc::Receiver<Vec<u8>>,
    vc_pb_writer: std::sync::mpsc::Sender<voice_chat::VoiceChatPlaybackEvent>,
) -> anyhow::Result<()> {
    tokio::spawn(async move {
        while let Some(next) = writer_rx.recv().await {
            let _ = writer.write_all(&next).await;
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
                    let writer_tx = writer_tx.clone();
                    let mut len_buf = [0; 4];
                    stream.read_exact(&mut len_buf).await?;
                    let len = u32::from_le_bytes(len_buf);
                    let mut buffer = vec![0; len as usize];
                    stream.read_exact(&mut buffer).await?;
                    decoder::decode(&buffer, writer_tx, None).await;
                }
                else{
                    return Err(anyhow::Error::msg("Connection lost"));
                }
            },
            data = datagrams.select_next_some() => {
                let writer_tx = writer_tx.clone();
                let data = data?;
                //println!("data {:?}", data);
                let vc_pb_writer = vc_pb_writer.clone();
                decoder::decode(&data[4..], writer_tx, Some(vc_pb_writer)).await;
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
