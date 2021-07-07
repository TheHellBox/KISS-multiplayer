use ifcfg::IfCfgError;
use igd::{RemovePortError, SearchError};
use thiserror::Error;

#[derive(Error, Debug)]
pub enum UPnPError {
    #[error("could not get the system's network interfaces: {0}")]
    // IfCfgError does not impl std::error::Error so have to have a manual From
    CouldNotGetInterfaces(IfCfgError),
    #[error("no interfaces had IPv4 or are connected to the public internet")]
    NoValidInterfaceIPs,
    #[error("could not find a gateway: {0}")]
    CouldNotFindGateway(#[from] SearchError),
    #[error("with all the valid IPs, could not add a port to any of them")]
    CouldNotAddPort,
    #[error("a port was already added for KISSMP, but removing it failed: {0}")]
    FailedToRemovePort(#[from] RemovePortError)
}

impl From<IfCfgError> for UPnPError {
    fn from(e: IfCfgError) -> Self {
        Self::CouldNotGetInterfaces(e)
    }
}