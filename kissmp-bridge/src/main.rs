pub mod discord;
pub mod http_proxy;
pub mod voice_chat;


use anyhow::Context;
use futures::stream::FuturesUnordered;
use futures::StreamExt;
use tokio::fs::{File, self, OpenOptions};
use std::collections::HashMap;
use std::collections::hash_map::Entry;
use std::error::Error;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, ToSocketAddrs};
use std::path::{Path, PathBuf};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, WriteHalf, BufWriter};
use tokio::net::{TcpListener, TcpStream};
use std::sync::Arc;
use tokio::sync::Mutex;
#[macro_use]
extern crate log;

const SERVER_IDLE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(120);
const CONNECTED_BYTE: &[u8] = &[1];

type ArcMutex<T> = Arc<Mutex<T>>;

type ActiveDownloadsHashMap = HashMap<String, ActiveDownload>;
struct ActiveDownload {
    path: PathBuf,
    writer: BufWriter<File>,
    recieved: u32,
    file_size: u32
}

impl ActiveDownload {
    fn new(path: PathBuf, writer: BufWriter<File>, file_size: u32) -> Self { Self { path, writer, recieved: 0, file_size } }
}

#[derive(Debug)]
struct JsonParseError {
    data: Vec<u8>,
    source: serde_json::Error
}

impl JsonParseError {
    fn new(data: Vec<u8>, source: serde_json::Error) -> Self { Self { data, source } }
}

impl std::fmt::Display for JsonParseError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Could not parse JSON")
    }
}

impl Error for JsonParseError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        Some(&self.source)
    }
}

#[derive(Debug, Clone)]
pub struct DiscordState {
    pub server_name: Option<String>,
}

async fn read_pascal_bytes<R: AsyncRead + Unpin>(
    stream: &mut R
) -> anyhow::Result<Vec<u8>> {
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
) -> anyhow::Result<()>{
    let len = bytes.len() as u32;
    let mut data = Vec::with_capacity(len as usize + 4);
    data.append(&mut len.to_le_bytes().to_vec());
    data.append(bytes);
    Ok(stream.write_all(&data).await?)
}


fn correct_path_for_unix(path: &Path) -> PathBuf {
    dirs::home_dir()
        .unwrap()
        .join(".steam/steam/steamapps/compatdata/284160/pfx/drive_c/")
        .join(
            path.to_str()
                .unwrap()
                .to_string()
                .replace(r#"C:\"#, "")
                .replace(r#"\"#, "/")
        )
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

        info!("Getting initial state...");

        let initial_state = match read_client_command(&mut client_stream).await {
            Ok((_, c)) => {
                if let shared::ClientCommand::StateUpdate(initial_state) = c {
                    initial_state
                } else {
                    error!("Client replied back with a different command instead of providing the state.");
                    error!("{:?}", c);
                    continue;
                }
            },
            Err(e) => {
                error!("Could not get a response back from the client: {:?}", e);
                continue;
            },
        };

        if cfg!(unix) && !initial_state.disregard_unix_path_correction {
            warn!(
                "We are going to change the given path from the mod to a compatiable path of the most common Steam Proton prefix. This case this path will be:\n{}",
                correct_path_for_unix(&Path::new(&initial_state.download_directory).to_path_buf()).to_string_lossy()
            );
        }

        info!("Connecting to {}...", addr);
        connect_to_server(initial_state, addr, client_stream, discord_tx.clone()).await;
    }
}

async fn connect_to_server(
    initial_state: shared::State,
    addr: SocketAddr,
    client_stream: TcpStream,
    discord_tx: std::sync::mpsc::Sender<DiscordState>
) -> () {
    let endpoint = {
        let mut client_cfg = quinn::ClientConfig::default();
    
        let mut transport = quinn::TransportConfig::default();
        transport
            .max_idle_timeout(Some(SERVER_IDLE_TIMEOUT))
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

    let _ = client_stream_writer.write_all(CONNECTED_BYTE).await;
    
    let (client_event_sender, client_event_receiver) =
        tokio::sync::mpsc::unbounded_channel::<(bool, shared::ClientCommand)>();
    let (server_commands_sender, server_commands_receiver) =
        tokio::sync::mpsc::channel::<shared::ServerCommand>(256);
    let (vc_recording_sender, vc_recording_receiver) =
        std::sync::mpsc::channel();
    let (vc_playback_sender, vc_playback_receiver) =
        std::sync::mpsc::channel();

    // TODO: Use a struct that can hold either a JoinHandle or a bare future so
    // additional tasks that do not depend on using tokio::spawn can be added.
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
        let state: ArcMutex<shared::State> = Arc::new(Mutex::new(initial_state));
        let mut active_downloads: ActiveDownloadsHashMap = HashMap::new();
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
                &state,
                server_commands_receiver,
                client_stream_writer),
            client_incoming(
                &state,
                server_connection.connection.clone(),
                vc_playback_sender.clone(),
                client_stream_reader,
                vc_recording_sender,
                client_event_sender),
            server_outgoing(
                &state,
                server_connection.connection.clone(),
                client_event_receiver),
            server_incoming(
                &state,
                server_commands_sender,
                vc_playback_sender,
                server_connection,
                &mut active_downloads
            ),

        ) {
            Ok(_) => debug!("Tasks completed successfully"),
            Err(e) => {
                if let Some(source) = e.source() {
                    error!("Tasks ended due to exception: {}\nSource: {}", e, source)
                } else {
                    error!("Tasks ended due to exception: {}", e)
                }
            },
        }
        if active_downloads.len() > 0 {
            warn!("Unfinished downloads. Deleting...");
            for (name, ActiveDownload { path, ..}) in active_downloads {
                warn!("Deleting {}", name);
                if let Err(e) = fs::remove_file(path).await {
                    error!("Failed to delete unfinished download {}: {}", name, e);
                }
            }
        };
        discord_tx.send(DiscordState { server_name: None }).unwrap();
    });
}

