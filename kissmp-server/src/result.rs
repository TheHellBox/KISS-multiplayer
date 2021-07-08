use shared::ClientInfoPrivate;

use crate::error::*;

pub type SendServerInfoResult = Result<(), SendServerInfoError>;
pub type PlayerConnectResult = Result<(),PlayerConnectError>;
pub type RecievePlayerInfoResult = Result<ClientInfoPrivate, RecievePlayerInfoError>;
pub type DriveSendResult = Result<(), DriveSendError>;
pub type DriveRecieveResult = Result<(), DriveRecieveError>;
pub type SendResult = Result<(), SendError>;
pub type ListModsResult = Result<(Vec<(String, u32)>, Vec<std::path::PathBuf>), ListModsError>;
type Port = u16;
pub type UPnPResult = Result<Port, UPnPError>;
pub type TransferFileResult = Result<(), TransferFileError>;
pub type HandleIncomingDataResult = Result<(), HandleIncomingDataError>;