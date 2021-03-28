pub fn spawn_discord_rpc(mut discord_rx: tokio::sync::mpsc::Receiver<crate::DiscordState>) {
    std::thread::spawn(move || {
        let mut drpc_client = discord_rpc_client::Client::new(771278096627662928);
        drpc_client.start();
        drpc_client
            .subscribe(discord_rpc_client::models::Event::ActivityJoin, |j| {
                j.secret("123456")
            })
            .expect("Failed to subscribe to event");

        //let mut state = crate::DiscordState { server_name: None };
        loop {
            let state = discord_rx.blocking_recv().unwrap();
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
