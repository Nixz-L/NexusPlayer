use nexus_types::{PlaybackSnapshot, PlaybackStatus, RepeatMode, Track};

pub struct PlayerCore {
    queue: Vec<Track>,
    current_index: Option<usize>,
    snapshot: PlaybackSnapshot,
    random_state: u64,
    history: Vec<usize>,
    history_cursor: usize,
    shuffle_remaining: Vec<usize>,
}

impl Default for PlayerCore {
    fn default() -> Self {
        Self {
            queue: Vec::new(), current_index: None,
            snapshot: PlaybackSnapshot::default(),
            random_state: 0x9E3779B97F4A7C15,
            history: Vec::new(), history_cursor: 0,
            shuffle_remaining: Vec::new(),
        }
    }
}

impl PlayerCore {
    pub fn new() -> Self { Self::default() }
    pub fn snapshot(&self) -> &PlaybackSnapshot { &self.snapshot }
    pub fn queue(&self) -> &[Track] { &self.queue }
    pub fn current_index(&self) -> Option<usize> { self.current_index }

    pub fn set_queue(&mut self, tracks: Vec<Track>) {
        self.queue = tracks;
        self.current_index = None;
        self.snapshot = PlaybackSnapshot::default();
        self.history.clear();
        self.history_cursor = 0;
        self.shuffle_remaining.clear();
    }

    pub fn play_index(&mut self, index: usize) -> bool {
        if index >= self.queue.len() { return false; }
        self.history.truncate(self.history_cursor + 1);
        self.history.push(index);
        self.history_cursor = self.history.len() - 1;
        self.shuffle_remaining.retain(|&item| item != index);
        self.select_index(index)
    }

    fn select_index(&mut self, index: usize) -> bool {
        let Some(track) = self.queue.get(index).cloned() else { return false; };
        self.current_index = Some(index);
        self.snapshot.current_track = Some(track.clone());
        self.snapshot.duration_ms = track.duration_ms;
        self.snapshot.position_ms = 0;
        self.snapshot.status = PlaybackStatus::Loading;
        true
    }

    pub fn next(&mut self) -> bool {
        let Some(current) = self.current_index else { return false; };
        if self.snapshot.repeat_mode == RepeatMode::Track { return self.select_index(current); }
        if self.history_cursor + 1 < self.history.len() {
            self.history_cursor += 1;
            return self.select_index(self.history[self.history_cursor]);
        }
        let next = if self.snapshot.shuffle {
            if self.shuffle_remaining.is_empty() {
                if self.snapshot.repeat_mode != RepeatMode::Queue { return false; }
                self.shuffle_remaining = (0..self.queue.len()).filter(|&i| i != current).collect();
            }
            match self.random_remaining_index() { Some(index) => index, None => return false }
        } else if current + 1 < self.queue.len() {
            current + 1
        } else if self.snapshot.repeat_mode == RepeatMode::Queue && !self.queue.is_empty() {
            0
        } else { return false; };
        self.history.truncate(self.history_cursor + 1);
        self.history.push(next);
        self.history_cursor = self.history.len() - 1;
        self.shuffle_remaining.retain(|&item| item != next);
        self.select_index(next)
    }

    pub fn previous(&mut self) -> bool {
        if self.current_index.is_none() { return false; }
        if self.snapshot.position_ms > 3000 { self.snapshot.position_ms = 0; return true; }
        if self.history_cursor == 0 { return false; }
        self.history_cursor -= 1;
        self.select_index(self.history[self.history_cursor])
    }

    pub fn seek(&mut self, position_ms: u64) {
        self.snapshot.position_ms = self.snapshot.duration_ms.map_or(position_ms, |d| position_ms.min(d));
    }
    pub fn set_status(&mut self, status: PlaybackStatus) { self.snapshot.status = status; }
    pub fn set_position(&mut self, position_ms: u64) { self.seek(position_ms); }
    pub fn set_repeat_mode(&mut self, mode: RepeatMode) { self.snapshot.repeat_mode = mode; }

    pub fn set_shuffle(&mut self, enabled: bool) {
        if self.snapshot.shuffle == enabled { return; }
        self.snapshot.shuffle = enabled;
        self.shuffle_remaining.clear();
        if enabled {
            self.shuffle_remaining = (0..self.queue.len()).filter(|i| !self.history.contains(i)).collect();
        }
    }

    fn random_remaining_index(&mut self) -> Option<usize> {
        if self.shuffle_remaining.is_empty() { return None; }
        self.random_state ^= self.random_state << 13;
        self.random_state ^= self.random_state >> 7;
        self.random_state ^= self.random_state << 17;
        let position = (self.random_state as usize) % self.shuffle_remaining.len();
        Some(self.shuffle_remaining.swap_remove(position))
    }
}


