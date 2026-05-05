use kissmp_server::*;
use std::sync::{Arc, Mutex};

#[tokio::main]
async fn main() {
    shared::init_logging();

    let path = std::path::Path::new("./mods/");
    if !path.exists() {
        let _ = std::fs::create_dir(path);
    }

    let config = config::Config::load(std::path::Path::new("./config.json"));
    let local_ip = web_ui::get_local_ip();
    let state = Arc::new(Mutex::new(web_ui::AppState {
        config,
        running: false,
        local_ip,
        destroyer: None,
    }));

    web_ui::spawn_web_ui(state, 3694);

    loop {
        tokio::time::sleep(std::time::Duration::from_secs(60)).await;
    }
}
