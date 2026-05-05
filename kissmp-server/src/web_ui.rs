use log::{error, info};
use serde::{Deserialize, Serialize};
use std::io::Read;
use std::sync::{Arc, Mutex};

const MAP_KEYWORDS: &[&str] = &[
    "map", "maps", "level", "levels", "road", "course", "track", "circuit", "route",
    "rally", "terrain", "desert", "forest", "island", "harbor", "harbour", "canyon",
    "grid", "stadium", "airport", "dock", "mountain", "cliff", "drift", "highway",
    "freeway", "raceway", "speedway", "hillclimb", "touge", "offroad", "trail",
];

#[derive(Serialize, Clone)]
struct ModInfo {
    name: String,
    path: String,
    size: u64,
    is_map: bool,
}

#[derive(Deserialize)]
struct StartRequest {
    server_name: String,
    description: Option<String>,
    port: u16,
    max_players: u8,
    max_vehicles_per_client: Option<u8>,
    tickrate: Option<u8>,
    map: String,
    show_in_server_list: Option<bool>,
    upnp_enabled: Option<bool>,
    require_scripts: Option<bool>,
    mods: Option<Vec<String>>,
    mods_folder: Option<String>,
}

pub struct AppState {
    pub config: crate::config::Config,
    pub running: bool,
    pub local_ip: String,
    pub destroyer: Option<tokio::sync::oneshot::Sender<()>>,
}

pub fn get_local_ip() -> String {
    std::net::UdpSocket::bind("0.0.0.0:0")
        .and_then(|s| {
            s.connect("8.8.8.8:53")?;
            s.local_addr()
        })
        .map(|a| a.ip().to_string())
        .unwrap_or_else(|_| "127.0.0.1".to_string())
}

fn find_beamng_mods() -> Option<String> {
    let local = std::env::var("LOCALAPPDATA").ok()?;
    let base = std::path::Path::new(&local).join("BeamNG.drive");
    if !base.exists() {
        return None;
    }
    let mut vers: Vec<_> = std::fs::read_dir(&base)
        .ok()?
        .filter_map(|e| e.ok())
        .map(|e| e.path())
        .filter(|p| p.is_dir())
        .collect();
    vers.sort();
    let mods_dir = vers.last()?.join("mods");
    if mods_dir.exists() {
        Some(mods_dir.to_string_lossy().replace('\\', "/"))
    } else {
        None
    }
}

fn is_map_mod(name: &str) -> bool {
    let l = name.to_lowercase();
    MAP_KEYWORDS.iter().any(|k| l.contains(k))
}

fn scan_mods(path: &str) -> Vec<ModInfo> {
    let dir = std::path::Path::new(path);
    if !dir.exists() {
        return vec![];
    }
    let mut list: Vec<ModInfo> = std::fs::read_dir(dir)
        .into_iter()
        .flatten()
        .filter_map(|e| e.ok())
        .filter(|e| {
            e.path()
                .extension()
                .and_then(|x| x.to_str())
                .map(|x| x.eq_ignore_ascii_case("zip"))
                .unwrap_or(false)
        })
        .map(|e| {
            let p = e.path();
            let name = p
                .file_name()
                .unwrap_or_default()
                .to_str()
                .unwrap_or("")
                .to_string();
            let size = p.metadata().map(|m| m.len()).unwrap_or(0);
            let im = is_map_mod(&name);
            ModInfo {
                name,
                path: p.to_string_lossy().replace('\\', "/"),
                size,
                is_map: im,
            }
        })
        .collect();
    list.sort_by(|a, b| a.name.cmp(&b.name));
    list
}

fn url_decode(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let bytes = s.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            let h = &s[i + 1..i + 3];
            if let Ok(b) = u8::from_str_radix(h, 16) {
                out.push(b as char);
                i += 3;
                continue;
            }
        } else if bytes[i] == b'+' {
            out.push(' ');
            i += 1;
            continue;
        }
        out.push(bytes[i] as char);
        i += 1;
    }
    out
}

fn hdr(s: &str) -> tiny_http::Header {
    s.parse().unwrap()
}

fn json_resp(body: &str) -> tiny_http::Response<std::io::Cursor<Vec<u8>>> {
    tiny_http::Response::from_string(body)
        .with_header(hdr("Content-Type: application/json"))
        .with_header(hdr("Access-Control-Allow-Origin: *"))
}

fn text_resp(body: &str) -> tiny_http::Response<std::io::Cursor<Vec<u8>>> {
    tiny_http::Response::from_string(body)
        .with_header(hdr("Access-Control-Allow-Origin: *"))
}