fn server_command_to_client_bytes(command: shared::ServerCommand) -> Vec<u8> {
    match command {
        shared::ServerCommand::FilePart(..) => panic!("The client no longer handles file downloads directly."),
        shared::ServerCommand::VoiceChatPacket(..) => panic!("Voice packets have to handled by the bridge itself."),
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

async fn client_outgoing(
    _state: &ArcMutex<shared::State>,
    mut server_commands_receiver: tokio::sync::mpsc::Receiver<shared::ServerCommand>,
    mut client_stream_writer: WriteHalf<TcpStream>
) -> anyhow::Result<()> {
    while let Some(server_command) = server_commands_receiver.recv().await {
        client_stream_writer.write_all(&server_command_to_client_bytes(server_command)).await?;
    }
    debug!("Server outgoing closed");
    Ok(())
}

async fn server_incoming(
    state: &ArcMutex<shared::State>,
    server_commands_sender: tokio::sync::mpsc::Sender<shared::ServerCommand>,
    vc_playback_sender: std::sync::mpsc::Sender<voice_chat::VoiceChatPlaybackEvent>,
    server_connection: quinn::generic::NewConnection<quinn::crypto::rustls::TlsSession>,
    active_downloads: &mut ActiveDownloadsHashMap
) -> anyhow::Result<()> {
    // Shorthand
    let command_from_bytes = |b: &[u8]| -> anyhow::Result<shared::ServerCommand> {
        Ok(bincode::deserialize::<shared::ServerCommand>(b)?)
    };

    let mut reliable_commands = server_connection
        .uni_streams
        .map(|stream| async {
            anyhow::Ok(
                command_from_bytes(read_pascal_bytes(&mut stream?).await?.as_slice())
            )
        });

    let mut unreliable_commands = server_connection
        .datagrams
        .map(|data| async {
            anyhow::Ok(
                command_from_bytes(data?.as_ref())?
            )
        })
        .buffer_unordered(1024);

    loop {
        let command: shared::ServerCommand =
            tokio::select! {
                Some(reliable_command) = reliable_commands.next() => {
                    reliable_command.await??
                },
                Some(unreliable_command) = unreliable_commands.next() => {
                    unreliable_command?
                },
                else => break
            };

        match command {
            shared::ServerCommand::VoiceChatPacket(client, pos, data) =>{
                let _ = vc_playback_sender.send(voice_chat::VoiceChatPlaybackEvent::Packet(
                    client, pos, data,
                ));
            },
            shared::ServerCommand::FilePart(name, data, chunk_n, file_size, sent) => {
                let mut entry = active_downloads.entry(name.clone());
                let ActiveDownload { writer, recieved, file_size, .. } = match entry {
                    Entry::Occupied(ref mut occupied) => {
                        occupied.get_mut()
                    },
                    Entry::Vacant(vacant) => {
                        let name_ref = vacant.key();
                        if !name_ref.ends_with(".zip") {
                            return Err(anyhow::Error::msg(format!("The server tried to send something other than a zip: {}", name_ref)))
                        }

                        if chunk_n != 0 {
                            return Err(anyhow::Error::msg("A download was started mid transfer."))
                        }

                        let s = &state.lock().await;
                        let download_directory: PathBuf = {
                            if cfg!(unix) && !s.disregard_unix_path_correction {
                                // For the forseeable future, BeamNG is going to be a Windows binary inside Proton so this will always be applied when on Linux.
                                correct_path_for_unix(&Path::new(&s.download_directory).to_path_buf())
                            } else {
                                Path::new(&s.download_directory).to_path_buf()
                            }
                        };
        
                        let path = download_directory.join(name_ref);

                        let f = OpenOptions::new()
                            .write(true)
                            .create_new(true)
                            .open(&path).await
                            .with_context(|| format!("Could not create file for download: {}", name_ref))?;

                        // Allocate space to catch low storage early
                        f.set_len(file_size as u64).await?;

                        vacant.insert(ActiveDownload::new(
                            path,
                            BufWriter::new(f),
                            file_size
                        ))
                    },
                };
                writer.write(&data).await.context("Failed to write bytes to file that is being downloaded.")?;
                *recieved += sent;
                let r = *recieved;
                let s = *file_size;
                if r >= s {
                    writer.flush().await
                        .with_context(|| format!("Failed to flush bytes to file that finished downloading: {}", name))?;
                    active_downloads.remove(&name);
                }
                server_commands_sender.send(shared::ServerCommand::DownloadProgress(name, r, s)).await?;
            }
            shared::ServerCommand::StateUpdate(..) => {
                error!("Server tried to update the state of the client! Are we connected to a evil server?");
            }
            _ => server_commands_sender.send(command).await?
        };
    };

    debug!("Server incoming closed");
    Ok(())
}

/**
    Reads bytes from the client and returns the command the client is trying to send and if it should be sent reliably to the server (if applicable.)
*/ 
async fn read_client_command(
    client_stream_reader: &mut (impl AsyncRead + std::marker::Unpin)
) -> anyhow::Result<(bool, shared::ClientCommand)> {
    let reliable = {
        let mut buffer = [0; 1];
        client_stream_reader.read_exact(&mut buffer).await?;
        buffer[0] == 1
    };
    let data_size = {
        let mut buffer = [0; 4];
        client_stream_reader.read_exact(&mut buffer).await?;
        i32::from_le_bytes(buffer) as usize
    };
    let mut data_buf = vec![0; data_size];
    client_stream_reader.read_exact(&mut data_buf).await?;
    Ok((
        reliable,
        serde_json::from_slice::<shared::ClientCommand>(&data_buf)
            .map_err(|e| JsonParseError::new(data_buf, e))?
    ))
}

async fn client_incoming(
    state: &ArcMutex<shared::State>,
    server_stream: quinn::generic::Connection<quinn::crypto::rustls::TlsSession>,
    vc_playback_sender: std::sync::mpsc::Sender<voice_chat::VoiceChatPlaybackEvent>,
    mut client_stream_reader: tokio::io::ReadHalf<TcpStream>,
    vc_recording_sender: std::sync::mpsc::Sender<voice_chat::VoiceChatRecordingEvent>,
    client_event_sender: tokio::sync::mpsc::UnboundedSender<(bool, shared::ClientCommand)>
) -> anyhow::Result<()> {
    loop {
        let (reliable, client_command) = match read_client_command(&mut client_stream_reader).await {
            Ok(c) => c,
            Err(e) => {
                if let Some(e_json) = e.downcast_ref::<JsonParseError>() {
                    let source = e_json.source().unwrap();
                    error!("Error decoding json: {:?}", source);
                    error!("Data recieved:\n{:?}", String::from_utf8(e_json.data.clone()));
                    continue;
                } else if let Some(e_io) = e.downcast_ref::<tokio::io::Error>() {
                    match e_io.kind() {
                        // Stream must be closing.
                        std::io::ErrorKind::UnexpectedEof => {
                            break;
                        }
                        _ => {
                            error!("IO error: {:?}", e);
                            break;
                        }
                    }
                } else {
                    error!("Other error: {:?}", e);
                    break;
                }
            },
        };

        match client_command {
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
            shared::ClientCommand::StateUpdate(new_state) => {
                let mut s = state.lock().await;
                *s = new_state;
            }
            _ => client_event_sender.send((reliable, client_command)).unwrap(),
        }
    }
    info!("Connection with game is closed");
    server_stream.close(0u32.into(), b"Client has left the game.");
    debug!("Client incoming closed");
    Ok(())
}

async fn server_outgoing(
    _state: &ArcMutex<shared::State>,
    server_stream: quinn::generic::Connection<quinn::crypto::rustls::TlsSession>,
    mut client_event_receiver: tokio::sync::mpsc::UnboundedReceiver<(bool, shared::ClientCommand)>
)  -> anyhow::Result<()> {
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
