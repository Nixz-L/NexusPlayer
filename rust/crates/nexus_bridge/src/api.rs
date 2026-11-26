use nexus_audio::{AudioEngine, EngineEvent, MpvEngine};
use nexus_core::PlayerCore;
use nexus_types::{PlaybackStatus, RepeatMode, Track};

#[derive(Clone, Debug)]
pub struct TrackInput {
    pub id: String,
    pub uri: String,
    pub title: String,
    pub artist: Option<String>,
    pub album: Option<String>,
    pub duration_ms: Option<u64>,
}

#[derive(Clone, Debug)]
pub struct TrackInfo {
    pub id: String,
    pub uri: String,
    pub title: String,
    pub artist: Option<String>,
    pub album: Option<String>,
    pub duration_ms: Option<u64>,
}

#[derive(Clone, Debug)]
pub struct PlaybackState {
    pub status: String,
    pub current_track: Option<TrackInfo>,
    pub position_ms: u64,
    pub duration_ms: Option<u64>,
    pub repeat_mode: String,
    pub shuffle: bool,
}

impl From<Track> for TrackInfo {
    fn from(track: Track) -> Self {
        Self {
            id: track.id,
            uri: track.uri,
            title: track.title,
            artist: track.artist,
            album: track.album,
            duration_ms: track.duration_ms,
        }
    }
}

fn status_to_string(status: PlaybackStatus) -> String {
    match status {
        PlaybackStatus::Idle => "idle",
        PlaybackStatus::Loading => "loading",
        PlaybackStatus::Playing => "playing",
        PlaybackStatus::Paused => "paused",
        PlaybackStatus::Stopped => "stopped",
        PlaybackStatus::Error => "error",
    }
    .to_string()
}

