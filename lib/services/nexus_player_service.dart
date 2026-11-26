import "dart:async";

import "package:flutter/foundation.dart";
import "package:flutter/services.dart";

import "../src/rust/api.dart";
import "media_library_service.dart";

/// Ponte unica entre a UI e o PlayerController (Rust + MPV).
class NexusPlayerService {
  NexusPlayerService._() {
    _systemChannel.setMethodCallHandler(_onSystemCall);
    state.addListener(_syncSystemControls);
  }

  static final NexusPlayerService instance = NexusPlayerService._();

  static const Duration _tickInterval = Duration(milliseconds: 250);

  /// Canal com o servico de notificacao/MediaSession (Kotlin).
  static const MethodChannel _systemChannel = MethodChannel(
    "com.nexus.nexus_player/playback",
  );

  PlayerController? _controller;
  Timer? _timer;
  bool _ticking = false;

  String? _lastSystemKey = "stopped";
  String? _lastSystemTrackId;

  /// Estado atual do player (null antes de iniciar).
  final ValueNotifier<PlaybackState?> state = ValueNotifier<PlaybackState?>(
    null,
  );

  /// Indice da musica atual na fila (null se nenhuma).
  final ValueNotifier<int?> currentIndex = ValueNotifier<int?>(null);

  Future<PlayerController> _ensureController() async {
    final existing = _controller;
    if (existing != null) return existing;
    final created = await PlayerController.newInstance();
    _controller = created;
    return created;
  }

  /// Define a fila de reproducao a partir da biblioteca carregada.
  Future<void> setLibrary(List<TrackInfo> tracks) async {
    final controller = await _ensureController();
    await controller.setQueue(
      tracks: tracks
          .map(
            (track) => TrackInput(
              id: track.id,
              uri: track.uri,
              title: track.title,
              artist: track.artist,
              album: track.album,
              durationMs: track.durationMs,
            ),
          )
          .toList(growable: false),
    );
    await _refresh();
  }

  Future<bool> playIndex(int index) async {
    final controller = await _ensureController();
    final ok = await controller.playIndex(index: index);
    await _refresh();
    return ok;
  }

  Future<void> togglePlayPause() async {
    final controller = await _ensureController();
    await controller.togglePlayPause();
    await _refresh();
  }

  Future<void> next() async {
    final controller = await _ensureController();
    await controller.next();
    await _refresh();
  }

  Future<void> previous() async {
    final controller = await _ensureController();
    await controller.previous();
    await _refresh();
  }

  Future<void> stop() async {
    final controller = await _ensureController();
    await controller.stop();
    await _refresh();
  }

  Future<void> seekTo(Duration position) async {
    final controller = await _ensureController();
    await controller.seek(positionMs: BigInt.from(position.inMilliseconds));
    // Forca reenvio da posicao para a notificacao.
    _lastSystemKey = null;
    await _refresh();
  }

  Future<void> toggleShuffle() async {
    final controller = await _ensureController();
    final current = state.value?.shuffle ?? false;
    await controller.setShuffle(enabled: !current);
    await _refresh();
  }

  /// off -> queue -> track -> off
  Future<void> cycleRepeat() async {
    final controller = await _ensureController();
    final current = state.value?.repeatMode ?? "off";
    final next = switch (current) {
      "off" => "queue",
      "queue" => "track",
      _ => "off",
    };
    await controller.setRepeatMode(mode: next);
    await _refresh();
  }

  Future<String?> lastError() async {
    final controller = await _ensureController();
    return controller.lastError();
  }

  /// Botao voltar na tela inicial: com musica ativa vai para segundo plano
  /// (a musica continua); sem musica, fecha o app normalmente.
  Future<void> handleRootBack() async {
    final status = state.value?.status;
    if (status == "playing" || status == "paused") {
      await _invokeSystem("moveToBackground");
    } else {
      await SystemNavigator.pop();
    }
  }

  Future<void> _refresh() async {
    final controller = _controller;
    if (controller == null) return;
    state.value = await controller.snapshot();
    currentIndex.value = await controller.currentIndex();
    _syncTimer();
  }

  void _syncTimer() {
    final playing = state.value?.status == "playing";
    if (playing && _timer == null) {
      _timer = Timer.periodic(_tickInterval, (_) => _onTick());
    } else if (!playing && _timer != null) {
      _timer!.cancel();
      _timer = null;
    }
  }

  Future<void> _onTick() async {
    final controller = _controller;
    if (controller == null || _ticking) return;
    _ticking = true;
    try {
      final previousIndex = currentIndex.value;
      state.value = await controller.tick();
      final index = await controller.currentIndex();
      if (index != previousIndex) currentIndex.value = index;
      _syncTimer();
    } finally {
      _ticking = false;
    }
  }

  // ---- Notificacao / MediaSession -------------------------------------

  Future<dynamic> _onSystemCall(MethodCall call) async {
    if (call.method != "mediaAction") return null;

    final args = Map<Object?, Object?>.from(call.arguments as Map);
    final action = args["action"] as String?;
    final status = state.value?.status;

    switch (action) {
      case "play":
        if (status != "playing") await togglePlayPause();
      case "pause":
        if (status == "playing") await togglePlayPause();
      case "toggle":
        await togglePlayPause();
      case "next":
        await next();
      case "previous":
        await previous();
      case "stop":
        await stop();
      case "seek":
        final position = args["positionMs"];
        if (position is num) {
          await seekTo(Duration(milliseconds: position.toInt()));
        }
    }
    return null;
  }

  void _syncSystemControls() {
    final current = state.value;
    final track = current?.currentTrack;
    final status = current?.status ?? "idle";
    final active = status == "playing" || status == "paused";

    if (current == null || track == null || !active) {
      if (_lastSystemKey != "stopped") {
        _lastSystemKey = "stopped";
        _lastSystemTrackId = null;
        unawaited(_invokeSystem("stop"));
      }
      return;
    }

    final key = "${track.id}|$status";
    if (key == _lastSystemKey) return;

    final trackChanged = _lastSystemTrackId != track.id;
    _lastSystemKey = key;
    _lastSystemTrackId = track.id;
    unawaited(_pushSystemState(current, track, includeCover: trackChanged));
  }

  Future<void> _pushSystemState(
    PlaybackState current,
    TrackInfo track, {
    required bool includeCover,
  }) async {
    Uint8List? cover;
    if (includeCover) {
      cover = await MediaLibraryService.loadCover(track.id, size: 400);
    }

    await _invokeSystem("update", <String, Object?>{
      "trackId": track.id,
      "title": track.title,
      "artist": track.artist,
      "album": track.album,
      "durationMs": (current.durationMs ?? track.durationMs)?.toInt() ?? 0,
      "positionMs": current.positionMs.toInt(),
      "playing": current.status == "playing",
      "cover": cover,
    });
  }

  Future<void> _invokeSystem(String method, [Object? arguments]) async {
    try {
      await _systemChannel.invokeMethod<void>(method, arguments);
    } catch (_) {
      // Sem servico de notificacao nao deve derrubar a reproducao.
    }
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }
}