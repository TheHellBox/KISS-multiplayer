use serde::Deserialize;

#[derive(Deserialize)]
pub struct Config {
    pub server_name: String,
    pub description: String,
    pub map: String,
    pub max_players: u8,
    pub tickrate: u8,
    pub show_in_server_list: bool
}

impl Config {
    pub fn load(path: &std::path::Path) -> Self {
        let config_file = std::fs::File::open(path).unwrap();
        let reader = std::io::BufReader::new(config_file);
        serde_json::from_reader(reader).unwrap()
    }
}
