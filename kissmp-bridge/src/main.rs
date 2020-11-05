use futures::{StreamExt, TryStreamExt};
use std::net::{IpAddr, Ipv4Addr, SocketAddr, ToSocketAddrs};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

#[cfg(feature = "discord-rpc-client")]
#[derive(Debug, Clone)]
struct DiscordState {
    server_name: Option<String>,
}

#[tokio::main]
async fn main() {
    #[cfg(feature = "discord-rpc-client")]
    let (mut discord_tx, mut discord_rx) = tokio::sync::mpsc::channel(10);
    #[cfg(feature = "discord-rpc-client")]
    let discord_tx_clone = discord_tx.clone();

    #[cfg(feature = "discord-rpc-client")]
    tokio::spawn(async move {
        let mut drpc_client = discord_rpc_client::Client::new(771278096627662928);
        drpc_client.start();
        let mut state = DiscordState { server_name: None };
        loop {
            std::thread::sleep(std::time::Duration::from_millis(1000));
            for new_state in discord_rx.try_recv() {
                state = new_state;
            }
            if state.server_name.is_none() {
                let _ = drpc_client.clear_activity();
                continue;
            }
            let _ = drpc_client
                .set_activity(|activity| {
                    activity
                        .details(format!("Playing on {}", state.clone().server_name.unwrap()))
                        .assets(|assets| assets.large_image("kissmp_logo").small_text("test"))
                });
        }
    });
   
    // Master server proxy
    tokio::spawn(async move {
        let server = tiny_http::Server::http("0.0.0.0:3693").unwrap();
        for request in server.incoming_requests() {
            let addr = request.remote_addr();
            if addr.ip() != Ipv4Addr::new(127, 0, 0, 1) {
                continue;
            }
            let mut url = request.url().to_string();
            url.remove(0);
            if url == "check" {
                let response = tiny_http::Response::from_string("ok");
                request.respond(response).unwrap();
                continue;
            }
            #[cfg(feature = "discord-rpc-client")]
            if url.starts_with("rich_presence") {
                let data = url.replace("rich_presence/", "").replace("%20", " ");
                let server_name = {
                    if data != "none" {
                        Some(data)
                    } else {
                        None
                    }
                };
                let state = DiscordState { server_name };
                discord_tx.send(state).await.unwrap();
                let response = tiny_http::Response::from_string("ok");
                request.respond(response).unwrap();
                continue;
            }
            let response = reqwest::get(&url).await.unwrap().text().await.unwrap();
            let response = tiny_http::Response::from_string(response);
            request.respond(response).unwrap();
        }
    });
    let addr = &"0.0.0.0:7894".parse::<SocketAddr>().unwrap();
    let mut listener = TcpListener::bind(addr).await.unwrap();
    println!("Bridge is running!");
    while let Ok(conn) = listener.accept().await {
        #[cfg(feature = "discord-rpc-client")]
        let mut discord_tx = discord_tx_clone.clone();

        let stream = conn.0;
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
                continue;
            }
        };

        let mut endpoint = quinn::Endpoint::builder();
        let mut client_cfg = quinn::ClientConfig::default();

        let mut transport = quinn::TransportConfig::default();
        transport
            .max_idle_timeout(Some(std::time::Duration::from_secs(60)))
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
            continue;
        }
        // Confirm that connection is established
        let _ = writer.write_all(&[1]).await;

        let connection = connection.unwrap();
        // That's some stupid naming
        let stream_connection = connection.connection.clone();
        tokio::spawn(async move {
            let mut buffer = [0; 1];
            while let Ok(_) = reader.read_exact(&mut buffer).await {
                let reliable = buffer[0] == 1;
                let mut buffer_a = vec![0; 1];
                let _ = reader.read_exact(&mut buffer_a).await;
                let mut len_buf = [0; 4];
                let _ = reader.read_exact(&mut len_buf).await;
                let len = i32::from_le_bytes(len_buf) as usize;
                let mut data = vec![0; len];
                let _ = reader.read_exact(&mut data).await;
                if !reliable {
                    buffer_a.append(&mut data);
                    let _ = stream_connection.send_datagram(buffer_a.into());
                    continue;
                }
                buffer_a.append(&mut len_buf.to_vec());
                buffer_a.append(&mut data);
                if let Ok(mut stream) = stream_connection.open_uni().await {
                    let _ = stream.write_all(&buffer_a).await;
                }
            }
            println!("Connection with game is closed");
            stream_connection.close(0u32.into(), b"Client has left the game.");
            #[cfg(feature = "discord-rpc-client")]
            discord_tx.send(DiscordState { server_name: None }).await.unwrap();
        });

        //let mut ordered = connection.uni_streams.next().await.unwrap().unwrap();
        tokio::spawn(async move {
            if let Err(r) = drive_receive(connection, &mut writer).await {
                let reason = r.to_string();
                println!("Disconnected! Reason: {}", reason);
                let reason_bytes = reason.into_bytes();
                // Send message type 10(Disconnected) to the game
                let _ = writer.write_all(&[10]).await;
                let _ = writer.write_all(&(reason_bytes.len() as u32).to_le_bytes()).await;
                let _ = writer.write_all(&reason_bytes).await;
            }
        });
    }
}

pub async fn drive_receive(
    mut connection: quinn::NewConnection,
    writer: &mut tokio::io::WriteHalf<tokio::net::TcpStream>,
) -> anyhow::Result<()> {
    let mut datagrams = connection
        .datagrams
        .map(|data| async {
            let mut data: Vec<u8> = data?.to_vec();
            let mut result = vec![data.remove(0)];
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
                    let mut buf = [0; 1024];
                    while let Some(n) = stream.read(&mut buf).await? {
                        if n == 0 {
                            break
                        }
                        let _ = writer.write_all(&buf[0..n].to_vec()).await;
                    }
                }
                else{
                    return Err(anyhow::Error::msg("Connection lost"));
                }
            },
            data = datagrams.select_next_some() => {
                let data = data?;
                let _ = writer.write_all(&data).await;
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
