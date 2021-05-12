use serde::{Deserialize, Serialize};

#[derive(Deserialize, Serialize)]
#[serde(default)]
pub struct Config {
    pub server_name: String,
    pub description: String,
    pub map: String,
    pub max_players: u8,
    pub tickrate: u8,
    pub port: u16,
    pub max_vehicles_per_client: u8,
    pub show_in_server_list: bool,
    pub upnp_enabled: bool,
    pub server_identifier: String,
    pub mods: Option<Vec<String>>,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            server_name: "Vanilla KissMP Server".to_string(),
            description: "Vanilla KissMP Server".to_string(),
            map: "/levels/smallgrid/info.json".to_string(),
            tickrate: 60,
            max_players: 8,
            max_vehicles_per_client: 3,
            port: 3698,
            show_in_server_list: false,
            upnp_enabled: false,
            server_identifier: rand_string(),
            mods: None,
        }
    }
}

impl Config {
    pub fn load(path: &std::path::Path) -> Self {
        if !path.exists() {
            create_default_config();
        }
        let config_file = std::fs::File::open(path).unwrap();
        let reader = std::io::BufReader::new(config_file);
        serde_json::from_reader(reader).unwrap()
    }
}

pub fn create_default_config() {
    use std::io::prelude::*;
    let mut config_file = std::fs::File::create("./config.json").unwrap();
    let config = Config::default();
    let config_str = serde_json::to_vec_pretty(&config).unwrap();
    config_file.write_all(&config_str).unwrap();
}

fn rand_string() -> String {
    (0..10)
        .map(|_| (0x20u8 + (rand::random::<f32>() * 96.0) as u8) as char)
        .collect()
}
