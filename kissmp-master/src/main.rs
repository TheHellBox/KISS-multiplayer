use std::net::SocketAddr;
use serde::{Serialize, Deserialize};
use std::collections::HashMap;
use tiny_http::{Server, Response};

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct ServerInfo {
    name: String,
    player_count: u16,
    port: u16,
    #[serde(skip)]
    update_time: Option<std::time::Instant>
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct ServerList(HashMap<SocketAddr, ServerInfo>);

fn main() {
    let server = Server::http("0.0.0.0:3692").unwrap();
    let mut server_list = ServerList(HashMap::new());

    for mut request in server.incoming_requests() {
        for (k, server) in server_list.0.clone() {
            if server.update_time.unwrap().elapsed().as_secs() > 10 {
               server_list.0.remove(&k);
            }
        }
        if request.method() == &tiny_http::Method::Post {
            let addr = request.remote_addr().clone();
            let mut content = String::new();
            request.as_reader().read_to_string(&mut content).unwrap();
            if let Ok(server_info) = serde_json::from_str(&content) {
                let mut server_info: ServerInfo = server_info;
                let addr = SocketAddr::new(addr.ip(), server_info.port);
                println!("Server update received: {:?} from {}", server_info, addr);
                server_info.update_time = Some(std::time::Instant::now());
                server_list.0.insert(addr, server_info);
                let response = Response::from_string("ok");
                request.respond(response).unwrap();
            }
            else{
                println!("Failed to parse server info");
                let response = Response::from_string("err");
                request.respond(response).unwrap();
            }
        }
        else{
            let response = Response::from_string(serde_json::to_string(&server_list).unwrap());
            request.respond(response).unwrap();
        }
    }
}