const DISCOVERY_PORT: u16 = 3699;

fn calc_broadcast(addr: std::net::Ipv4Addr, mask: std::net::Ipv4Addr) -> std::net::Ipv4Addr {
    let a = u32::from(addr);
    let m = u32::from(mask);
    std::net::Ipv4Addr::from((a & m) | !m)
}

fn get_broadcast_addrs(port: u16) -> Vec<String> {
    let mut addrs = vec![format!("255.255.255.255:{}", port)];
    if let Ok(ifaces) = ifcfg::IfCfg::get() {
        for iface in &ifaces {
            for iaddr in &iface.addresses {
                let ip = match iaddr.address {
                    Some(std::net::SocketAddr::V4(a)) => *a.ip(),
                    _ => continue,
                };
                let mask = match iaddr.mask {
                    Some(std::net::SocketAddr::V4(m)) => *m.ip(),
                    _ => continue,
                };
                if ip.is_loopback() { continue; }
                let bcast = calc_broadcast(ip, mask);
                let s = format!("{}:{}", bcast, port);
                if !addrs.contains(&s) {
                    addrs.push(s);
                }
            }
        }
    }
    addrs
}

fn spawn_broadcast(state: Arc<Mutex<AppState>>) {
    std::thread::spawn(move || {
        let socket = match std::net::UdpSocket::bind("0.0.0.0:0") {
            Ok(s) => s,
            Err(e) => { log::warn!("UDP broadcast: no se pudo crear socket: {}", e); return; }
        };
        if socket.set_broadcast(true).is_err() {
            log::warn!("UDP broadcast: set_broadcast fallo");
        }
        loop {
            {
                let s = state.lock().unwrap();
                if s.running {
                    let packet = format!(
                        r#"{{"name":{},"port":{},"max_players":{},"map":{},"players":0}}"#,
                        serde_json::to_string(&s.config.server_name).unwrap(),
                        s.config.port,
                        s.config.max_players,
                        serde_json::to_string(&s.config.map).unwrap(),
                    );
                    let data = packet.as_bytes();
                    for dest in get_broadcast_addrs(DISCOVERY_PORT) {
                        let _ = socket.send_to(data, &dest);
                    }
                }
            }
            std::thread::sleep(std::time::Duration::from_secs(2));
        }
    });
}

