use kissmp_server::*;

#[tokio::main]
async fn main() {
    println!("Gas, Gas, Gas!");
    let _ = list_mods(); // Dirty hack to create /mods/ folder
    let config = config::Config::load(std::path::Path::new("./config.json"));
    let server = Server::from_config(config);
    server.run(true).await;
}

fn list_mods() -> anyhow::Result<Vec<(String, u32)>> {
    let path = std::path::Path::new("./mods/");
    if !path.exists() {
        std::fs::create_dir(path).unwrap();
    }
    let mut result = vec![];
    let paths = std::fs::read_dir(path)?;
    for path in paths {
        let path = path?.path();
        if path.is_dir() {
            continue;
        }
        let file_name = path.file_name().unwrap().to_str().unwrap().to_string();
        let file = std::fs::File::open(path)?;
        let metadata = file.metadata()?;
        result.push((file_name, metadata.len() as u32))
    }
    Ok(result)
}
