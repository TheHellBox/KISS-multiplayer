// It used to be 50 loc, written with tinyhttp.
// At some point...
// Now it's what you're seeing, I hate it

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::{Arc, Mutex};
use warp::Filter;
use shared::{VERSION_STR, VERSION};

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct ServerInfo {
    name: String,
    player_count: u8,
    max_players: u8,
    description: String,
    map: String,
    port: u16,
    version: (u32, u32),
    #[serde(skip)]
    update_time: Option<std::time::Instant>,
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct ServerList(HashMap<SocketAddr, ServerInfo>);

#[tokio::main]
async fn main() {
    let server_list_r = Arc::new(Mutex::new(ServerList(HashMap::new())));
    let addresses_r: Arc<Mutex<HashMap<std::net::IpAddr, HashMap<u16, bool>>>>= Arc::new(Mutex::new(HashMap::new()));

    let server_list = server_list_r.clone();
    let addresses = addresses_r.clone();
    let post = warp::post()
        .and(warp::addr::remote())
        .and(warp::body::json())
        .and(warp::path::end())
        .map(move |addr: Option<SocketAddr>, server_info: ServerInfo| {
            let addr = {
                if let Some(addr) = addr {
                    addr
                }
                else{
                    return "err"
                }
            };
            let censor_standart = censor::Censor::Standard;
            let censor_sex = censor::Censor::Sex;
            let mut server_info: ServerInfo = server_info;
            if server_info.version != VERSION {
                return "Invalid server version";
            }
            if server_info.description.len() > 256 || server_info.name.len() > 64 {
                return "Server descrition/name length is too big!";
            }
            if censor_standart.check(&server_info.name) || censor_sex.check(&server_info.name) {
                return "Censor!";
            }
            {
                let server_list = &mut *server_list.lock().unwrap();
                let addresses = &mut *addresses.lock().unwrap();
                if let Some(ports) = addresses.get_mut(&addr.ip()) {
                    ports.insert(server_info.port, true);
                    // Limit amount of servers per addr to avoid spam
                    if ports.len() > 10 {
                        return "Too many servers!";
                    }
                }
                else{
                    addresses.insert(addr.ip(), HashMap::new());
                    addresses.get_mut(&addr.ip()).unwrap().insert(server_info.port, true);
                }
                let addr = SocketAddr::new(addr.ip(), server_info.port);
                server_info.update_time = Some(std::time::Instant::now());
                server_list.0.insert(addr, server_info);
            }
            return "ok";
        });
    let server_list = server_list_r.clone();
    let addresses = addresses_r.clone();
    let ver = warp::path::param().map(move |ver: String| {
        if ver != VERSION_STR && ver != "latest" {
            return outdated_ver()
        }
        let server_list = server_list.clone();
        let addresses = addresses.clone();
        {
            let server_list = &mut *server_list.lock().unwrap();
            let addresses = &mut *addresses.lock().unwrap();
            for (k, server) in server_list.0.clone() {
                if server.update_time.unwrap().elapsed().as_secs() > 10 {
                    server_list.0.remove(&k);
                    if let Some(ports) = addresses.get_mut(&k.ip()) {
                        ports.remove(&k.port());
                    }
                }
            }
        }
        let response = {
            let server_list = &mut *server_list.lock().unwrap();
            serde_json::to_string(&server_list).unwrap()
        };
        response
    });
    let outdated = warp::get().map(move || {
        return outdated_ver()
    });
    let routes = post.or(ver).or(outdated);
    warp::serve(routes).run(([0, 0, 0, 0], 3692)).await;
}

fn outdated_ver() -> String {
    let mut server_list = ServerList(HashMap::with_capacity(5));
    for k in 0..5 {
        server_list.0.insert(SocketAddr::new(std::net::IpAddr::V4(std::net::Ipv4Addr::new(127, 0, 0, 1)), k), ServerInfo {
            name: "You're running an outdated version of KissMP. Please, consider updating to a newer version".to_string(),
            player_count: 0,
            max_players: 0,
            description: "You can find updated version of KissMP on a github releases page".to_string(),
            map: "Update to a newer version of KissMP".to_string(),
            port: 0,
            version: VERSION,
            update_time: None
        });
    }
    serde_json::to_string(&server_list).unwrap()
}
