use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::net::SocketAddr;
use tiny_http::{Response, Server};

const VERSION: (u32, u32) = (0, 2);

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

fn main() {
    let server = Server::http("0.0.0.0:3692").unwrap();
    let mut server_list = ServerList(HashMap::new());
    let mut addresses: HashMap<std::net::IpAddr, HashMap<u16, bool>> = HashMap::new();

    let censor_standard = censor::Censor::Standard;
    let censor_sex = censor::Censor::Sex;

    for mut request in server.incoming_requests() {
        for (k, server) in server_list.0.clone() {
            if server.update_time.unwrap().elapsed().as_secs() > 10 {
                server_list.0.remove(&k);
                if let Some(ports) = addresses.get_mut(&k.ip()) {
                    ports.remove(&k.port());
                }
            }
        }
        if request.method() == &tiny_http::Method::Post {
            let addr = request.remote_addr().clone();
            let mut content = String::new();
            let _ = request.as_reader().read_to_string(&mut content);
            if let Ok(server_info) = serde_json::from_str(&content) {
                let mut server_info: ServerInfo = server_info;
                if server_info.version != VERSION {
                    let response = Response::from_string("Mismatching version");
                    let _ = request.respond(response);
                    continue;
                }
                server_info.description.truncate(256);
                server_info.name.truncate(64);
                if censor_standard.check(&server_info.name) || censor_sex.check(&server_info.name) {
                    continue;
                }
                if let Some(ports) = addresses.get_mut(&addr.ip()) {
                    ports.insert(server_info.port, true);
                    // Limit amount of servers per addr to avoid spam
                    if ports.len() > 10 {
                        continue;
                    }
                }
                else{
                    addresses.insert(addr.ip(), HashMap::new());
                    addresses.get_mut(&addr.ip()).unwrap().insert(server_info.port, true);
                }
                let addr = SocketAddr::new(addr.ip(), server_info.port); 
                server_info.update_time = Some(std::time::Instant::now());
                server_list.0.insert(addr, server_info);
                let response = Response::from_string("ok");
                let _ = request.respond(response);
            } else {
                let response = Response::from_string("err");
                let _ = request.respond(response);
            }
        } else {
            let response = Response::from_string(serde_json::to_string(&server_list).unwrap());
            let _ = request.respond(response);
        }
    }
}
