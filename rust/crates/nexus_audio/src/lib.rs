use std::fmt;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AudioError {
    NotInitialized,
    AlreadyInitialized,
    InvalidUri,
    EngineFailure(String),
}

impl fmt::Display for AudioError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NotInitialized => write!(f, "Audio engine is not initialized"),
            Self::AlreadyInitialized => write!(f, "Audio engine is already initialized"),
            Self::InvalidUri => write!(f, "Invalid media URI"),
            Self::EngineFailure(message) => write!(f, "Audio engine failure: {message}"),
        }
    }
}

impl std::error::Error for AudioError {}

pub trait AudioEngine {
    fn initialize(&mut self) -> Result<(), AudioError>;
    fn load(&mut self, uri: &str) -> Result<(), AudioError>;
    fn play(&mut self) -> Result<(), AudioError>;
    fn pause(&mut self) -> Result<(), AudioError>;
    fn stop(&mut self) -> Result<(), AudioError>;
    fn seek(&mut self, position_ms: u64) -> Result<(), AudioError>;
    fn shutdown(&mut self) -> Result<(), AudioError>;
}

pub struct MpvEngine {
    initialized: bool,
}

impl MpvEngine {
    pub fn new() -> Self {
        Self { initialized: false }
    }
}

impl Default for MpvEngine {
    fn default() -> Self { Self::new() }
}

impl AudioEngine for MpvEngine {
    fn initialize(&mut self) -> Result<(), AudioError> {
        if self.initialized { return Err(AudioError::AlreadyInitialized); }
        Err(AudioError::EngineFailure("MPV backend is not connected yet".into()))
    }

    fn load(&mut self, _uri: &str) -> Result<(), AudioError> {
        Err(AudioError::NotInitialized)
    }

    fn play(&mut self) -> Result<(), AudioError> {
        Err(AudioError::NotInitialized)
    }

    fn pause(&mut self) -> Result<(), AudioError> {
        Err(AudioError::NotInitialized)
    }

    fn stop(&mut self) -> Result<(), AudioError> {
        Err(AudioError::NotInitialized)
    }

    fn seek(&mut self, _position_ms: u64) -> Result<(), AudioError> {
        Err(AudioError::NotInitialized)
    }

    fn shutdown(&mut self) -> Result<(), AudioError> {
        self.initialized = false;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn engine_starts_uninitialized() {
        let mut engine = MpvEngine::new();
        assert!(matches!(engine.play(), Err(AudioError::NotInitialized)));
    }

    #[test]
    fn backend_reports_missing_mpv() {
        let mut engine = MpvEngine::new();
        assert!(matches!(engine.initialize(), Err(AudioError::EngineFailure(_))));
    }

    #[test]
    fn shutdown_is_safe_before_initialization() {
        let mut engine = MpvEngine::new();
        assert!(engine.shutdown().is_ok());
    }
}
