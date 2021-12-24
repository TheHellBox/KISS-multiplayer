use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct State {
    pub download_directory: String,
    /// Future use
    pub disregard_unix_path_correction: bool
}