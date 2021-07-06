use kissmp_server::*;

#[tokio::main]
async fn main() {
    println!("Gas, Gas, Gas!");
    let path = std::path::Path::new("./mods/");
    if !path.exists() {
        std::fs::create_dir(path).unwrap();
    }
    let config = config::Config::load(std::path::Path::new("./config.json"));
    let server = Server::from_config(config);
    server.run(true, tokio::sync::oneshot::channel().1, None).await;
    std::process::exit(0);
}
