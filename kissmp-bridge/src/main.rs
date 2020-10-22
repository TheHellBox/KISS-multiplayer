use futures::{StreamExt, TryStreamExt};
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

#[tokio::main]
async fn main() {
    // Master server proxy
    tokio::spawn(async {
        let server = tiny_http::Server::http("0.0.0.0:3693").unwrap();
        for request in server.incoming_requests() {
            let mut url = request.url().to_string();
            url.remove(0);
            if url == "check" {
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
    while let Ok(conn) = listener.accept().await {
        let stream = conn.0;
        let (mut reader, mut writer) = tokio::io::split(stream);
        // Receive addr from client
        let mut addr_len = [0; 4];
        reader.read_exact(&mut addr_len).await.unwrap();
        let addr_len = u32::from_le_bytes(addr_len) as usize;
        let mut addr_buffer = vec![0; addr_len];
        reader.read_exact(&mut addr_buffer).await.unwrap();
        let addr_str = String::from_utf8(addr_buffer).unwrap();
        let addr = &addr_str.parse::<SocketAddr>().unwrap();

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
        let mut connection = endpoint.connect(addr, "kissmp").unwrap().await.unwrap();
        // That's some stupid naming
        let stream_connection = connection.connection.clone();
        tokio::spawn(async move {
            let mut buffer = [0; 1];
            while let Ok(_) = reader.read_exact(&mut buffer).await {
                let reliable = buffer[0] == 1;
                let mut buffer_a = vec![0; 1];
                reader.read_exact(&mut buffer_a).await.unwrap();
                let mut len_buf = [0; 4];
                reader.read_exact(&mut len_buf).await.unwrap();
                let len = i32::from_le_bytes(len_buf) as usize;
                let mut data = vec![0; len];
                reader.read_exact(&mut data).await.unwrap();
                if !reliable {
                    buffer_a.append(&mut data);
                    stream_connection.send_datagram(buffer_a.into()).unwrap();
                    continue;
                }
                buffer_a.append(&mut len_buf.to_vec());
                buffer_a.append(&mut data);
                let mut stream = stream_connection.open_uni().await.unwrap();
                stream.write_all(&buffer_a).await.unwrap();
                //stream.finish().await.unwrap();
            }
        });

        //let mut ordered = connection.uni_streams.next().await.unwrap().unwrap();
        tokio::spawn(async move {
            /*let mut cmds = connection
                .uni_streams
                .map(|stream| async {
                    let mut stream = stream?;
                    let mut buf = [0; 1024];
                    let mut result = vec![];
                    while let Some(n) = stream.read(&mut buf).await? {
                        println!("read {}", n);
                        result = buf[0..n].to_vec();
                        writer.write_all(&result).await.unwrap();
                        break;
                    }
                    Ok::<_, anyhow::Error>(result)
                })
                .buffer_unordered(16);
            let mut datagrams = connection
                .datagrams
                .map(|data| async {
                    let mut data: Vec<u8> = data.unwrap().to_vec();
                    let mut result = vec![data.remove(0)];
                    let data_len = (data.len() as u32).to_le_bytes();
                    result.append(&mut data_len.to_vec());
                    result.append(&mut data);
                    Ok::<_, anyhow::Error>(result)
                })
                .buffer_unordered(32);
            loop {
                tokio::select! {
                    data = cmds.select_next_some() => {
                        let data = data.unwrap();
                        //writer.write_all(&data).await.unwrap();
                    }
                    data = datagrams.select_next_some() => {
                        let data = data.unwrap();
                        writer.write_all(&data).await.unwrap();
                    }
                }
        }*/
            let mut datagrams = connection
                .datagrams
                .map(|data| async {
                    let mut data: Vec<u8> = data.unwrap().to_vec();
                    let mut result = vec![data.remove(0)];
                    let data_len = (data.len() as u32).to_le_bytes();
                    result.append(&mut data_len.to_vec());
                    result.append(&mut data);
                    Ok::<_, anyhow::Error>(result)
                })
                .buffer_unordered(32);
            loop{
                tokio::select!{
                    stream = connection.uni_streams.try_next() => {
                        let mut stream = stream.unwrap().unwrap();
                        let mut buf = [0; 1024];
                        while let Some(n) = stream.read(&mut buf).await.unwrap() {
                            if n == 0 {
                                break
                            }
                            writer.write_all(&buf[0..n].to_vec()).await.unwrap();
                        }
                    },
                    data = datagrams.select_next_some() => {
                        let data = data.unwrap();
                        writer.write_all(&data).await.unwrap();
                    }
                }
            }
        });
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
