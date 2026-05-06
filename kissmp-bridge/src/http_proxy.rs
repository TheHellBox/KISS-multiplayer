use percent_encoding::percent_decode_str;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::net::{Ipv4Addr, UdpSocket};
use std::sync::{Arc, Mutex};
use std::time::Instant;

const DISCOVERY_PORT: u16 = 3699;
const DISCOVERY_TTL_SECS: u64 = 8;

#[derive(Deserialize)]
struct ServerHostData {
    name: String,
    max_players: u8,
    map: String,
    mods: Option<Vec<String>>,
    port: u16,
}

#[derive(Serialize, Clone)]
struct HostedServerInfo {
    name: String,
    addr: String,
    map: String,
    player_count: u32,
    max_players: u8,
    is_self: bool,
}

fn get_local_ip() -> String {
    UdpSocket::bind("0.0.0.0:0")
        .and_then(|s| {
            s.connect("8.8.8.8:53")?;
            s.local_addr()
        })
        .map(|addr| addr.ip().to_string())
        .unwrap_or_else(|_| "127.0.0.1".to_string())
}

fn get_machine_name() -> String {
    std::env::var("COMPUTERNAME")
        .or_else(|_| std::env::var("HOSTNAME"))
        .unwrap_or_else(|_| "KissMP Server".to_string())
}