#[cfg(test)]
mod tests {
    use super::*;

    fn track(id: &str) -> Track {
        Track { id: id.to_string(), uri: format!("file:///{id}.mp3"), title: id.to_string(), artist: None, album: None, duration_ms: Some(180_000) }
    }

    fn player() -> PlayerCore {
        let mut p = PlayerCore::new();
        p.set_queue(vec![track("a"), track("b"), track("c")]);
        p
    }

    #[test]
    fn selects_track_and_rejects_invalid_index() {
        let mut p = player();
        assert!(p.play_index(1));
        assert_eq!(p.current_index(), Some(1));
        assert_eq!(p.snapshot().current_track.as_ref().unwrap().id, "b");
        assert!(!p.play_index(9));
    }

    #[test]
    fn next_stops_at_queue_end_without_repeat() {
        let mut p = player();
        assert!(p.play_index(2));
        assert!(!p.next());
        assert_eq!(p.current_index(), Some(2));
    }

    #[test]
    fn repeat_queue_wraps_to_first_track() {
        let mut p = player();
        p.set_repeat_mode(RepeatMode::Queue);
        assert!(p.play_index(2));
        assert!(p.next());
        assert_eq!(p.current_index(), Some(0));
    }

    #[test]
    fn repeat_track_keeps_current_track() {
        let mut p = player();
        p.set_repeat_mode(RepeatMode::Track);
        assert!(p.play_index(1));
        p.set_position(50_000);
        assert!(p.next());
        assert_eq!(p.current_index(), Some(1));
        assert_eq!(p.snapshot().position_ms, 0);
    }

    #[test]
    fn previous_restarts_track_after_three_seconds() {
        let mut p = player();
        assert!(p.play_index(1));
        p.set_position(4_000);
        assert!(p.previous());
        assert_eq!(p.current_index(), Some(1));
        assert_eq!(p.snapshot().position_ms, 0);
    }

    #[test]
    fn seek_does_not_exceed_duration() {
        let mut p = player();
        assert!(p.play_index(0));
        p.seek(200_000);
        assert_eq!(p.snapshot().position_ms, 180_000);
    }

    #[test]
    fn shuffle_does_not_repeat_before_exhausting_queue() {
        let mut p = player();
        p.set_shuffle(true);
        assert!(p.play_index(0));
        assert!(p.next());
        let second = p.current_index().unwrap();
        assert_ne!(second, 0);
        assert!(p.next());
        let third = p.current_index().unwrap();
        assert_ne!(third, 0);
        assert_ne!(third, second);
        assert!(!p.next());
    }

    #[test]
    fn previous_uses_actual_playback_history() {
        let mut p = player();
        p.set_shuffle(true);
        assert!(p.play_index(0));
        assert!(p.next());
        let second = p.current_index().unwrap();
        assert!(p.next());
        assert!(p.previous());
        assert_eq!(p.current_index(), Some(second));
        assert!(p.previous());
        assert_eq!(p.current_index(), Some(0));
    }

    #[test]
    fn next_replays_forward_history_after_previous() {
        let mut p = player();
        assert!(p.play_index(0));
        assert!(p.next());
        assert!(p.next());
        let third = p.current_index();
        assert!(p.previous());
        assert!(p.next());
        assert_eq!(p.current_index(), third);
    }


    #[test]
    fn changing_queue_resets_playback_state() {
        let mut p = player();
        assert!(p.play_index(1));
        p.set_position(40_000);
        p.set_queue(vec![track("x")]);
        assert_eq!(p.current_index(), None);
        assert_eq!(p.snapshot().position_ms, 0);
        assert!(p.snapshot().current_track.is_none());
        assert_eq!(p.queue().len(), 1);
        assert!(!p.previous());
    }

    #[test]
    fn manual_selection_after_previous_discards_forward_history() {
        let mut p = player();
        assert!(p.play_index(0));
        assert!(p.next());
        assert!(p.next());
        assert!(p.previous());
        assert!(p.play_index(2));
        assert!(!p.next());
        assert_eq!(p.current_index(), Some(2));
    }

    #[test]
    fn shuffle_can_be_disabled_and_reenabled() {
        let mut p = player();
        p.set_shuffle(true);
        assert!(p.play_index(0));
        p.set_shuffle(false);
        assert!(p.next());
        assert_eq!(p.current_index(), Some(1));
        p.set_shuffle(true);
        assert!(p.next());
        assert_eq!(p.current_index(), Some(2));
    }
}
