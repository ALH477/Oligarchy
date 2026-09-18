use std::path::PathBuf;

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("{0}")]
    Msg(String),
    #[error("required tool {0:?} is not on PATH; enter the Reliquary Nix shell so preservation tools are wrapped in")]
    MissingTool(&'static str),
    #[error("command failed ({code}): {cmd}\n{stderr}")]
    Command {
        cmd: String,
        code: i32,
        stderr: String,
    },
    #[error("source does not exist: {0}")]
    MissingSource(PathBuf),
    #[error("unknown block {0}")]
    UnknownBlock(String),
    #[error("{0}")]
    Store(String),
    #[error(transparent)]
    Io(#[from] std::io::Error),
    #[error(transparent)]
    Json(#[from] serde_json::Error),
}

pub type Result<T> = std::result::Result<T, Error>;

impl Error {
    pub fn store(msg: impl Into<String>) -> Self {
        Error::Store(msg.into())
    }
}
