use ifcfg::IfCfgError;
use igd::{RemovePortError, SearchError};
use quinn::{ConnectionError, ReadExactError, SendDatagramError, WriteError};
use thiserror::Error;
use tokio::sync::mpsc::error::SendError as TokioSendError;

use crate::incoming::IncomingEvent;

#[derive(Error, Debug)]
pub enum SendServerInfoError {

}

#[derive(Error, Debug)]
pub enum PlayerConnectError {
    #[error("server full")]
    ServerFull
}

#[derive(Error, Debug)]
pub enum RecievePlayerInfoError {
    #[error("could not open the connection")]
    OpenConnection(#[from] ConnectionError),
    #[error("reading from the connection failed")]
    ReadConnection(#[from] ReadExactError),
    #[error("deseralizing information failed")]
    Deserialize(#[from] Box<bincode::ErrorKind>),
    #[error("recieved something else: {0:?}")]
    RecievedSomethingElse(shared::ClientCommand),
    #[error("no stream given")]
    NoStream
}

#[derive(Error, Debug)]
pub enum DriveSendError {
    #[error("sending datagram failed")]
    SendDatagram(#[from] SendDatagramError),
    #[error("client disconnected")]
    Disconnected
}

#[derive(Error, Debug)]
pub enum DriveRecieveError {
    #[error("reading from the connection failed")]
    ReadConnection(#[from] ReadExactError),
    #[error("client disconnected")]
    Disconnected,
    #[error("recieving command failed")]
    Commands(#[from] CMDRecieveError),
    #[error("recieving datagram failed")]
    Datagram(#[from] DatagramRecieveError)
}

#[derive(Error, Debug)]
pub enum SendError {
    #[error("writing to the connections failed")]
    WriteAll(#[from] WriteError)
}

#[derive(Error, Debug)]
pub enum ListModsError {
    #[error("reading the mod directory failed")]
    ReadDirectory(std::io::Error),
    #[error("getting mod file information failed")]
    Metadata(std::io::Error)
}

#[derive(Error, Debug)]
pub enum UPnPError {
    #[error("could not get the system's network interfaces")]
    // IfCfgError does not impl std::error::Error so have to have a manual From
    GetInterfaces(IfCfgError),
    #[error("no interfaces had IPv4 or are connected to the public internet")]
    NoValidInterfaceIPs,
    #[error("could not find a gateway: {0}")]
    GatewayNotFound(#[from] SearchError),
    #[error("with all the valid IPs, could not add a port to any of them")]
    AddPort,
    #[error("a port was already added for KISSMP, but removing it failed")]
    RemovePort(#[from] RemovePortError)
}

impl From<IfCfgError> for UPnPError {
    fn from(e: IfCfgError) -> Self {
        Self::GetInterfaces(e)
    }
}

#[derive(Error, Debug)]
pub enum TransferFileError {
    #[error("could not open file")]
    OpenFile(std::io::Error),
    #[error("getting file metadata failed")]
    Metadata(std::io::Error),
    #[error("connection failed")]
    Connection(#[from] ConnectionError),
    #[error("send failed")]
    Send(#[from] SendError)
}

#[derive(Error, Debug)]
pub enum HandleIncomingDataError {
    #[error("send failed")]
    Send(#[from] TokioSendError<(u32, IncomingEvent)>),
    #[error("deseralizing information failed")]
    Deserialize(#[from] Box<bincode::ErrorKind>)
}


#[derive(Error, Debug)]
pub enum CMDRecieveError {
    #[error("could not open the connection")]
    OpenConnection(#[from] ConnectionError),
    #[error("reading from the connection failed")]
    ReadConnection(#[from] ReadExactError),
}

#[derive(Error, Debug)]
pub enum DatagramRecieveError {
    #[error("could not open the connection")]
    OpenConnection(#[from] ConnectionError),
    #[error("reading from the connection failed")]
    ReadConnection(#[from] ReadExactError),
}