pub fn spawn_web_ui(state: Arc<Mutex<AppState>>, ui_port: u16) {
    spawn_broadcast(state.clone());
    std::thread::spawn(move || {
        let server = match tiny_http::Server::http(format!("0.0.0.0:{}", ui_port)) {
            Ok(s) => s,
            Err(e) => {
                error!("Web UI failed to start on port {}: {}", ui_port, e);
                return;
            }
        };
        info!("Web UI disponible en http://127.0.0.1:{}", ui_port);

        // Auto-abrir navegador en Windows
        #[cfg(windows)]
        let _ = std::process::Command::new("cmd")
            .args(["/c", "start", &format!("http://127.0.0.1:{}", ui_port)])
            .spawn();

        let html = include_str!("../ui/index.html");

        loop {
            let mut req = match server.recv() {
                Ok(r) => r,
                Err(_) => continue,
            };

            let full_url = req.url().to_string();
            let path = full_url.split('?').next().unwrap_or("/").to_string();
            let query = full_url.splitn(2, '?').nth(1).unwrap_or("").to_string();
            let is_get = req.method() == &tiny_http::Method::Get;
            let is_post = req.method() == &tiny_http::Method::Post;

            if is_get && (path == "/" || path == "/index.html") {
                let resp = tiny_http::Response::from_string(html)
                    .with_header(hdr("Content-Type: text/html; charset=utf-8"));
                let _ = req.respond(resp);
                continue;
            }

            if is_get && path == "/api/status" {
                let s = state.lock().unwrap();
                let cfg = &s.config;
                let mods_json = match &cfg.mods {
                    Some(m) => serde_json::to_string(m).unwrap_or_else(|_| "[]".to_string()),
                    None => "[]".to_string(),
                };
                let body = serde_json::json!({
                    "running": s.running,
                    "players": 0,
                    "max_players": cfg.max_players,
                    "ip": s.local_ip,
                    "port": cfg.port,
                    "config": {
                        "server_name": cfg.server_name,
                        "description": cfg.description,
                        "port": cfg.port,
                        "max_players": cfg.max_players,
                        "max_vehicles_per_client": cfg.max_vehicles_per_client,
                        "tickrate": cfg.tickrate,
                        "map": cfg.map,
                        "show_in_server_list": cfg.show_in_server_list,
                        "upnp_enabled": cfg.upnp_enabled,
                        "require_scripts": cfg.require_scripts,
                        "mods_folder": cfg.mods_folder,
                        "mods": mods_json,
                    }
                }).to_string();
                let _ = req.respond(json_resp(&body));
                continue;
            }

            if is_get && path == "/api/detect_beamng" {
                let detected = find_beamng_mods();
                let body = match detected {
                    Some(p) => format!(r#"{{"path":"{}"}}"#, p.replace('"', "\\\"")),
                    None => r#"{"path":null}"#.to_string(),
                };
                let _ = req.respond(json_resp(&body));
                continue;
            }

            if is_get && path == "/api/mods" {
                let raw_path = query
                    .split('&')
                    .find(|s| s.starts_with("path="))
                    .map(|s| url_decode(&s[5..]))
                    .unwrap_or_default();
                let mods = scan_mods(&raw_path);
                let body = serde_json::to_string(&mods).unwrap_or_else(|_| "[]".to_string());
                let _ = req.respond(json_resp(&body));
                continue;
            }

            // Guardar ruta de mods sin iniciar el servidor
            if is_post && path == "/api/mods_folder" {
                let mut body = String::new();
                let _ = req.as_reader().read_to_string(&mut body);
                let folder = body.trim().to_string();
                let mut s = state.lock().unwrap();
                s.config.mods_folder = folder;
                s.config.save_to_file("./config.json");
                let _ = req.respond(text_resp("ok"));
                continue;
            }

            if is_post && path == "/api/start" {
                let mut body = String::new();
                let _ = req.as_reader().read_to_string(&mut body);
                let sr: StartRequest = match serde_json::from_str(&body) {
                    Ok(r) => r,
                    Err(e) => {
                        let _ = req.respond(text_resp(&format!("error: {}", e)));
                        continue;
                    }
                };

                // Parar servidor existente
                {
                    let mut s = state.lock().unwrap();
                    if let Some(tx) = s.destroyer.take() {
                        let _ = tx.send(());
                    }
                    s.running = false;
                    s.config.server_name = sr.server_name.clone();
                    if let Some(ref d) = sr.description { s.config.description = d.clone(); }
                    s.config.port = sr.port;
                    s.config.max_players = sr.max_players;
                    if let Some(v) = sr.max_vehicles_per_client { s.config.max_vehicles_per_client = v; }
                    if let Some(v) = sr.tickrate { s.config.tickrate = v; }
                    s.config.map = sr.map.clone();
                    if let Some(v) = sr.show_in_server_list { s.config.show_in_server_list = v; }
                    if let Some(v) = sr.upnp_enabled { s.config.upnp_enabled = v; }
                    if let Some(v) = sr.require_scripts { s.config.require_scripts = v; }
                    s.config.mods = sr.mods.clone();
                    if let Some(ref f) = sr.mods_folder { s.config.mods_folder = f.clone(); }
                    s.config.save_to_file("./config.json");
                }

                // Construir config del servidor
                let srv_config = {
                    let s = state.lock().unwrap();
                    s.config.clone()
                };

                let (dtx, drx) = tokio::sync::oneshot::channel::<()>();
                let (setup_tx, setup_rx) =
                    tokio::sync::oneshot::channel::<shared::vehicle::ServerSetupResult>();

                let state2 = state.clone();
                std::thread::spawn(move || {
                    let rt = tokio::runtime::Runtime::new().unwrap();
                    rt.block_on(async move {
                        let server = crate::Server::from_config(srv_config);
                        server.run(false, drx, Some(setup_tx)).await;
                        state2.lock().unwrap().running = false;
                        info!("Servidor detenido.");
                    });
                });

                // Esperar a que el servidor esté listo (o falle)
                match setup_rx.blocking_recv() {
                    Ok(_) => {
                        state.lock().unwrap().destroyer = Some(dtx);
                        state.lock().unwrap().running = true;
                        let _ = req.respond(text_resp("ok"));
                    }
                    Err(_) => {
                        // El servidor falló al iniciar
                        let _ = req.respond(text_resp(
                            "error: el servidor no pudo iniciar. Revisa el log.",
                        ));
                    }
                }
                continue;
            }

            if is_post && path == "/api/stop" {
                let mut s = state.lock().unwrap();
                if let Some(tx) = s.destroyer.take() {
                    let _ = tx.send(());
                }
                s.running = false;
                let _ = req.respond(text_resp("ok"));
                continue;
            }

            let _ = req.respond(
                tiny_http::Response::from_string("not found").with_status_code(404),
            );
        }
    });
}
