import "dart:collection";

import "package:flutter/services.dart";

import "../src/rust/api.dart";

class MediaLibraryService {
  MediaLibraryService._();

  static const MethodChannel _channel = MethodChannel(
    "com.nexus.nexus_player/media",
  );

  static Future<List<TrackInfo>> loadTracks() async {
    final rawTracks = await _channel.invokeMethod<List<dynamic>>(
      "getAudioTracks",
    );

    if (rawTracks == null || rawTracks.isEmpty) {
      return const <TrackInfo>[];
    }

    return rawTracks.map((rawTrack) {
      final track = Map<Object?, Object?>.from(rawTrack as Map);
      final duration = track["durationMs"];

      return TrackInfo(
        id: track["id"] as String,
        uri: track["uri"] as String,
        title: track["title"] as String,
        artist: track["artist"] as String?,
        album: track["album"] as String?,
        durationMs: duration is num ? BigInt.from(duration.toInt()) : null,
      );
    }).toList(growable: false);
  }

  static const int _coverCacheLimit = 200;
  static final LinkedHashMap<String, Future<Uint8List?>> _coverCache =
      LinkedHashMap<String, Future<Uint8List?>>();

  /// Capa embutida da faixa (JPEG) ou null se nao houver. Com cache em memoria.
  static Future<Uint8List?> loadCover(String trackId, {int size = 400}) {
    final key = "$trackId:$size";
    final cached = _coverCache.remove(key);
    if (cached != null) {
      _coverCache[key] = cached;
      return cached;
    }

    final future = _fetchCover(trackId, size);
    _coverCache[key] = future;
    if (_coverCache.length > _coverCacheLimit) {
      _coverCache.remove(_coverCache.keys.first);
    }
    return future;
  }

  static Future<Uint8List?> _fetchCover(String trackId, int size) async {
    try {
      return await _channel.invokeMethod<Uint8List>(
        "getCover",
        <String, Object>{"id": trackId, "size": size},
      );
    } on PlatformException {
      return null;
    }
  }
}
