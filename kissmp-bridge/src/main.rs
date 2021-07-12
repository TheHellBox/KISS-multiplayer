pub mod discord;
pub mod http_proxy;
pub mod voice_chat;

use futures::stream::FuturesUnordered;
use futures::{StreamExt};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, ToSocketAddrs};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, WriteHalf};
use tokio::net::{TcpListener, TcpStream};
#[macro_use]
extern crate log;

const SERVER_IDLE_TIMEOUT: u64 = 120;

#[derive(Debug, Clone)]
pub struct DiscordState {
    pub server_name: Option<String>,
}

async fn read_pascal_bytes<R: AsyncRead + Unpin>(
    stream: &mut R
) -> Result<Vec<u8>, anyhow::Error> {
    let mut buffer = [0; 4];
    stream.read_exact(&mut buffer).await?;
    let len = u32::from_le_bytes(buffer) as usize;
    let mut buffer = vec![0; len];
    stream.read_exact(&mut buffer).await?;
    Ok(buffer)
}

async fn write_pascal_bytes<W: AsyncWrite + Unpin>(
    stream: &mut W,
    bytes: &mut Vec<u8>
) -> Result<(), anyhow::Error>{
    let len = bytes.len() as u32;
    let mut data = Vec::with_capacity(len as usize + 4);
    data.append(&mut len.to_le_bytes().to_vec());
    data.append(bytes);
    Ok(stream.write_all(&data).await?)
}

#[tokio::main]
async fn main() {
    shared::init_logging();

    let (discord_tx, discord_rx) = std::sync::mpsc::channel();
    discord::spawn_discord_rpc(discord_rx).await;
    {
        let discord_tx = discord_tx.clone();
        tokio::spawn(async move {
            http_proxy::spawn_http_proxy(discord_tx).await;
        });
    }
    let bind_addr = SocketAddr::from((Ipv4Addr::UNSPECIFIED, 7894));
    let listener = TcpListener::bind(bind_addr).await.unwrap();
    info!("Bridge is running!");
    while let Ok((mut client_stream, _)) = listener.accept().await {

        info!("Attempting to connect to a server...");

        let addr = {
            let address_string = 
                String::from_utf8(
                    read_pascal_bytes(&mut client_stream).await.unwrap()
                ).unwrap();

            let mut socket_addrs = match address_string.to_socket_addrs() {
                    Ok(socket_addrs) => socket_addrs,
                    Err(e) => {
                        error!("Failed to parse address: {}", e);
                        continue;
                    },
                };
            match socket_addrs.next() {
                Some(addr) => addr,
                None => {
                    error!("Could not find address: {}", address_string);
                    continue;
                },
            }
        };

        info!("Connecting to {}...", addr);
        connect_to_server(addr, client_stream, discord_tx.clone()).await;
    }
}

