#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Track {
    pub id: String,
    pub uri: String,
    pub title: String,
    pub artist: Option<String>,
    pub album: Option<String>,
    pub duration_ms: Option<u64>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PlaybackStatus {
    Idle,
    Loading,
    Playing,
    Paused,
    Stopped,
    Error,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RepeatMode {
    Off,
    Track,
    Queue,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PlaybackSnapshot {
    pub status: PlaybackStatus,
    pub current_track: Option<Track>,
    pub position_ms: u64,
    pub duration_ms: Option<u64>,
    pub repeat_mode: RepeatMode,
    pub shuffle: bool,
}

impl Default for PlaybackSnapshot {
    fn default() -> Self {
        Self {
            status: PlaybackStatus::Idle,
            current_track: None,
            position_ms: 0,
            duration_ms: None,
            repeat_mode: RepeatMode::Off,
            shuffle: false,
        }
    }
}
