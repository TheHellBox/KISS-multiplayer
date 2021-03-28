use crate::*;

#[derive(Debug)]
pub enum IncomingEvent {
    ClientConnected(Connection),
    ConnectionLost,
    ClientCommand(shared::ClientCommand)
}

impl Server {
    pub async fn handle_incoming_data(
        id: u32,
        data: Vec<u8>,
        client_events_tx: &mut mpsc::Sender<(u32, IncomingEvent)>,
    ) -> anyhow::Result<()> {
        let client_command = bincode::deserialize::<shared::ClientCommand>(&data)?;
        client_events_tx.send((id, IncomingEvent::ClientCommand(client_command))).await?;
        Ok(())
    }
}
