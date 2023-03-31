pub async fn spawn_discord_rpc(discord_rx: std::sync::mpsc::Receiver<crate::DiscordState>) {
    //let discord_rx = tokio_stream::wrappers::ReceiverStream::new(discord_rx);
    std::thread::spawn(move || {
        let mut drpc_client = discord_rpc_client::Client::new(771278096627662928);
        if let Err(err) = drpc_client.start() {
            log::error!("Failed to start Discord client: {}", err);
            return;
        }
        if let Err(err) = drpc_client.subscribe(discord_rpc_client::models::Event::ActivityJoin, |j| {
            j.secret("123456")
        }) {
            log::error!("Failed to subscribe to event: {}", err);
            return;
        }
        //println!("test");
        let mut state = crate::DiscordState { server_name: None };
        loop {
            std::thread::sleep(std::time::Duration::from_millis(5000));
            for new_state in discord_rx.try_recv() {
                state = new_state;
            }
            if state.server_name.is_none() {
                if let Err(err) = drpc_client.clear_activity() {
                    // handle error case, e.g. log error message
                    log::error!("Failed to clear activity: {}", err);
                }
                continue;
            }
            if let Err(err) = drpc_client.set_activity(|activity| {
                activity
                    .details(state.clone().server_name.unwrap())
                    //.state("[1/8]")
                    .assets(|assets| assets.large_image("kissmp_logo"))
                //.secrets(|secrets| secrets.game("Test").join("127.0.0.1:3698"))
            }) {
                // handle error case, e.g. log error message
                log::error!("Failed to set activity: {}", err);
            }
        }
    });
}
