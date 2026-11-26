use std::fmt;

mod ffi;

use ffi::{END_FILE_REASON_EOF, END_FILE_REASON_ERROR, MpvHandle, RawEvent};

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

/// Eventos relevantes do motor. Paradas causadas por stop/loadfile sao ignoradas.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EngineEvent {
    FileLoaded,
    EndOfFile,
    Failed(String),
    Shutdown,
}

pub trait AudioEngine {
    fn initialize(&mut self) -> Result<(), AudioError>;
    fn load(&mut self, uri: &str) -> Result<(), AudioError>;
    fn play(&mut self) -> Result<(), AudioError>;
    fn pause(&mut self) -> Result<(), AudioError>;
    fn stop(&mut self) -> Result<(), AudioError>;
    fn seek(&mut self, position_ms: u64) -> Result<(), AudioError>;
    fn shutdown(&mut self) -> Result<(), AudioError>;
    fn position_ms(&self) -> Option<u64>;
    fn duration_ms(&self) -> Option<u64>;
    fn poll_event(&mut self) -> Option<EngineEvent>;
}

pub struct MpvEngine {
    handle: Option<MpvHandle>,
}

fn base_options() -> Vec<(&'static str, &'static str)> {
    let mut options = vec![
        ("config", "no"),
        ("terminal", "no"),
        ("load-scripts", "no"),
        ("ytdl", "no"),
        ("vid", "no"),
        ("audio-display", "no"),
        ("idle", "yes"),
        ("keep-open", "no"),
        ("input-default-bindings", "no"),
        ("input-vo-keyboard", "no"),
        ("msg-level", "all=warn"),
        ("audio-client-name", "Nexus Player"),
    ];
    if cfg!(target_os = "android") {
        options.push(("ao", "opensles"));
    }
    options
}

impl MpvEngine {
    pub fn new() -> Self {
        Self { handle: None }
    }

    fn handle(&self) -> Result<&MpvHandle, AudioError> {
        self.handle.as_ref().ok_or(AudioError::NotInitialized)
    }
}

impl Default for MpvEngine {
    fn default() -> Self {
        Self::new()
    }
}

fn failure(message: String) -> AudioError {
    AudioError::EngineFailure(message)
}

impl AudioEngine for MpvEngine {
    fn initialize(&mut self) -> Result<(), AudioError> {
        if self.handle.is_some() {
            return Err(AudioError::AlreadyInitialized);
        }
        let handle = MpvHandle::create(&base_options()).map_err(failure)?;
        self.handle = Some(handle);
        Ok(())
    }

    fn load(&mut self, uri: &str) -> Result<(), AudioError> {
        let handle = self.handle()?;
        if uri.trim().is_empty() {
            return Err(AudioError::InvalidUri);
        }
        handle.command(&["loadfile", uri, "replace"]).map_err(failure)
    }

    fn play(&mut self) -> Result<(), AudioError> {
        self.handle()?.set_property("pause", "no").map_err(failure)
    }

    fn pause(&mut self) -> Result<(), AudioError> {
        self.handle()?.set_property("pause", "yes").map_err(failure)
    }

    fn stop(&mut self) -> Result<(), AudioError> {
        self.handle()?.command(&["stop"]).map_err(failure)
    }

    fn seek(&mut self, position_ms: u64) -> Result<(), AudioError> {
        let seconds = format!("{:.3}", position_ms as f64 / 1000.0);
        self.handle()?
            .command(&["seek", &seconds, "absolute"])
            .map_err(failure)
    }

    fn shutdown(&mut self) -> Result<(), AudioError> {
        self.handle = None;
        Ok(())
    }

    fn position_ms(&self) -> Option<u64> {
        let seconds = self.handle.as_ref()?.get_double("time-pos")?;
        Some((seconds * 1000.0).max(0.0) as u64)
    }

    fn duration_ms(&self) -> Option<u64> {
        let seconds = self.handle.as_ref()?.get_double("duration")?;
        Some((seconds * 1000.0).max(0.0) as u64)
    }

    fn poll_event(&mut self) -> Option<EngineEvent> {
        let handle = self.handle.as_ref()?;
        loop {
            match handle.poll_event() {
                RawEvent::None => return None,
                RawEvent::Shutdown => return Some(EngineEvent::Shutdown),
                RawEvent::FileLoaded => return Some(EngineEvent::FileLoaded),
                RawEvent::EndFile { reason, error } => match reason {
                    END_FILE_REASON_EOF => return Some(EngineEvent::EndOfFile),
                    END_FILE_REASON_ERROR => {
                        return Some(EngineEvent::Failed(handle.error_text(error)));
                    }
                    _ => continue,
                },
                RawEvent::Other => continue,
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn engine_starts_uninitialized() {
        let mut engine = MpvEngine::new();
        assert!(matches!(engine.play(), Err(AudioError::NotInitialized)));
        assert!(matches!(engine.load("x.mp3"), Err(AudioError::NotInitialized)));
        assert!(engine.position_ms().is_none());
        assert!(engine.poll_event().is_none());
    }

    #[test]
    fn initialize_never_panics_without_libmpv() {
        let mut engine = MpvEngine::new();
        // Sem libmpv no PC retorna EngineFailure; com libmpv instalada retorna Ok.
        match engine.initialize() {
            Ok(()) => assert!(matches!(engine.initialize(), Err(AudioError::AlreadyInitialized))),
            Err(error) => assert!(matches!(error, AudioError::EngineFailure(_))),
        }
    }

    #[test]
    fn shutdown_is_safe_before_initialization() {
        let mut engine = MpvEngine::new();
        assert!(engine.shutdown().is_ok());
    }
}