pub async fn spawn_http_proxy(discord_tx: std::sync::mpsc::Sender<crate::DiscordState>) {
    let server = std::sync::Arc::new(tiny_http::Server::http("0.0.0.0:3693").unwrap());

    let destroyer: Arc<Mutex<Option<tokio::sync::oneshot::Sender<()>>>> =
        Arc::new(Mutex::new(None));
    let hosted_info: Arc<Mutex<Option<HostedServerInfo>>> = Arc::new(Mutex::new(None));

    // Mapa de servidores descubiertos en LAN: IP -> (info, ultimo_visto)
    let discovered: Arc<Mutex<HashMap<String, (HostedServerInfo, Instant)>>> =
        Arc::new(Mutex::new(HashMap::new()));

    // Broadcast UDP del servidor hosteado por el bridge (creado desde el juego)
    {
        let hosted_info = hosted_info.clone();
        std::thread::spawn(move || {
            let socket = match UdpSocket::bind("0.0.0.0:0") {
                Ok(s) => s,
                Err(e) => { error!("UDP broadcast socket: {}", e); return; }
            };
            let _ = socket.set_broadcast(true);
            loop {
                if let Some(info) = hosted_info.lock().unwrap().as_ref() {
                    let port = info.addr.split(':').last()
                        .and_then(|p| p.parse::<u16>().ok())
                        .unwrap_or(3698);
                    let packet = format!(
                        r#"{{"name":{},"port":{},"max_players":{},"map":{},"players":{}}}"#,
                        serde_json::to_string(&info.name).unwrap(),
                        port,
                        info.max_players,
                        serde_json::to_string(&info.map).unwrap(),
                        info.player_count,
                    );
                    let data = packet.as_bytes();
                    let _ = socket.send_to(data, format!("255.255.255.255:{}", DISCOVERY_PORT));
                }
                std::thread::sleep(std::time::Duration::from_secs(2));
            }
        });
    }

    // Listener UDP para descubrimiento LAN
    {
        let discovered = discovered.clone();
        std::thread::spawn(move || {
            let socket = match UdpSocket::bind(format!("0.0.0.0:{}", DISCOVERY_PORT)) {
                Ok(s) => s,
                Err(e) => {
                    error!("LAN discovery listener: no se pudo bindear puerto {}: {}", DISCOVERY_PORT, e);
                    return;
                }
            };
            let _ = socket.set_read_timeout(Some(std::time::Duration::from_secs(2)));
            let mut buf = [0u8; 1024];
            info!("LAN discovery escuchando en puerto {}", DISCOVERY_PORT);
            loop {
                match socket.recv_from(&mut buf) {
                    Ok((n, from)) => {
                        let src_ip = from.ip().to_string();
                        if let Ok(v) = serde_json::from_slice::<serde_json::Value>(&buf[..n]) {
                            let port = v["port"].as_u64().unwrap_or(3698) as u16;
                            let info = HostedServerInfo {
                                name: v["name"].as_str().unwrap_or("LAN Server").to_string(),
                                addr: format!("{}:{}", src_ip, port),
                                map: v["map"].as_str().unwrap_or("").to_string(),
                                player_count: v["players"].as_u64().unwrap_or(0) as u32,
                                max_players: v["max_players"].as_u64().unwrap_or(8) as u8,
                                is_self: false,
                            };
                            discovered.lock().unwrap().insert(src_ip, (info, Instant::now()));
                        }
                    }
                    Err(_) => {
                        // Timeout — limpiar entradas viejas
                        let now = Instant::now();
                        discovered.lock().unwrap()
                            .retain(|_, (_, t)| now.duration_since(*t).as_secs() < DISCOVERY_TTL_SECS);
                    }
                }
            }
        });
    }

    loop {
        let server_clone = server.clone();
        let request = match tokio::task::spawn_blocking(move || server_clone.recv()).await {
            Ok(Ok(req)) => req,
            _ => continue,
        };

        let addr = request.remote_addr().unwrap();
        if addr.ip() != Ipv4Addr::new(127, 0, 0, 1) {
            continue;
        }

        let mut url = request.url().to_string();
        url.remove(0);
        let url = url.replace("http:/", "http://").replace("https:/", "https://");

        // ── /check ────────────────────────────────────────────────
        if url == "check" {
            let _ = request.respond(tiny_http::Response::from_string("ok"));
            continue;
        }

        // ── /system/name ──────────────────────────────────────────
        if url == "system/name" {
            let _ = request.respond(tiny_http::Response::from_string(get_machine_name()));
            continue;
        }

        // ── /system/ip ────────────────────────────────────────────
        if url == "system/ip" {
            let _ = request.respond(tiny_http::Response::from_string(get_local_ip()));
            continue;
        }

        // ── /lan/list ─────────────────────────────────────────────
        if url == "lan/list" {
            let mut servers: Vec<HostedServerInfo> = Vec::new();

            // Server hosteado localmente por este bridge
            if let Some(s) = hosted_info.lock().unwrap().as_ref() {
                servers.push(s.clone());
            }

            // Servers descubiertos en la LAN via UDP
            let now = Instant::now();
            for (_, (info, last_seen)) in discovered.lock().unwrap().iter() {
                if now.duration_since(*last_seen).as_secs() < DISCOVERY_TTL_SECS {
                    let already = servers.iter().any(|s| s.addr == info.addr);
                    if !already {
                        servers.push(info.clone());
                    }
                }
            }

            let json = serde_json::to_string(&servers).unwrap_or_else(|_| "[]".to_string());
            let _ = request.respond(tiny_http::Response::from_string(json));
            continue;
        }

        // ── /host/stop ────────────────────────────────────────────
        if url == "host/stop" {
            let mut d = destroyer.lock().unwrap();
            if let Some(tx) = d.take() {
                let _ = tx.send(());
            }
            *hosted_info.lock().unwrap() = None;
            let _ = request.respond(tiny_http::Response::from_string("ok"));
            continue;
        }

        // ── /rich_presence/* ──────────────────────────────────────
        if url.starts_with("rich_presence") {
            let encoded = url.replace("rich_presence/", "");
            let data = percent_decode_str(&encoded)
                .decode_utf8_lossy()
                .into_owned();
            let server_name = if data != "none" { Some(data) } else { None };
            let _ = discord_tx.send(crate::DiscordState { server_name });
            let _ = request.respond(tiny_http::Response::from_string("ok"));
            continue;
        }

        // ── /host/{config} ────────────────────────────────────────
        if url.starts_with("host/") {
            let raw = url.replacen("host/", "", 1);
            let decoded = percent_decode_str(&raw).decode_utf8_lossy().into_owned();

            let data: ServerHostData = match serde_json::from_str(&decoded) {
                Ok(d) => d,
                Err(e) => {
                    error!("Failed to parse host config: {}", e);
                    let _ = request.respond(tiny_http::Response::from_string("error"));
                    continue;
                }
            };

            // Parar el servidor anterior si existe
            {
                let mut d = destroyer.lock().unwrap();
                if let Some(tx) = d.take() {
                    let _ = tx.send(());
                }
            }

            // Guardar info del servidor hosteado
            let local_ip = get_local_ip();
            {
                let mut info = hosted_info.lock().unwrap();
                *info = Some(HostedServerInfo {
                    name: data.name.clone(),
                    addr: format!("{}:{}", local_ip, data.port),
                    map: data.map.clone(),
                    player_count: 0,
                    max_players: data.max_players,
                    is_self: true,
                });
            }

            let (destroyer_tx, destroyer_rx) = tokio::sync::oneshot::channel();
            *destroyer.lock().unwrap() = Some(destroyer_tx);

            let (setup_result_tx, setup_result_rx) = tokio::sync::oneshot::channel();

            std::thread::spawn(move || {
                let config = kissmp_server::config::Config {
                    server_name: data.name,
                    max_players: data.max_players,
                    map: data.map,
                    port: data.port,
                    mods: data.mods,
                    upnp_enabled: true,
                    ..Default::default()
                };
                let rt = tokio::runtime::Runtime::new().unwrap();
                rt.block_on(async move {
                    let server = kissmp_server::Server::from_config(config);
                    server.run(false, destroyer_rx, Some(setup_result_tx)).await;
                });
            });

            let _ = setup_result_rx.await;
            let _ = request.respond(tiny_http::Response::from_string("ok"));
            continue;
        }

        // ── proxy al master server ────────────────────────────────
        if !url.starts_with(&format!("http://{}", shared::MASTER_SERVER))
            && !url.starts_with(&format!("https://{}", shared::MASTER_SERVER))
        {
            let _ = request.respond(tiny_http::Response::from_string("[]"));
            continue;
        }

        if let Ok(Ok(response)) = tokio::time::timeout(
            std::time::Duration::from_secs(5),
            reqwest::get(&url),
        )
        .await
        {
            if let Ok(text) = response.text().await {
                let _ = request.respond(tiny_http::Response::from_string(text));
            }
        } else {
            let _ = request.respond(tiny_http::Response::from_string("[]"));
        }
    }
}
