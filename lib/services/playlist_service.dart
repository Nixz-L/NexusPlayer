import "dart:convert";
import "dart:io";

import "package:path_provider/path_provider.dart";
import "package:shared_preferences/shared_preferences.dart";

class NexusPlaylist {
  final String id;
  final String title;
  final List<String> trackIds;
  final int artwork;
  final String? coverPath;

  const NexusPlaylist({
    required this.id,
    required this.title,
    required this.trackIds,
    required this.artwork,
    this.coverPath,
  });

  NexusPlaylist copyWith({
    String? title,
    List<String>? trackIds,
    String? coverPath,
    bool clearCover = false,
  }) {
    return NexusPlaylist(
      id: id,
      title: title ?? this.title,
      trackIds: trackIds ?? this.trackIds,
      artwork: artwork,
      coverPath: clearCover ? null : (coverPath ?? this.coverPath),
    );
  }

  Map<String, dynamic> toJson() => {
    "id": id,
    "title": title,
    "trackIds": trackIds,
    "artwork": artwork,
    "coverPath": coverPath,
  };

  factory NexusPlaylist.fromJson(Map<String, dynamic> json) {
    return NexusPlaylist(
      id: json["id"] as String,
      title: json["title"] as String,
      trackIds: (json["trackIds"] as List<dynamic>)
          .map((id) => id as String)
          .toList(),
      artwork: (json["artwork"] as num?)?.toInt() ?? 0,
      coverPath: json["coverPath"] as String?,
    );
  }
}

class PlaylistService {
  PlaylistService._();

  static final PlaylistService instance = PlaylistService._();

  static const String _storageKey = "nexus_user_playlists";

  Future<List<NexusPlaylist>> loadPlaylists() async {
    final preferences = await SharedPreferences.getInstance();
    final stored = preferences.getString(_storageKey);

    if (stored == null || stored.isEmpty) return [];

    try {
      final decoded = jsonDecode(stored) as List<dynamic>;

      return decoded
          .map(
            (item) => NexusPlaylist.fromJson(
              Map<String, dynamic>.from(item as Map),
            ),
          )
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _save(List<NexusPlaylist> playlists) async {
    final preferences = await SharedPreferences.getInstance();

    final encoded = jsonEncode(
      playlists.map((playlist) => playlist.toJson()).toList(),
    );

    await preferences.setString(_storageKey, encoded);
  }

  Future<void> _deleteFile(String? path) async {
    if (path == null || path.isEmpty) return;
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  Future<NexusPlaylist> createPlaylist(String title) async {
    final normalizedTitle = title.trim();

    if (normalizedTitle.isEmpty) {
      throw ArgumentError("O nome da playlist n\u00e3o pode estar vazio.");
    }

    final playlists = await loadPlaylists();

    final playlist = NexusPlaylist(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      title: normalizedTitle,
      trackIds: const [],
      artwork: playlists.length % 4,
    );

    playlists.add(playlist);
    await _save(playlists);

    return playlist;
  }

  Future<void> renamePlaylist(String id, String title) async {
    final normalizedTitle = title.trim();

    if (normalizedTitle.isEmpty) {
      throw ArgumentError("O nome da playlist n\u00e3o pode estar vazio.");
    }

    final playlists = await loadPlaylists();
    final index = playlists.indexWhere((playlist) => playlist.id == id);

    if (index < 0) return;

    playlists[index] = playlists[index].copyWith(title: normalizedTitle);
    await _save(playlists);
  }

  /// Define a capa da playlist a partir de [sourcePath] (copia para o app)
  /// ou remove a capa quando [sourcePath] e nulo.
  Future<void> setCover(String id, String? sourcePath) async {
    final playlists = await loadPlaylists();
    final index = playlists.indexWhere((playlist) => playlist.id == id);

    if (index < 0) return;

    final old = playlists[index].coverPath;

    if (sourcePath == null) {
      playlists[index] = playlists[index].copyWith(clearCover: true);
      await _save(playlists);
      await _deleteFile(old);
      return;
    }

    final base = await getApplicationDocumentsDirectory();
    final dir = Directory("${base.path}/playlist_covers");
    if (!await dir.exists()) await dir.create(recursive: true);

    final dot = sourcePath.lastIndexOf(".");
    final ext = dot > sourcePath.lastIndexOf("/") && dot >= 0
        ? sourcePath.substring(dot)
        : ".jpg";
    final target =
        "${dir.path}/${id}_${DateTime.now().millisecondsSinceEpoch}$ext";

    await File(sourcePath).copy(target);

    playlists[index] = playlists[index].copyWith(coverPath: target);
    await _save(playlists);
    await _deleteFile(old);
  }

  Future<void> deletePlaylist(String id) async {
    final playlists = await loadPlaylists();
    final removed = playlists.where((playlist) => playlist.id == id).toList();

    playlists.removeWhere((playlist) => playlist.id == id);
    await _save(playlists);

    for (final playlist in removed) {
      await _deleteFile(playlist.coverPath);
    }
  }

  Future<void> addTrack(String playlistId, String trackId) async {
    final playlists = await loadPlaylists();
    final index = playlists.indexWhere(
      (playlist) => playlist.id == playlistId,
    );

    if (index < 0) return;

    final playlist = playlists[index];

    if (playlist.trackIds.contains(trackId)) return;

    playlists[index] = playlist.copyWith(
      trackIds: [...playlist.trackIds, trackId],
    );

    await _save(playlists);
  }

  Future<void> removeTrack(String playlistId, String trackId) async {
    final playlists = await loadPlaylists();
    final index = playlists.indexWhere(
      (playlist) => playlist.id == playlistId,
    );

    if (index < 0) return;

    final playlist = playlists[index];

    playlists[index] = playlist.copyWith(
      trackIds: playlist.trackIds.where((id) => id != trackId).toList(),
    );

    await _save(playlists);
  }
}