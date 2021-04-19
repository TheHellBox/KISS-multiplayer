pub async fn spawn_discord_rpc(discord_rx: std::sync::mpsc::Receiver<crate::DiscordState>) {
    //let discord_rx = tokio_stream::wrappers::ReceiverStream::new(discord_rx);
    std::thread::spawn(move || {
        let mut drpc_client = discord_rpc_client::Client::new(771278096627662928);
        drpc_client.start();
        drpc_client
            .subscribe(discord_rpc_client::models::Event::ActivityJoin, |j| {
                j.secret("123456")
            })
            .expect("Failed to subscribe to event");
        //println!("test");
        let mut state = crate::DiscordState { server_name: None };
        loop {
            std::thread::sleep(std::time::Duration::from_millis(5000));
            for new_state in discord_rx.try_recv() {
                state = new_state;
            }
            if state.server_name.is_none() {
                let _ = drpc_client.clear_activity();
                continue;
            }
            let _ = drpc_client.set_activity(|activity| {
                activity
                    .details(state.clone().server_name.unwrap())
                    //.state("[1/8]")
                    .assets(|assets| assets.large_image("kissmp_logo"))
                //.secrets(|secrets| secrets.game("Test").join("127.0.0.1:3698"))
            });
        }
    });
}