async fn connect_to_server(
    addr: SocketAddr,
    client_stream: TcpStream,
    discord_tx: std::sync::mpsc::Sender<DiscordState>
) -> () {
    let endpoint = {
        let mut client_cfg = quinn::ClientConfig::default();
    
        let mut transport = quinn::TransportConfig::default();
        transport
            .max_idle_timeout(Some(std::time::Duration::from_secs(SERVER_IDLE_TIMEOUT)))
            .unwrap();
        client_cfg.transport = std::sync::Arc::new(transport);
    
        let tls_cfg = std::sync::Arc::get_mut(&mut client_cfg.crypto).unwrap();
        tls_cfg
            .dangerous()
            .set_certificate_verifier(std::sync::Arc::new(AcceptAnyCertificate));
        
        let mut endpoint = quinn::Endpoint::builder();
        endpoint.default_client_config(client_cfg);

        let bind_from = match addr {
            SocketAddr::V4(_) => IpAddr::from(Ipv4Addr::UNSPECIFIED),
            SocketAddr::V6(_) => IpAddr::from(Ipv6Addr::UNSPECIFIED),
        };

        endpoint
            .bind(&SocketAddr::new(bind_from, 0))
            .unwrap().0
    };

    let server_connection = match endpoint.connect(&addr, "kissmp").unwrap().await {
        Ok(c) => c,
        Err(e) => {
            error!("Failed to connect to the server: {}", e);
            return;
        },
    };

    let (client_stream_reader, mut client_stream_writer) =
        tokio::io::split(client_stream);

    // Confirm that connection is established
    let _ = client_stream_writer.write_all(&[1]).await;

    // Get all of our channels set up.
    let (client_event_sender, client_event_receiver) =
        tokio::sync::mpsc::unbounded_channel::<(bool, shared::ClientCommand)>();
    let (server_commands_sender, server_commands_receiver) =
        tokio::sync::mpsc::channel::<shared::ServerCommand>(256);
    let (vc_recording_sender, vc_recording_receiver) =
        std::sync::mpsc::channel();
    let (vc_playback_sender, vc_playback_receiver) =
        std::sync::mpsc::channel();
    
    // Then start up everything.

    let mut non_critical_tasks = FuturesUnordered::new();

    match voice_chat::try_create_vc_playback_task(vc_playback_receiver) {
        Ok(handle) => {
            non_critical_tasks.push(handle);
            debug!("Playback OK")
        },
        Err(e) => {error!("Failed to set up voice chat playback: {}", e)},
    };

    match voice_chat::try_create_vc_recording_task(client_event_sender.clone(), vc_recording_receiver) {
        Ok(handle) => {
            non_critical_tasks.push(handle);
            debug!("Recording OK")
        },
        Err(e) => {error!("Failed to set up voice chat recording: {}", e)},
    };
    
    tokio::spawn(async move {
        debug!("Starting tasks");
        match tokio::try_join!(
            async {
                while let Some(result) = non_critical_tasks.next().await {
                    match result {
                        Err(e) => warn!("Non-critical task failed: {}", e),
                        Ok(Err(e)) => warn!("Non-critical task died with exception: {}", e),
                        _ => ()
                    }
                }
                Ok(())
            },
            client_outgoing(
                server_commands_receiver,
                client_stream_writer),
            client_incoming(
                server_connection.connection.clone(),
                vc_playback_sender.clone(),
                client_stream_reader,
                vc_recording_sender,
                client_event_sender),
            server_outgoing(
                server_connection.connection.clone(),
                client_event_receiver),
            server_incoming(
                server_commands_sender,
                vc_playback_sender,
                server_connection),

        ) {
            Ok(_) => debug!("Tasks completed successfully"),
            Err(e) => warn!("Tasks ended due to exception: {}", e),
        }
        discord_tx.send(DiscordState { server_name: None }).unwrap();
    });
}

fn server_command_to_client_bytes(command: shared::ServerCommand) -> Vec<u8> {
    match command {
        shared::ServerCommand::FilePart(name, data, chunk_n, file_size, data_left) => {
            let name_b = name.as_bytes();
            let mut result = vec![0];
            result.append(&mut (name_b.len() as u32).to_le_bytes().to_vec());
            result.append(&mut name_b.to_vec());
            result.append(&mut chunk_n.to_le_bytes().to_vec());
            result.append(&mut file_size.to_le_bytes().to_vec());
            result.append(&mut data_left.to_le_bytes().to_vec());
            result.append(&mut data.clone());
            result
        }
        shared::ServerCommand::VoiceChatPacket(_, _, _) => panic!("Voice packets have to handled by the bridge itself."),
        _ => {
            let json = serde_json::to_string(&command).unwrap();
            //println!("{:?}", json);
            let mut data = json.into_bytes();
            let mut result = vec![1];
            result.append(&mut (data.len() as u32).to_le_bytes().to_vec());
            result.append(&mut data);
            result
        }
    }
}

type AHResult = Result<(), anyhow::Error>;

async fn client_outgoing(
    mut server_commands_receiver: tokio::sync::mpsc::Receiver<shared::ServerCommand>,
    mut client_stream_writer: WriteHalf<TcpStream>
) -> AHResult {
    while let Some(server_command) = server_commands_receiver.recv().await {
        client_stream_writer.write_all(server_command_to_client_bytes(server_command).as_ref()).await?;
    }
    debug!("Server outgoing closed");
    Ok(())
}

