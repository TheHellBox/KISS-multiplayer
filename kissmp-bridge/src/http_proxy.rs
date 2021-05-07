use percent_encoding::percent_decode_str;
use std::net::Ipv4Addr;
use serde::Deserialize;

#[derive(Deserialize)]
struct ServerHostData {
    name: String,
    max_players: u8,
    map: String,
    mods: Option<Vec<String>>,
    port: u16,
}

pub async fn spawn_http_proxy(mut discord_tx: std::sync::mpsc::Sender<crate::DiscordState>) {
    // Master server proxy
    //println!("start");
    let server = tiny_http::Server::http("0.0.0.0:3693").unwrap();
    let mut destroyer: Option<tokio::sync::oneshot::Sender<()>> = None;
    loop {
        for request in server.incoming_requests() {
            let addr = request.remote_addr();
            if addr.ip() != Ipv4Addr::new(127, 0, 0, 1) {
                continue;
            }
            let mut url = request.url().to_string();
            //println!("{:?}", url);
            url.remove(0);
            if url == "check" {
                let response = tiny_http::Response::from_string("ok");
                request.respond(response).unwrap();
                continue;
            }
            if url.starts_with("rich_presence") {
                let server_name_encoded = url.replace("rich_presence/", "");
                let data = percent_decode_str(&server_name_encoded)
                    .decode_utf8_lossy()
                    .into_owned();
                let server_name = {
                    if data != "none" {
                        Some(data)
                    } else {
                        None
                    }
                };
                let state = crate::DiscordState { server_name };
                let _ = discord_tx.send(state);
                let response = tiny_http::Response::from_string("ok");
                request.respond(response).unwrap();
                continue;
            }
            if url.starts_with("host") {
                let data = url.replace("host/", "");
                let data = percent_decode_str(&data)
                    .decode_utf8_lossy()
                    .into_owned();
                if let Some(destroyer) = destroyer {
                    let _ = destroyer.send(());
                }
                let (destroyer_tx, destroyer_rx) = tokio::sync::oneshot::channel();
                destroyer = Some(destroyer_tx);
                std::thread::spawn(move || {
                    let data: ServerHostData = serde_json::from_str(&data).unwrap();
                    let config = kissmp_server::config::Config{
                        server_name: data.name,
                        max_players: data.max_players,
                        map: data.map,
                        port: data.port,
                        mods: data.mods,
                        ..Default::default()
                    };
                    let rt = tokio::runtime::Runtime::new().unwrap();
                    rt.block_on(async move {
                        let server = kissmp_server::Server::from_config(config);
                        server.run(false, destroyer_rx).await;
                    });
                });
                let response = tiny_http::Response::from_string("ok");
                request.respond(response).unwrap();
                continue;
            }
            if let Ok(response) = reqwest::get(&url).await {
                if let Ok(text) = response.text().await {
                    let response = tiny_http::Response::from_string(text);
                    request.respond(response).unwrap();
                }
            }
        }
    }
}