fn repeat_to_string(mode: RepeatMode) -> String {
    match mode {
        RepeatMode::Off => "off",
        RepeatMode::Track => "track",
        RepeatMode::Queue => "queue",
    }
    .to_string()
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum State {
    Idle,
    Playing,
    Paused,
    Stopped,
    Error,
}

pub struct PlayerController {
    core: PlayerCore,
    engine: MpvEngine,
    engine_ready: bool,
    state: State,
    last_error: Option<String>,
}

impl PlayerController {
    pub fn new() -> Self {
        Self {
            core: PlayerCore::new(),
            engine: MpvEngine::new(),
            engine_ready: false,
            state: State::Idle,
            last_error: None,
        }
    }

    fn fail(&mut self, message: String) {
        self.state = State::Error;
        self.last_error = Some(message);
    }

    fn ensure_engine(&mut self) -> bool {
        if self.engine_ready {
            return true;
        }
        match self.engine.initialize() {
            Ok(()) => {
                self.engine_ready = true;
                true
            }
            Err(error) => {
                self.fail(error.to_string());
                false
            }
        }
    }

    /// Carrega no MPV a musica atual do core e inicia a reproducao.
    fn load_current(&mut self) -> bool {
        let uri = self
            .core
            .snapshot()
            .current_track
            .as_ref()
            .map(|track| track.uri.clone());

        let Some(uri) = uri else {
            self.state = State::Stopped;
            return false;
        };

        if !self.ensure_engine() {
            return false;
        }

        if let Err(error) = self.engine.load(&uri) {
            self.fail(error.to_string());
            return false;
        }
        if let Err(error) = self.engine.play() {
            self.fail(error.to_string());
            return false;
        }

        self.state = State::Playing;
        self.last_error = None;
        true
    }

    fn stop_engine(&mut self) {
        if self.engine_ready {
            let _ = self.engine.stop();
        }
        self.state = State::Stopped;
    }

    fn handle_track_end(&mut self) {
        let repeat_track = matches!(self.core.snapshot().repeat_mode, RepeatMode::Track);
        if repeat_track {
            self.load_current();
        } else if self.core.next() {
            self.load_current();
        } else {
            self.state = State::Stopped;
        }
    }

    pub fn set_queue(&mut self, tracks: Vec<TrackInput>) {
        let tracks = tracks
            .into_iter()
            .map(|track| Track {
                id: track.id,
                uri: track.uri,
                title: track.title,
                artist: track.artist,
                album: track.album,
                duration_ms: track.duration_ms,
            })
            .collect();

        self.core.set_queue(tracks);
    }

    pub fn play_index(&mut self, index: u32) -> bool {
        if !self.core.play_index(index as usize) {
            return false;
        }
        self.load_current()
    }

    pub fn next(&mut self) -> bool {
        if self.core.next() {
            self.load_current()
        } else {
            self.stop_engine();
            false
        }
    }

    pub fn previous(&mut self) -> bool {
        if matches!(self.state, State::Playing | State::Paused) {
            if let Some(position) = self.engine.position_ms() {
                if position > 3000 {
                    let _ = self.engine.seek(0);
                    self.core.seek(0);
                    return true;
                }
            }
        }

        if self.core.previous() {
            self.load_current()
        } else {
            false
        }
    }

    pub fn pause(&mut self) {
        if self.state == State::Playing && self.engine_ready {
            if let Err(error) = self.engine.pause() {
                self.fail(error.to_string());
            } else {
                self.state = State::Paused;
            }
        }
    }

    pub fn resume(&mut self) {
        match self.state {
            State::Paused => {
                if let Err(error) = self.engine.play() {
                    self.fail(error.to_string());
                } else {
                    self.state = State::Playing;
                }
            }
            State::Idle | State::Stopped | State::Error => {
                if self.core.current_index().is_some() {
                    self.load_current();
                } else if !self.core.queue().is_empty() {
                    self.play_index(0);
                }
            }
            State::Playing => {}
        }
    }

    pub fn toggle_play_pause(&mut self) {
        if self.state == State::Playing {
            self.pause();
        } else {
            self.resume();
        }
    }

    pub fn stop(&mut self) {
        self.stop_engine();
    }

    pub fn seek(&mut self, position_ms: u64) {
        self.core.seek(position_ms);
        if self.engine_ready && matches!(self.state, State::Playing | State::Paused) {
            let _ = self.engine.seek(position_ms);
        }
    }

    pub fn set_shuffle(&mut self, enabled: bool) {
        self.core.set_shuffle(enabled);
    }

    pub fn set_repeat_mode(&mut self, mode: String) -> bool {
        let repeat_mode = match mode.as_str() {
            "off" => RepeatMode::Off,
            "track" => RepeatMode::Track,
            "queue" => RepeatMode::Queue,
            _ => return false,
        };

        self.core.set_repeat_mode(repeat_mode);
        true
    }

    /// Chamar a cada ~250 ms pelo Flutter: processa eventos do MPV
    /// (fim de faixa, erro) e devolve o estado atualizado.
    pub fn tick(&mut self) -> PlaybackState {
        if self.engine_ready {
            while let Some(event) = self.engine.poll_event() {
                match event {
                    EngineEvent::EndOfFile => self.handle_track_end(),
                    EngineEvent::Failed(message) => self.fail(message),
                    EngineEvent::FileLoaded | EngineEvent::Shutdown => {}
                }
            }
        }
        self.snapshot()
    }

    pub fn last_error(&self) -> Option<String> {
        self.last_error.clone()
    }

    pub fn snapshot(&self) -> PlaybackState {
        let snapshot = self.core.snapshot();

        let active = self.engine_ready && matches!(self.state, State::Playing | State::Paused);
        let (position_ms, engine_duration) = if active {
            (
                self.engine.position_ms().unwrap_or(0),
                self.engine.duration_ms(),
            )
        } else {
            (0, None)
        };

        let status = match self.state {
            State::Idle => PlaybackStatus::Idle,
            State::Playing => PlaybackStatus::Playing,
            State::Paused => PlaybackStatus::Paused,
            State::Stopped => PlaybackStatus::Stopped,
            State::Error => PlaybackStatus::Error,
        };

        PlaybackState {
            status: status_to_string(status),
            current_track: snapshot.current_track.clone().map(TrackInfo::from),
            position_ms,
            duration_ms: engine_duration.or(snapshot.duration_ms),
            repeat_mode: repeat_to_string(snapshot.repeat_mode),
            shuffle: snapshot.shuffle,
        }
    }

    pub fn queue(&self) -> Vec<TrackInfo> {
        self.core
            .queue()
            .iter()
            .cloned()
            .map(TrackInfo::from)
            .collect()
    }

    pub fn current_index(&self) -> Option<u32> {
        self.core.current_index().map(|index| index as u32)
    }
}

pub fn get_nexus_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}