async fn server_incoming(
    server_commands_sender: tokio::sync::mpsc::Sender<shared::ServerCommand>,
    vc_playback_sender: std::sync::mpsc::Sender<voice_chat::VoiceChatPlaybackEvent>,
    server_connection: quinn::generic::NewConnection<quinn::crypto::rustls::TlsSession>
) -> AHResult {
    let mut reliable_commands = server_connection
        .uni_streams
        .map(|stream| async {
            Ok::<_, anyhow::Error>(read_pascal_bytes(&mut stream?).await?)
        });

    let mut unreliable_commands = server_connection
        .datagrams
        .map(|data| async {
            Ok::<_, anyhow::Error>(data?.to_vec())
        })
        .buffer_unordered(1024);

    loop {
        let command_bytes =
            tokio::select! {
                Some(reliable_command) = reliable_commands.next() => {
                    reliable_command.await?
                },
                Some(unreliable_command) = unreliable_commands.next() => {
                    unreliable_command?
                },
                else => break
            };
        let command = bincode::deserialize::<shared::ServerCommand>(command_bytes.as_ref())?;
        match command {
            shared::ServerCommand::VoiceChatPacket(client, pos, data) =>{
                let _ = vc_playback_sender.send(voice_chat::VoiceChatPlaybackEvent::Packet(
                    client, pos, data,
                ));
            },
            _ => server_commands_sender.send(command).await?
        };
    };
    debug!("Server incoming closed");
    Ok(())
}

async fn client_incoming(
    server_stream: quinn::generic::Connection<quinn::crypto::rustls::TlsSession>,
    vc_playback_sender: std::sync::mpsc::Sender<voice_chat::VoiceChatPlaybackEvent>,
    mut client_stream_reader: tokio::io::ReadHalf<TcpStream>,
    vc_recording_sender: std::sync::mpsc::Sender<voice_chat::VoiceChatRecordingEvent>,
    client_event_sender: tokio::sync::mpsc::UnboundedSender<(bool, shared::ClientCommand)>
) -> AHResult {
    let mut buffer = [0; 1];
    while let Ok(_) = client_stream_reader.read_exact(&mut buffer).await {
        let reliable = buffer[0] == 1;
        let mut len_buf = [0; 4];
        let _ = client_stream_reader.read_exact(&mut len_buf).await;
        let len = i32::from_le_bytes(len_buf) as usize;
        let mut data = vec![0; len];
        let _ = client_stream_reader.read_exact(&mut data).await;
        let decoded = serde_json::from_slice::<shared::ClientCommand>(&data);
        if let Ok(decoded) = decoded {
            match decoded {
                shared::ClientCommand::SpatialUpdate(left_ear, right_ear) => {
                    let _ = vc_playback_sender.send(
                        voice_chat::VoiceChatPlaybackEvent::PositionUpdate(
                            left_ear, right_ear,
                        ),
                    );
                }
                shared::ClientCommand::StartTalking => {
                    let _ = vc_recording_sender.send(voice_chat::VoiceChatRecordingEvent::Start);
                }
                shared::ClientCommand::EndTalking => {
                    let _ = vc_recording_sender.send(voice_chat::VoiceChatRecordingEvent::End);
                }
                _ => client_event_sender.send((reliable, decoded)).unwrap(),
            };
        } else {
            error!("error decoding json {:?}", decoded);
            error!("{:?}", String::from_utf8(data));
        }
    }
    info!("Connection with game is closed");
    server_stream.close(0u32.into(), b"Client has left the game.");
    debug!("Client incoming closed");
    Ok(())
}

async fn server_outgoing(
    server_stream: quinn::generic::Connection<quinn::crypto::rustls::TlsSession>,
    mut client_event_receiver: tokio::sync::mpsc::UnboundedReceiver<(bool, shared::ClientCommand)>
)  -> AHResult {
    while let Some((reliable, client_command)) = client_event_receiver.recv().await {
        let mut data = bincode::serialize::<shared::ClientCommand>(&client_command)?;
        if !reliable {
            server_stream.send_datagram(data.into())?;
        } else {
            write_pascal_bytes(&mut server_stream.open_uni().await?, &mut data).await?;
        }
    }
    debug!("Server outgoing closed");
    Ok(())
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
