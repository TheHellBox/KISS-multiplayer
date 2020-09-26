use std::net::{SocketAddr, Ipv4Addr, IpAddr};
use futures::{StreamExt};
use tokio::io::{AsyncWriteExt, AsyncReadExt};
use tokio::net::TcpListener;

#[tokio::main]
async fn main() {
    let addr = &"0.0.0.0:1234".parse::<SocketAddr>().unwrap();
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
        let tls_cfg = std::sync::Arc::get_mut(&mut client_cfg.crypto).unwrap();
        tls_cfg
            .dangerous()
            .set_certificate_verifier(std::sync::Arc::new(AcceptAnyCertificate));
        endpoint.default_client_config(client_cfg);
        let (endpoint, _) = endpoint.bind(&SocketAddr::new(IpAddr::from(Ipv4Addr::UNSPECIFIED), 0)).unwrap();
        let mut connection = endpoint
            .connect(
                addr,
                "kissmp",
            )
            .unwrap()
            .await
            .unwrap();
        // That's some stupid naming
        let stream_connection = connection.connection.clone();
        tokio::spawn(async move {
            let mut buffer = [0; 1];
            while let Ok(_) = reader.read_exact(&mut buffer).await {
                let mut stream = stream_connection.open_uni().await.unwrap();
                // buffer_a represents data_type. I named it so it's more convinient to merge with buffer_b
                let mut buffer_a = vec![0; 1];
                reader.read_exact(&mut buffer_a).await.unwrap();
                let mut len_buf = [0; 4];
                reader.read_exact(&mut len_buf).await.unwrap();
                let len = i32::from_le_bytes(len_buf) as usize;
                let mut buffer_b = vec![0; len];
                reader.read_exact(&mut buffer_b).await.unwrap();
                buffer_a.append(&mut len_buf.to_vec());
                buffer_a.append(&mut buffer_b);
                stream.write_all(&buffer_a).await.unwrap();
                stream.finish().await.unwrap();
            }
        });

        let mut ordered = connection.uni_streams.next().await.unwrap().unwrap();
        loop {
            let mut buffer_a = vec![0; 1];
            ordered.read_exact(&mut buffer_a).await.unwrap();
            let mut len = [0; 4];
            ordered.read_exact(&mut len).await.unwrap();
            let mut buffer_b = vec![0; u32::from_le_bytes(len) as usize];
            ordered.read_exact(&mut buffer_b).await.unwrap();
            buffer_a.append(&mut len.to_vec());
            buffer_a.append(&mut buffer_b);
            writer.write_all(&buffer_a).await.unwrap();
        }
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
