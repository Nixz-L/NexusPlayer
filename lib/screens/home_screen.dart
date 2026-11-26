import "dart:math" as math;

import "package:flutter/services.dart";
import "dart:io";

import "package:image_picker/image_picker.dart";
import "package:url_launcher/url_launcher.dart";

import "../services/media_library_service.dart";
import "../services/nexus_player_service.dart";
import "../services/playlist_service.dart";
import "../widgets/track_cover.dart";
import "../src/rust/api.dart";

import "package:material_ui/material_ui.dart";

const _bg = Color(0xFF05040A);
const _violet = Color(0xFFAA55FF);
const _muted = Color(0xFF898398);

const _playlistPalettes = [
  [Color(0xFF34206C), Color(0xFF090D27)],
  [Color(0xFF482052), Color(0xFF100D20)],
  [Color(0xFF3C167F), Color(0xFF080C29)],
  [Color(0xFF40306D), Color(0xFF111426)],
];
class NexusHomeScreen extends StatefulWidget {
  const NexusHomeScreen({super.key});

  @override
  State<NexusHomeScreen> createState() => _NexusHomeScreenState();
}

class _NexusHomeScreenState extends State<NexusHomeScreen> {
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();

  int _tab = 0;
  List<TrackInfo> _libraryTracks = const [];
  List<NexusPlaylist> _playlists = const [];
  bool _playlistsLoading = false;
  bool _libraryLoading = false;
  bool _libraryRequested = false;
  String? _libraryError;
  String? _queueSignature;
  bool _playlistBusy = false;
  late final Future<String> _versionFuture = getNexusVersion();

  @override
  void initState() {
    super.initState();
    _loadLibrary();
    _loadPlaylists();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  Future<void> _loadPlaylists() async {
    if (_playlistsLoading) return;

    setState(() => _playlistsLoading = true);

    try {
      final playlists = await PlaylistService.instance.loadPlaylists();
      if (!mounted) return;
      setState(() => _playlists = playlists);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Erro ao carregar playlists: $error")),
      );
    } finally {
      if (mounted) {
        setState(() => _playlistsLoading = false);
      }
    }
  }
  void _selectTab(int index) {
    setState(() => _tab = index);
    if (index == 1 && !_libraryRequested) _loadLibrary();
  }

  Future<void> _loadLibrary() async {
    if (_libraryLoading) return;
    setState(() {
      _libraryLoading = true;
      _libraryError = null;
      _libraryRequested = true;
    });

    try {
      final tracks = await MediaLibraryService.loadTracks();
      if (!mounted) return;
      try {
        await NexusPlayerService.instance.setLibrary(tracks);
        _queueSignature = _queueSignatureFor("library", tracks);
      } catch (_) {
        // A biblioteca continua visivel mesmo se o player nao iniciar.
      }
      if (!mounted) return;
      setState(() => _libraryTracks = tracks);
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() {
        _libraryError = error.code == "permission_denied"
            ? "Permissão para acessar músicas negada."
            : "Não foi possível acessar a biblioteca.";
        _libraryRequested = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _libraryError = "Erro ao carregar suas músicas.";
        _libraryRequested = false;
      });
    } finally {
      if (mounted) setState(() => _libraryLoading = false);
    }
  }

  void _selectTrack(TrackInfo track) {
    final index = _libraryTracks.indexWhere((item) => item.id == track.id);
    if (index < 0) return;
    _playFrom(_libraryTracks, "library", index);
  }
  Future<void> _runPlayerAction(Future<void> Function() action) async {
    await action();
    if (!mounted) return;
    await _reportPlaybackError(context);
  }

  void _openNowPlaying() {
    Navigator.of(context).push(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 420),
        reverseTransitionDuration: const Duration(milliseconds: 320),
        pageBuilder: (_, animation, secondaryAnimation) {
          return const NowPlayingScreen();
        },
        transitionsBuilder: (_, animation, secondaryAnimation, child) {
          final curved = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
          );

          return FadeTransition(
            opacity: curved,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.045),
                end: Offset.zero,
              ).animate(curved),
              child: child,
            ),
          );
        },
      ),
    );
  }

  Widget _trackThumb(TrackInfo track, Color background, double radius) {
    return Container(
      width: 46,
      height: 46,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(radius),
      ),
      child: TrackCover(
        trackId: track.id,
        size: 160,
        fallback: const Icon(Icons.music_note_rounded, color: _violet),
      ),
    );
  }

  // ---- Playlists ------------------------------------------------------

  static const RoundedRectangleBorder _sheetShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
  );

  Widget _sheetHandle() {
    return Center(
      child: Container(
        width: 38,
        height: 4,
        decoration: BoxDecoration(
          color: Colors.white24,
          borderRadius: BorderRadius.circular(8),
        ),
      ),
    );
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: const Color(0xFF1A1226),
        content: Text(message),
      ),
    );
  }

  Future<void> _refreshPlaylists() async {
    final playlists = await PlaylistService.instance.loadPlaylists();
    if (!mounted) return;
    setState(() => _playlists = playlists);
  }

  /// Executa uma operacao de playlist em serie (evita corrida no armazenamento).
  Future<void> _playlistOp(Future<void> Function() operation) async {
    if (_playlistBusy) return;
    _playlistBusy = true;
    try {
      await operation();
      await _refreshPlaylists();
    } catch (_) {
      _showMessage("N\u00e3o foi poss\u00edvel salvar a playlist.");
    } finally {
      _playlistBusy = false;
    }
  }

  List<TrackInfo> _resolveTracks(NexusPlaylist playlist) {
    final byId = {for (final track in _libraryTracks) track.id: track};
    return playlist.trackIds
        .map((id) => byId[id])
        .whereType<TrackInfo>()
        .toList();
  }

  String _queueSignatureFor(String source, List<TrackInfo> queue) {
    return "$source:${Object.hashAll(queue.map((track) => track.id))}";
  }

  /// Toca [queue] a partir de [index], usando essa lista como fila do player.
  Future<void> _playFrom(
    List<TrackInfo> queue,
    String source,
    int index,
  ) async {
    if (index < 0 || index >= queue.length) return;

    final player = NexusPlayerService.instance;
    final track = queue[index];
    final state = player.state.value;
    final active = state?.status == "playing" || state?.status == "paused";
    final signature = _queueSignatureFor(source, queue);

    if (signature == _queueSignature &&
        active &&
        state?.currentTrack?.id == track.id) {
      _openNowPlaying();
      return;
    }

    _openNowPlaying();

    if (signature != _queueSignature) {
      try {
        await player.setLibrary(queue);
        _queueSignature = signature;
      } catch (_) {
        // Segue tentando tocar com a fila anterior.
      }
    }

    final started = await player.playIndex(index);
    if (started || !mounted) return;
    await _reportPlaybackError(context);
  }

  Future<String?> _promptPlaylistName({
    required String title,
    required String confirmLabel,
    String initial = "",
  }) {
    final controller = TextEditingController(text: initial);

    return showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: const Color(0xFF100D19),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
            side: const BorderSide(color: Color(0xFF38234D)),
          ),
          title: Text(
            title,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          content: TextField(
            controller: controller,
            autofocus: true,
            maxLength: 40,
            textCapitalization: TextCapitalization.sentences,
            style: const TextStyle(fontSize: 14),
            decoration: const InputDecoration(
              hintText: "Nome da playlist",
              hintStyle: TextStyle(color: _muted),
              counterText: "",
              enabledBorder: UnderlineInputBorder(
                borderSide: BorderSide(color: Color(0xFF48305F)),
              ),
              focusedBorder: UnderlineInputBorder(
                borderSide: BorderSide(color: _violet),
              ),
            ),
            onSubmitted: (value) => Navigator.pop(dialogContext, value),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text("Cancelar", style: TextStyle(color: _muted)),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, controller.text),
              child: Text(confirmLabel, style: const TextStyle(color: _violet)),
            ),
          ],
        );
      },
    );
  }

  Future<NexusPlaylist?> _createPlaylist() async {
    final name = await _promptPlaylistName(
      title: "Nova playlist",
      confirmLabel: "Criar",
    );
    if (name == null || name.trim().isEmpty) return null;

    NexusPlaylist? created;
    await _playlistOp(() async {
      created = await PlaylistService.instance.createPlaylist(name);
    });
    return created;
  }

  Future<void> _createAndOpenPlaylist() async {
    final created = await _createPlaylist();
    if (created == null || !mounted) return;
    _openPlaylist(created);
  }

  Future<void> _renamePlaylist(NexusPlaylist playlist) async {
    final name = await _promptPlaylistName(
      title: "Renomear playlist",
      confirmLabel: "Salvar",
      initial: playlist.title,
    );
    if (name == null || name.trim().isEmpty) return;
    await _playlistOp(
      () => PlaylistService.instance.renamePlaylist(playlist.id, name),
    );
  }

  Future<bool> _deletePlaylist(NexusPlaylist playlist) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: const Color(0xFF100D19),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
            side: const BorderSide(color: Color(0xFF38234D)),
          ),
          title: const Text(
            "Excluir playlist?",
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          content: Text(
            "\"${playlist.title}\" ser\u00e1 removida. Suas m\u00fasicas continuam no aparelho.",
            style: const TextStyle(color: _muted, fontSize: 13),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text("Cancelar", style: TextStyle(color: _muted)),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text(
                "Excluir",
                style: TextStyle(color: Color(0xFFFF6B8A)),
              ),
            ),
          ],
        );
      },
    );

    if (confirmed != true) return false;
    await _playlistOp(
      () => PlaylistService.instance.deletePlaylist(playlist.id),
    );
    return true;
  }

  Future<void> _pickPlaylistCover(NexusPlaylist playlist) async {
    try {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 900,
        maxHeight: 900,
        imageQuality: 88,
      );
      if (picked == null) return;
      await _playlistOp(
        () => PlaylistService.instance.setCover(playlist.id, picked.path),
      );
    } catch (_) {
      _showMessage("N\u00e3o foi poss\u00edvel abrir a galeria.");
    }
  }

  Future<void> _removePlaylistCover(NexusPlaylist playlist) {
    return _playlistOp(
      () => PlaylistService.instance.setCover(playlist.id, null),
    );
  }

  Future<void> _openGithub() async {
    const link = "https://github.com/Nixz-L";
    try {
      final ok = await launchUrl(
        Uri.parse(link),
        mode: LaunchMode.externalApplication,
      );
      if (ok) return;
    } catch (_) {}
    await Clipboard.setData(const ClipboardData(text: link));
    _showMessage("Link copiado.");
  }

Future<void> _showPlaylistActions(NexusPlaylist playlist) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF100D19),
      shape: _sheetShape,
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 16, 22, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _sheetHandle(),
                const SizedBox(height: 18),
                Text(
                  playlist.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.image_outlined, color: _violet),
                  title: const Text("Alterar capa", style: TextStyle(fontSize: 14)),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _pickPlaylistCover(playlist);
                  },
                ),
                if (playlist.coverPath != null)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.hide_image_outlined, color: _muted),
                    title: const Text("Remover capa", style: TextStyle(fontSize: 14)),
                    onTap: () {
                      Navigator.pop(sheetContext);
                      _removePlaylistCover(playlist);
                    },
                  ),
ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.edit_rounded, color: _violet),
                  title: const Text("Renomear", style: TextStyle(fontSize: 14)),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _renamePlaylist(playlist);
                  },
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(
                    Icons.delete_outline_rounded,
                    color: Color(0xFFFF6B8A),
                  ),
                  title: const Text("Excluir", style: TextStyle(fontSize: 14)),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _deletePlaylist(playlist);
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _showAddTracksSheet(NexusPlaylist playlist) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF100D19),
      isScrollControlled: true,
      shape: _sheetShape,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final current = _playlists.firstWhere(
              (item) => item.id == playlist.id,
              orElse: () => playlist,
            );
            final selected = current.trackIds.toSet();

            return SafeArea(
              child: SizedBox(
                height: MediaQuery.of(sheetContext).size.height * 0.8,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(22, 16, 22, 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _sheetHandle(),
                      const SizedBox(height: 18),
                      Row(
                        children: [
                          const Expanded(
                            child: Text(
                              "Adicionar m\u00fasicas",
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          TextButton(
                            onPressed: () => Navigator.pop(sheetContext),
                            child: const Text(
                              "Concluir",
                              style: TextStyle(color: _violet),
                            ),
                          ),
                        ],
                      ),
                      Text(
                        "${selected.length} ${selected.length == 1 ? "selecionada" : "selecionadas"}",
                        style: const TextStyle(color: _muted, fontSize: 12),
                      ),
                      const SizedBox(height: 10),
                      Expanded(
                        child: _libraryTracks.isEmpty
                            ? const Center(
                                child: Text(
                                  "Sua biblioteca est\u00e1 vazia.",
                                  style: TextStyle(color: _muted),
                                ),
                              )
                            : ListView.builder(
                                itemCount: _libraryTracks.length,
                                itemBuilder: (itemContext, index) {
                                  final track = _libraryTracks[index];
                                  final isSelected = selected.contains(
                                    track.id,
                                  );

                                  return ListTile(
                                    contentPadding: EdgeInsets.zero,
                                    leading: _trackThumb(
                                      track,
                                      const Color(0xFF191020),
                                      10,
                                    ),
                                    title: Text(
                                      track.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontSize: 14),
                                    ),
                                    subtitle: Text(
                                      track.artist ?? "Unknown artist",
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: _muted,
                                        fontSize: 11,
                                      ),
                                    ),
                                    trailing: Icon(
                                      isSelected
                                          ? Icons.check_circle_rounded
                                          : Icons.radio_button_unchecked_rounded,
                                      color: isSelected ? _violet : _muted,
                                    ),
                                    onTap: () async {
                                      await _playlistOp(
                                        () => isSelected
                                            ? PlaylistService.instance
                                                  .removeTrack(
                                                    playlist.id,
                                                    track.id,
                                                  )
                                            : PlaylistService.instance
                                                  .addTrack(
                                                    playlist.id,
                                                    track.id,
                                                  ),
                                      );
                                      if (context.mounted) {
                                        setSheetState(() {});
                                      }
                                    },
                                  );
                                },
                              ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _showAddToPlaylistSheet(TrackInfo track) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF100D19),
      isScrollControlled: true,
      shape: _sheetShape,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return SafeArea(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(sheetContext).size.height * 0.7,
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(22, 16, 22, 20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _sheetHandle(),
                      const SizedBox(height: 18),
                      const Text(
                        "Adicionar \u00e0 playlist",
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        track.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: _muted, fontSize: 12),
                      ),
                      const SizedBox(height: 10),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.add_rounded, color: _violet),
                        title: const Text(
                          "Nova playlist",
                          style: TextStyle(fontSize: 14),
                        ),
                        onTap: () async {
                          final created = await _createPlaylist();
                          if (created == null) return;
                          await _playlistOp(
                            () => PlaylistService.instance.addTrack(
                              created.id,
                              track.id,
                            ),
                          );
                          if (context.mounted) setSheetState(() {});
                        },
                      ),
                      Flexible(
                        child: ListView(
                          shrinkWrap: true,
                          children: [
                            for (final playlist in _playlists)
                              ListTile(
                                contentPadding: EdgeInsets.zero,
                                leading: ClipRRect(
                                  borderRadius: BorderRadius.circular(10),
                                  child: SizedBox(
                                    width: 42,
                                    height: 42,
                                    child: _PlaylistArt(playlist: playlist),
                                  ),
                                ),
                                title: Text(
                                  playlist.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 14),
                                ),
                                subtitle: Text(
                                  "${playlist.trackIds.length} faixas",
                                  style: const TextStyle(
                                    color: _muted,
                                    fontSize: 11,
                                  ),
                                ),
                                trailing: Icon(
                                  playlist.trackIds.contains(track.id)
                                      ? Icons.check_circle_rounded
                                      : Icons.radio_button_unchecked_rounded,
                                  color: playlist.trackIds.contains(track.id)
                                      ? _violet
                                      : _muted,
                                ),
                                onTap: () async {
                                  final has = playlist.trackIds.contains(
                                    track.id,
                                  );
                                  await _playlistOp(
                                    () => has
                                        ? PlaylistService.instance.removeTrack(
                                            playlist.id,
                                            track.id,
                                          )
                                        : PlaylistService.instance.addTrack(
                                            playlist.id,
                                            track.id,
                                          ),
                                  );
                                  if (context.mounted) setSheetState(() {});
                                },
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _openPlaylist(NexusPlaylist initial) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF100D19),
      isScrollControlled: true,
      shape: _sheetShape,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final playlist = _playlists.firstWhere(
              (item) => item.id == initial.id,
              orElse: () => initial,
            );
            final tracks = _resolveTracks(playlist);
            final source = "playlist:${playlist.id}";

            return SafeArea(
              child: SizedBox(
                height: MediaQuery.of(sheetContext).size.height * 0.75,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(22, 16, 22, 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _sheetHandle(),
                      const SizedBox(height: 22),
                      Row(
                        children: [
                          SizedBox(
                            width: 76,
                            height: 76,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(13),
                              child: _PlaylistArt(playlist: playlist),
                            ),
                          ),
                          const SizedBox(width: 15),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  playlist.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 19,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 5),
                                Text(
                                  "${tracks.length} faixas",
                                  style: const TextStyle(
                                    color: _muted,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            tooltip: "Alterar capa",
                            onPressed: () async {
                              await _pickPlaylistCover(playlist);
                              if (context.mounted) setSheetState(() {});
                            },
                            icon: const Icon(
                              Icons.image_outlined,
                              color: Colors.white70,
                              size: 21,
                            ),
                          ),
IconButton(
                            tooltip: "Renomear",
                            onPressed: () async {
                              await _renamePlaylist(playlist);
                              if (context.mounted) setSheetState(() {});
                            },
                            icon: const Icon(
                              Icons.edit_rounded,
                              color: Colors.white70,
                              size: 21,
                            ),
                          ),
                          IconButton(
                            tooltip: "Excluir",
                            onPressed: () async {
                              final deleted = await _deletePlaylist(playlist);
                              if (deleted && sheetContext.mounted) {
                                Navigator.pop(sheetContext);
                              }
                            },
                            icon: const Icon(
                              Icons.delete_outline_rounded,
                              color: Color(0xFFFF6B8A),
                              size: 22,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 18),
                      Row(
                        children: [
                          Expanded(
                            child: _PillButton(
                              icon: Icons.play_arrow_rounded,
                              label: "Tocar",
                              filled: true,
                              onTap: tracks.isEmpty
                                  ? null
                                  : () {
                                      Navigator.pop(sheetContext);
                                      _playFrom(tracks, source, 0);
                                    },
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _PillButton(
                              icon: Icons.add_rounded,
                              label: "Adicionar",
                              onTap: () async {
                                await _showAddTracksSheet(playlist);
                                if (context.mounted) setSheetState(() {});
                              },
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      const Text(
                        "FAIXAS",
                        style: TextStyle(
                          color: _violet,
                          fontSize: 10,
                          letterSpacing: 2,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Expanded(
                        child: tracks.isEmpty
                            ? const Center(
                                child: Text(
                                  "Esta playlist ainda n\u00e3o tem m\u00fasicas.",
                                  style: TextStyle(color: _muted),
                                ),
                              )
                            : ListView.builder(
                                itemCount: tracks.length,
                                itemBuilder: (itemContext, index) {
                                  final track = tracks[index];

                                  return ListTile(
                                    contentPadding: EdgeInsets.zero,
                                    leading: _trackThumb(
                                      track,
                                      const Color(0xFF191020),
                                      10,
                                    ),
                                    title: Text(
                                      track.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontSize: 14),
                                    ),
                                    subtitle: Text(
                                      track.artist ?? "Unknown artist",
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: _muted,
                                        fontSize: 11,
                                      ),
                                    ),
                                    trailing: IconButton(
                                      tooltip: "Remover da playlist",
                                      onPressed: () async {
                                        await _playlistOp(
                                          () => PlaylistService.instance
                                              .removeTrack(
                                                playlist.id,
                                                track.id,
                                              ),
                                        );
                                        if (context.mounted) {
                                          setSheetState(() {});
                                        }
                                      },
                                      icon: const Icon(
                                        Icons.remove_circle_outline_rounded,
                                        color: _muted,
                                        size: 22,
                                      ),
                                    ),
                                    onTap: () {
                                      Navigator.pop(sheetContext);
                                      _playFrom(tracks, source, index);
                                    },
                                  );
                                },
                              ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) NexusPlayerService.instance.handleRootBack();
      },
      child: _buildScaffold(context),
    );
  }

  Widget _buildScaffold(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: Stack(
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(painter: _WaveBackgroundPainter()),
            ),
          ),
          Positioned.fill(
            child: SafeArea(
              bottom: false,
              child: _tab == 0 ? _buildHome() : _buildOtherTab(),
            ),
          ),
          if (_tab == 0)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: 290,
              child: IgnorePointer(
                child: DecoratedBox(
                  key: const ValueKey("_bottomFade"),
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0x0005040A), Color(0xFF05040A)],
                      stops: [0.0, 0.55],
                    ),
                  ),
                ),
              ),
            ),
          _buildBottomDock(),
        ],
      ),
    );
  }

  Widget _buildHome() {
    final query = _searchController.text.trim().toLowerCase();
    final filtered = _playlists.where((playlist) => playlist.title.toLowerCase().contains(query)).toList();

    return SingleChildScrollView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.fromLTRB(20, 5, 20, 225),
      child: Column(
        children: [
          _buildHeader(),
          const SizedBox(height: 14),
          SizedBox(
            height: 245,
            child: Stack(
              children: [
                Positioned.fill(
                  child: CustomPaint(painter: _HeroWavePainter()),
                ),
                Align(
                  alignment: const Alignment(0, 0.72),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        "Good evening.",
                        style: TextStyle(
                          fontSize: 36,
                          fontWeight: FontWeight.w300,
                          letterSpacing: -1.4,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        "Your music. Your space.",
                        style: TextStyle(
                          color: _violet,
                          fontSize: 17,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _buildSearch(),
          const SizedBox(height: 42),
          _buildSectionTitle("Your music", "See all", () {
            _selectTab(1);
          }),
          const SizedBox(height: 8),
          _buildHomeTracks(query),
          const SizedBox(height: 28),
          _buildSectionTitle("Playlists", "See all", () {
            _selectTab(2);
          }),
          const SizedBox(height: 16),
          SizedBox(
            height: 215,
            child: filtered.isEmpty
                ? Center(
                    child: _playlists.isEmpty
                        ? TextButton.icon(
                            onPressed: _createAndOpenPlaylist,
                            icon: const Icon(Icons.add_rounded, color: _violet),
                            label: const Text(
                              "Criar sua primeira playlist",
                              style: TextStyle(color: _violet),
                            ),
                          )
                        : const Text(
                            "Nenhuma playlist encontrada",
                            style: TextStyle(color: _muted),
                          ),
                  )
                : ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: filtered.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 15),
                    itemBuilder: (context, index) {
                      final entry = filtered[index];
                      return _PlaylistCard(
                        playlist: entry,
                        onTap: () => _openPlaylist(entry),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildHomeTracks(String query) {
    final tracks = _libraryTracks
        .where((track) {
          final searchable = [
            track.title,
            track.artist ?? "",
            track.album ?? "",
          ].join(" ").toLowerCase();
          return searchable.contains(query);
        })
        .toList();

    if (_libraryLoading && tracks.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: CircularProgressIndicator(color: _violet, strokeWidth: 2),
        ),
      );
    }

    if (tracks.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 18),
        child: Text(
          _libraryError ?? "Suas músicas aparecerão aqui.",
          style: const TextStyle(color: _muted, fontSize: 12),
        ),
      );
    }

    return Column(
      children: tracks.map((track) {
        return ListTile(
          contentPadding: EdgeInsets.zero,
          leading: _trackThumb(track, const Color(0xFF191020), 12),
          title: Text(
            track.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
          ),
          subtitle: Text(
            track.artist ?? "Unknown artist",
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: _muted, fontSize: 11),
          ),
          onLongPress: () => _showAddToPlaylistSheet(track),
          trailing: const Icon(
            Icons.chevron_right_rounded,
            color: Color(0xFFB9A4D5),
          ),
          onTap: () => _selectTrack(track),
        );
      }).toList(),
    );
  }

  Widget _buildHeader() {
    return SizedBox(
      height: 65,
      child: Stack(
        alignment: Alignment.center,
        children: [
          const Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                "N E X U S",
                style: TextStyle(
                  fontSize: 23,
                  fontWeight: FontWeight.w400,
                  letterSpacing: 2,
                ),
              ),
              SizedBox(height: 3),
              Text(
                "Y O U R   M U S I C",
                style: TextStyle(
                  fontSize: 8,
                  color: Color(0xFFB5A8C8),
                  letterSpacing: 1.5,
                ),
              ),
            ],
          ),
          Align(
            alignment: Alignment.centerRight,
            child: IconButton(
              onPressed: () => _searchFocus.requestFocus(),
              icon: const Icon(
                Icons.search_rounded,
                size: 27,
                color: Color(0xFFD9D2E7),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearch() {
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 17),
      decoration: BoxDecoration(
        color: const Color(0xD7100D1B),
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: const Color(0xFF48305F)),
        boxShadow: [
          BoxShadow(color: _violet.withValues(alpha: 0.09), blurRadius: 22),
        ],
      ),
      child: Row(
        children: [
          const Icon(Icons.search_rounded, color: _muted, size: 23),
          const SizedBox(width: 13),
          Expanded(
            child: TextField(
              controller: _searchController,
              focusNode: _searchFocus,
              onChanged: (_) => setState(() {}),
              style: const TextStyle(fontSize: 13),
              decoration: const InputDecoration(
                hintText: "Search songs, artists, albums...",
                hintStyle: TextStyle(color: _muted, fontSize: 13),
                border: InputBorder.none,
                isDense: true,
              ),
            ),
          ),
          IconButton(
            onPressed: () {
              _searchController.clear();
              _searchFocus.unfocus();
              setState(() {});
            },
            icon: Icon(
              _searchController.text.isEmpty
                  ? Icons.tune_rounded
                  : Icons.close_rounded,
              color: const Color(0xFFC69BFF),
              size: 21,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(String title, String action, VoidCallback onTap) {
    return Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: const TextStyle(
              fontSize: 19,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.3,
            ),
          ),
        ),
        GestureDetector(
          onTap: onTap,
          child: Row(
            children: [
              Text(
                action,
                style: const TextStyle(color: _violet, fontSize: 13),
              ),
              const SizedBox(width: 4),
              const Icon(Icons.arrow_forward_rounded, color: _violet, size: 17),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildOtherTab() {
    if (_tab == 1) return _buildLibraryTab();
    if (_tab == 2) return _buildPlaylistsTab();
    return _buildSettingsTab();
  }

  Widget _buildPlaylistsTab() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 5, 22, 225),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeader(),
          const SizedBox(height: 24),
          Row(
            children: [
              const Expanded(
                child: Text(
                  "Playlists",
                  style: TextStyle(
                    fontSize: 27,
                    fontWeight: FontWeight.w500,
                    letterSpacing: -0.6,
                  ),
                ),
              ),
              IconButton(
                tooltip: "Nova playlist",
                onPressed: _createAndOpenPlaylist,
                icon: const Icon(Icons.add_rounded, color: _violet, size: 28),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            "${_playlists.length} ${_playlists.length == 1 ? "playlist" : "playlists"}",
            style: const TextStyle(color: _muted, fontSize: 12),
          ),
          const SizedBox(height: 18),
          Expanded(child: _buildPlaylistsBody()),
        ],
      ),
    );
  }

  Widget _buildPlaylistsBody() {
    if (_playlistsLoading && _playlists.isEmpty) {
      return const Center(
        child: CircularProgressIndicator(color: _violet, strokeWidth: 2),
      );
    }

    if (_playlists.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.queue_music_rounded, size: 42, color: _violet),
            const SizedBox(height: 16),
            const Text(
              "Nenhuma playlist ainda",
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 17),
            ),
            const SizedBox(height: 7),
            const Text(
              "Crie uma playlist para organizar suas m\u00fasicas.",
              textAlign: TextAlign.center,
              style: TextStyle(color: _muted, fontSize: 12),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: 190,
              child: _PillButton(
                icon: Icons.add_rounded,
                label: "Nova playlist",
                filled: true,
                onTap: _createAndOpenPlaylist,
              ),
            ),
          ],
        ),
      );
    }

    return ListView.separated(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 18),
      itemCount: _playlists.length,
      separatorBuilder: (_, _) =>
          Divider(height: 1, color: Colors.white.withValues(alpha: 0.055)),
      itemBuilder: (context, index) {
        final playlist = _playlists[index];

        return ListTile(
          contentPadding: EdgeInsets.zero,
          leading: ClipRRect(
            borderRadius: BorderRadius.circular(11),
            child: SizedBox(
              width: 46,
              height: 46,
              child: _PlaylistArt(playlist: playlist),
            ),
          ),
          title: Text(
            playlist.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              "${playlist.trackIds.length} faixas",
              style: const TextStyle(color: _muted, fontSize: 11),
            ),
          ),
          trailing: IconButton(
            tooltip: "Op\u00e7\u00f5es",
            onPressed: () => _showPlaylistActions(playlist),
            icon: const Icon(
              Icons.more_vert_rounded,
              color: Color(0xFFB9A4D5),
            ),
          ),
          onTap: () => _openPlaylist(playlist),
          onLongPress: () => _showPlaylistActions(playlist),
        );
      },
    );
  }

  Widget _settingsLabel(String text) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 10),
      child: Text(
        text,
        style: const TextStyle(color: _violet, fontSize: 10, letterSpacing: 2),
      ),
    );
  }

  Widget _settingsTile({
    required IconData icon,
    required String title,
    required String subtitle,
    VoidCallback? onTap,
    Widget? trailing,
  }) {
    return ListTile(
      onTap: onTap,
      tileColor: const Color(0xFF110D1C),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: Color(0xFF2A1B3D)),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Icon(icon, color: _violet),
      title: Text(
        title,
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 3),
        child: Text(
          subtitle,
          style: const TextStyle(color: _muted, fontSize: 11),
        ),
      ),
      trailing:
          trailing ??
          (onTap == null
              ? null
              : const Icon(
                  Icons.chevron_right_rounded,
                  color: Color(0xFFB9A4D5),
                )),
    );
  }

  Widget _buildSettingsTab() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 5, 22, 225),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeader(),
          const SizedBox(height: 24),
          const Text(
            "Settings",
            style: TextStyle(
              fontSize: 27,
              fontWeight: FontWeight.w500,
              letterSpacing: -0.6,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            "Customize your Nexus experience.",
            style: TextStyle(color: _muted, fontSize: 12),
          ),
          const SizedBox(height: 22),
          Expanded(
            child: ListView(
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.only(bottom: 18),
              children: [
                _settingsLabel("BIBLIOTECA"),
                _settingsTile(
                  icon: Icons.refresh_rounded,
                  title: "Atualizar biblioteca",
                  subtitle:
                      "${_libraryTracks.length} ${_libraryTracks.length == 1 ? "m\u00fasica encontrada" : "m\u00fasicas encontradas"}",
                  onTap: _libraryLoading ? null : _loadLibrary,
                  trailing: _libraryLoading
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            color: _violet,
                            strokeWidth: 2,
                          ),
                        )
                      : null,
                ),
                const SizedBox(height: 10),
                _settingsTile(
                  icon: Icons.queue_music_rounded,
                  title: "Playlists",
                  subtitle:
                      "${_playlists.length} ${_playlists.length == 1 ? "salva" : "salvas"} neste aparelho",
                  onTap: () => _selectTab(2),
                ),
                const SizedBox(height: 24),
                _settingsLabel("SOBRE"),
                _settingsTile(
                  icon: Icons.code_rounded,
                  title: "Criado por Nixz",
                  subtitle: "github.com/Nixz-L",
                  onTap: _openGithub,
                  trailing: const Icon(
                    Icons.open_in_new_rounded,
                    color: Color(0xFFB9A4D5),
                    size: 20,
                  ),
                ),
                const SizedBox(height: 10),
                FutureBuilder<String>(
                  future: _versionFuture,
                  builder: (context, snapshot) {
                    return _settingsTile(
                      icon: Icons.info_outline_rounded,
                      title: "Nexus Player",
                      subtitle: snapshot.hasData
                          ? "N\u00facleo v${snapshot.data}"
                          : "Player de m\u00fasicas locais",
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
  Widget _buildLibraryTab() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 5, 22, 225),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeader(),
          const SizedBox(height: 24),
          Row(
            children: [
              const Expanded(
                child: Text(
                  "Your Library",
                  style: TextStyle(
                    fontSize: 27,
                    fontWeight: FontWeight.w500,
                    letterSpacing: -0.6,
                  ),
                ),
              ),
              IconButton(
                onPressed: _libraryLoading ? null : _loadLibrary,
                icon: Icon(
                  Icons.refresh_rounded,
                  color: _libraryLoading ? _muted : Colors.white70,
                ),
                tooltip: "Atualizar biblioteca",
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            "${_libraryTracks.length} ${_libraryTracks.length == 1 ? "track" : "tracks"}",
            style: const TextStyle(color: _muted, fontSize: 12),
          ),
          const SizedBox(height: 18),
          Expanded(
            child: _libraryLoading
                ? const Center(
                    child: CircularProgressIndicator(
                      color: _violet,
                      strokeWidth: 2,
                    ),
                  )
                : _libraryError != null
                ? _buildLibraryMessage(
                    Icons.lock_outline_rounded,
                    _libraryError!,
                    "Toque para tentar novamente",
                    _loadLibrary,
                  )
                : _libraryTracks.isEmpty
                ? _buildLibraryMessage(
                    Icons.music_off_rounded,
                    "Sua biblioteca está vazia",
                    "Adicione arquivos de áudio ao dispositivo.",
                    _loadLibrary,
                  )
                : ListView.separated(
                    physics: const BouncingScrollPhysics(),
                    padding: const EdgeInsets.only(bottom: 18),
                    itemCount: _libraryTracks.length,
                    separatorBuilder: (_, _) => Divider(
                      height: 1,
                      color: Colors.white.withValues(alpha: 0.055),
                    ),
                    itemBuilder: (context, index) {
                      final track = _libraryTracks[index];
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: _trackThumb(track, const Color(0xFF171020), 11),
                        title: Text(
                          track.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        subtitle: Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            [
                              track.artist ?? "Unknown artist",
                              if (track.album != null) track.album!,
                            ].join(" · "),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: _muted, fontSize: 11),
                          ),
                        ),
                        onLongPress: () => _showAddToPlaylistSheet(track),
                        trailing: Text(
                          _formatTrackDuration(track.durationMs),
                          style: const TextStyle(
                            color: _muted,
                            fontSize: 11,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                        onTap: () => _selectTrack(track),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildLibraryMessage(
    IconData icon,
    String title,
    String subtitle,
    VoidCallback onRetry,
  ) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 42, color: _violet),
          const SizedBox(height: 16),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 17),
          ),
          const SizedBox(height: 7),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: const TextStyle(color: _muted, fontSize: 12),
          ),
          const SizedBox(height: 18),
          TextButton(
            onPressed: onRetry,
            child: const Text(
              "Tentar novamente",
              style: TextStyle(color: _violet),
            ),
          ),
        ],
      ),
    );
  }

  String _formatTrackDuration(BigInt? durationMs) {
    final totalSeconds = (durationMs?.toInt() ?? 0) ~/ 1000;
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return "$minutes:${seconds.toString().padLeft(2, "0")}";
  }

  Widget _buildBottomDock() {
    return Positioned(
      left: 16,
      right: 16,
      bottom: 0,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildMiniPlayer(),
            const SizedBox(height: 13),
            Container(
              height: 76,
              decoration: BoxDecoration(
                color: const Color(0xFF0D0A16),
                borderRadius: BorderRadius.circular(38),
                border: Border.all(color: const Color(0xFF38234D), width: 0.8),
                boxShadow: [
                  BoxShadow(
                    color: _violet.withValues(alpha: 0.08),
                    blurRadius: 24,
                  ),
                ],
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _NavItem(
                    icon: Icons.home_rounded,
                    label: "Home",
                    selected: _tab == 0,
                    onTap: () => _selectTab(0),
                  ),
                  _NavItem(
                    icon: Icons.library_music_rounded,
                    label: "Library",
                    selected: _tab == 1,
                    onTap: () => _selectTab(1),
                  ),
                  _NavItem(
                    icon: Icons.queue_music_rounded,
                    label: "Playlists",
                    selected: _tab == 2,
                    onTap: () => _selectTab(2),
                  ),
                  _NavItem(
                    icon: Icons.settings_rounded,
                    label: "Settings",
                    selected: _tab == 3,
                    onTap: () => _selectTab(3),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _buildMiniPlayer() {
    final player = NexusPlayerService.instance;

    return ValueListenableBuilder<PlaybackState?>(
      valueListenable: player.state,
      builder: (context, state, _) {
        final track = state?.currentTrack;
        final playing = state?.status == "playing";
        final failed = state?.status == "error";
        final artist = track?.artist;
        final subtitle = track == null
            ? "Choose a track"
            : failed
            ? "Playback error"
            : (artist != null && artist.isNotEmpty
                  ? artist
                  : "Unknown artist");

        return Container(
          height: 105,
          clipBehavior: Clip.antiAlias,
          padding: const EdgeInsets.symmetric(horizontal: 15),
          decoration: BoxDecoration(
            color: const Color(0xFF0E0A19),
            borderRadius: BorderRadius.circular(25),
            border: Border.all(color: const Color(0xFF61318C)),
            boxShadow: [
              BoxShadow(color: _violet.withValues(alpha: 0.12), blurRadius: 25),
            ],
          ),
          child: GestureDetector(
            onTap: track == null ? null : _openNowPlaying,
            child: Stack(
              children: [
                Row(
                  children: [
                    SizedBox(
                      width: 66,
                      height: 66,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(13),
                        child: track == null
                            ? CustomPaint(painter: _ArtworkPainter(0))
                            : TrackCover(
                                trackId: track.id,
                                size: 200,
                                fallback: CustomPaint(
                                  painter: _ArtworkPainter(0),
                                ),
                              ),
                      ),
                    ),
                    const SizedBox(width: 13),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            track?.title ?? "Not Playing",
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: _muted, fontSize: 11),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: track == null
                          ? null
                          : () => _runPlayerAction(player.previous),
                      icon: const Icon(
                        Icons.skip_previous_rounded,
                        color: Color(0xFFB9A4D5),
                        size: 25,
                      ),
                    ),
                    Container(
                      width: 49,
                      height: 49,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: const LinearGradient(
                          colors: [Color(0xFFB04DFF), Color(0xFF5D16C4)],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: _violet.withValues(alpha: 0.35),
                            blurRadius: 18,
                          ),
                        ],
                      ),
                      child: IconButton(
                        onPressed: _libraryTracks.isEmpty
                            ? null
                            : () => _runPlayerAction(player.togglePlayPause),
                        icon: Icon(
                          playing
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                          color: Colors.white,
                          size: 29,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: track == null
                          ? null
                          : () => _runPlayerAction(player.next),
                      icon: const Icon(
                        Icons.skip_next_rounded,
                        color: Color(0xFFB9A4D5),
                        size: 25,
                      ),
                    ),
                  ],
                ),
                if (playing)
                  const Positioned(
                    left: 105,
                    right: 105,
                    bottom: 2,
                    height: 12,
                    child: _AnimatedVisualizer(),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

Future<void> _reportPlaybackError(BuildContext context) async {
  final player = NexusPlayerService.instance;
  if (player.state.value?.status != "error") return;
  final message = await player.lastError();
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      backgroundColor: const Color(0xFF1A1226),
      content: Text(
        message ?? "N\u00e3o foi poss\u00edvel reproduzir esta m\u00fasica.",
      ),
    ),
  );
}

class NowPlayingScreen extends StatefulWidget {
  const NowPlayingScreen({super.key});

  @override
  State<NowPlayingScreen> createState() => _NowPlayingScreenState();
}

class _NowPlayingScreenState extends State<NowPlayingScreen> {
  double? _dragMs;

  String _formatDuration(int milliseconds) {
    final duration = Duration(milliseconds: milliseconds);
    return "${duration.inMinutes}:${duration.inSeconds.remainder(60).toString().padLeft(2, '0')}";
  }

  Future<void> _run(Future<void> Function() action) async {
    await action();
    if (!mounted) return;
    await _reportPlaybackError(context);
  }

  @override
  Widget build(BuildContext context) {
    final player = NexusPlayerService.instance;

    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 28),
          child: ValueListenableBuilder<PlaybackState?>(
            valueListenable: player.state,
            builder: (context, state, _) {
              final track = state?.currentTrack;
              final status = state?.status ?? "idle";
              final playing = status == "playing";
              final active = playing || status == "paused";
              final shuffle = state?.shuffle ?? false;
              final repeat = state?.repeatMode ?? "off";
              final artist = track?.artist;

              final positionMs = active ? (state?.positionMs.toInt() ?? 0) : 0;
              final durationMs =
                  (state?.durationMs ?? track?.durationMs)?.toInt() ?? 0;
              final canSeek = active && durationMs > 0;
              final sliderMax = durationMs > 0 ? durationMs.toDouble() : 1.0;
              final sliderValue = (_dragMs ?? positionMs.toDouble())
                  .clamp(0.0, sliderMax)
                  .toDouble();

              final coverFallback = Stack(
                fit: StackFit.expand,
                children: [
                  CustomPaint(painter: _HeroWavePainter()),
                  Center(
                    child: Icon(
                      Icons.graphic_eq_rounded,
                      size: 88,
                      color: _violet.withValues(alpha: .9),
                    ),
                  ),
                ],
              );

              return Column(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      IconButton(
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(
                          Icons.keyboard_arrow_down_rounded,
                          color: Colors.white,
                          size: 32,
                        ),
                      ),
                      const Expanded(
                        child: Text(
                          "NOW PLAYING",
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: _muted,
                            fontSize: 11,
                            letterSpacing: 3,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: 48),
                    ],
                  ),
                  Expanded(
                    child: Center(
                      child: AspectRatio(
                        aspectRatio: 1,
                        child: Container(
                          constraints: const BoxConstraints(maxWidth: 340),
                          clipBehavior: Clip.antiAlias,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(28),
                            gradient: const LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [
                                Color(0xFF32164D),
                                Color(0xFF160D26),
                                Color(0xFF08070D),
                              ],
                            ),
                            border: Border.all(
                              color: _violet.withValues(alpha: .22),
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: _violet.withValues(alpha: .13),
                                blurRadius: 50,
                              ),
                            ],
                          ),
                          child: track == null
                              ? coverFallback
                              : TrackCover(
                                  trackId: track.id,
                                  size: 700,
                                  fallback: coverFallback,
                                ),
                        ),
                      ),
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        track?.title ?? "Nothing playing",
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 25,
                          height: 1.2,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        artist != null && artist.isNotEmpty
                            ? artist
                            : "Unknown artist",
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: _muted, fontSize: 15),
                      ),
                      const SizedBox(height: 24),
                      SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 3,
                          thumbShape: const RoundSliderThumbShape(
                            enabledThumbRadius: 5,
                          ),
                          overlayShape: SliderComponentShape.noOverlay,
                          activeTrackColor: _violet,
                          inactiveTrackColor: Colors.white12,
                          thumbColor: _violet,
                          disabledActiveTrackColor: _violet,
                          disabledInactiveTrackColor: Colors.white12,
                          disabledThumbColor: _violet,
                        ),
                        child: Slider(
                          value: sliderValue,
                          min: 0,
                          max: sliderMax,
                          onChanged: canSeek
                              ? (value) => setState(() => _dragMs = value)
                              : null,
                          onChangeEnd: canSeek
                              ? (value) async {
                                  await player.seekTo(
                                    Duration(milliseconds: value.round()),
                                  );
                                  if (mounted) setState(() => _dragMs = null);
                                }
                              : null,
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              _formatDuration(sliderValue.round()),
                              style: const TextStyle(
                                color: _muted,
                                fontSize: 12,
                              ),
                            ),
                            Text(
                              durationMs > 0
                                  ? _formatDuration(durationMs)
                                  : "--:--",
                              style: const TextStyle(
                                color: _muted,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 20),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          IconButton(
                            onPressed: () => _run(player.toggleShuffle),
                            icon: Icon(
                              Icons.shuffle_rounded,
                              color: shuffle ? _violet : _muted,
                              size: 23,
                            ),
                          ),
                          IconButton(
                            onPressed: track == null
                                ? null
                                : () => _run(player.previous),
                            icon: const Icon(
                              Icons.skip_previous_rounded,
                              color: Color(0xFFB9A4D5),
                              size: 34,
                            ),
                          ),
                          Container(
                            width: 66,
                            height: 66,
                            decoration: BoxDecoration(
                              color: _violet.withValues(alpha: .18),
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: _violet.withValues(alpha: .35),
                              ),
                            ),
                            child: IconButton(
                              onPressed: () => _run(player.togglePlayPause),
                              icon: Icon(
                                playing
                                    ? Icons.pause_rounded
                                    : Icons.play_arrow_rounded,
                                color: _violet,
                                size: 38,
                              ),
                            ),
                          ),
                          IconButton(
                            onPressed: track == null
                                ? null
                                : () => _run(player.next),
                            icon: const Icon(
                              Icons.skip_next_rounded,
                              color: Color(0xFFB9A4D5),
                              size: 34,
                            ),
                          ),
                          IconButton(
                            onPressed: () => _run(player.cycleRepeat),
                            icon: Icon(
                              repeat == "track"
                                  ? Icons.repeat_one_rounded
                                  : Icons.repeat_rounded,
                              color: repeat == "off" ? _muted : _violet,
                              size: 23,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _AnimatedVisualizer extends StatefulWidget {
  const _AnimatedVisualizer();

  @override
  State<_AnimatedVisualizer> createState() => _AnimatedVisualizerState();
}

class _AnimatedVisualizerState extends State<_AnimatedVisualizer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animation;

  @override
  void initState() {
    super.initState();
    _animation = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat();
  }

  @override
  @override
  void dispose() {
    _animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        return CustomPaint(painter: _VisualizerPainter(_animation.value));
      },
    );
  }
}

class _VisualizerPainter extends CustomPainter {
  final double phase;

  _VisualizerPainter(this.phase);

  @override
  void paint(Canvas canvas, Size size) {
    const count = 37;
    const gap = 3.0;
    final barWidth = (size.width - (count - 1) * gap) / count;

    for (int i = 0; i < count; i++) {
      final wave = math.sin(i * .52 + phase * math.pi * 2);
      final secondary = math.sin(i * .23 - phase * math.pi * 3);
      final height = 2.0 + (wave + 1) * 3.0 + (secondary + 1) * 1.4;

      final paint = Paint()
        ..shader = const LinearGradient(
          colors: [Color(0xFFE8D5FF), Color(0xFF9E42FF)],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ).createShader(Rect.fromLTWH(0, 0, barWidth, size.height));

      final x = i * (barWidth + gap);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, size.height - height, barWidth, height),
          const Radius.circular(2),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _VisualizerPainter oldDelegate) =>
      oldDelegate.phase != phase;
}

class _PillButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool filled;

  const _PillButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.filled = false,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final foreground = enabled ? Colors.white : _muted;

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 18),
        decoration: BoxDecoration(
          gradient: filled && enabled
              ? const LinearGradient(
                  colors: [Color(0xFFB04DFF), Color(0xFF5D16C4)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                )
              : null,
          color: filled && enabled ? null : const Color(0xFF191020),
          borderRadius: BorderRadius.circular(24),
          border: filled && enabled
              ? null
              : Border.all(color: const Color(0xFF48305F)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 19, color: foreground),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: foreground,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlaylistCard extends StatelessWidget {
  final NexusPlaylist playlist;
  final VoidCallback onTap;

  const _PlaylistCard({required this.playlist, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 150,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(13),
              child: SizedBox(
                width: 150,
                height: 150,
                child: _PlaylistArt(playlist: playlist),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              playlist.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 4),
            Text(
              "${playlist.trackIds.length} faixas",
              style: const TextStyle(color: _muted, fontSize: 10),
            ),
          ],
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _NavItem({
    required this.icon,
    required this.label,
    required this.onTap,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = selected ? _violet : const Color(0xFF777184);

    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(25),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: color, size: 23),
            const SizedBox(height: 5),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 10,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ArtworkPainter extends CustomPainter {
  final int type;

  _ArtworkPainter(this.type);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final colors = _playlistPalettes[type % _playlistPalettes.length];

    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: colors,
        ).createShader(rect),
    );

    final glow = Paint()
      ..shader =
          RadialGradient(
            colors: [
              const Color(0xFFB66AFF).withValues(alpha: 0.55),
              Colors.transparent,
            ],
          ).createShader(
            Rect.fromCircle(
              center: Offset(size.width * .5, size.height * .45),
              radius: size.width * .65,
            ),
          );

    canvas.drawRect(rect, glow);

    final white = Paint()
      ..color = const Color(0xFFD9B9FF).withValues(alpha: .8);

    if (type == 0) {
      canvas.drawCircle(
        Offset(size.width * .67, size.height * .31),
        size.width * .105,
        white,
      );
      canvas.drawCircle(
        Offset(size.width * .72, size.height * .27),
        size.width * .105,
        Paint()..color = colors.first,
      );

      final mountain = Path()
        ..moveTo(0, size.height * .78)
        ..lineTo(size.width * .35, size.height * .48)
        ..lineTo(size.width * .52, size.height * .68)
        ..lineTo(size.width * .76, size.height * .44)
        ..lineTo(size.width, size.height * .77)
        ..lineTo(size.width, size.height)
        ..lineTo(0, size.height)
        ..close();

      canvas.drawPath(mountain, Paint()..color = const Color(0xFF0A0B20));
    } else if (type == 1) {
      final center = Offset(size.width * .5, size.height * .42);
      final petal = Paint()..color = const Color(0xFF171020);

      for (int i = 0; i < 7; i++) {
        canvas.save();
        canvas.translate(center.dx, center.dy);
        canvas.rotate(i * 0.9);
        canvas.drawOval(
          Rect.fromCenter(
            center: Offset(0, -size.height * .1),
            width: size.width * .19,
            height: size.height * .31,
          ),
          petal,
        );
        canvas.restore();
      }

      canvas.drawCircle(center, size.width * .09, petal);
      canvas.drawLine(
        Offset(center.dx, center.dy),
        Offset(center.dx - 5, size.height),
        Paint()
          ..color = const Color(0xFF191326)
          ..strokeWidth = 3,
      );
    } else if (type == 2) {
      final cityPaint = Paint()..color = const Color(0xFF100D2B);
      final heights = [.42, .58, .35, .73, .5, .65, .4];

      for (int i = 0; i < heights.length; i++) {
        final x = i * size.width / heights.length;
        final h = size.height * heights[i];
        canvas.drawRect(
          Rect.fromLTWH(x, size.height - h, size.width / heights.length + 2, h),
          cityPaint,
        );

        for (int j = 0; j < 3; j++) {
          canvas.drawRect(
            Rect.fromLTWH(x + 4, size.height - h + 8 + j * 12, 3, 3),
            Paint()..color = const Color(0xFFB16CFF),
          );
        }
      }
    } else {
      for (int i = 0; i < 5; i++) {
        canvas.drawCircle(
          Offset(size.width * (i * .22), size.height * (.25 + (i % 2) * .12)),
          size.width * .22,
          Paint()..color = Colors.white.withValues(alpha: .035),
        );
      }
      canvas.drawRect(
        Rect.fromLTWH(0, size.height * .76, size.width, size.height * .24),
        Paint()..color = const Color(0xFF101024),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ArtworkPainter oldDelegate) =>
      oldDelegate.type != type;
}

class _WaveBackgroundPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    _drawRibbon(
      canvas,
      size,
      size.height * .19,
      size.height * .075,
      const Color(0xFF7D27FF),
    );

    _drawRibbon(
      canvas,
      size,
      size.height * .76,
      size.height * .045,
      const Color(0xFF6822C9),
    );
  }

  void _drawRibbon(
    Canvas canvas,
    Size size,
    double centerY,
    double amplitude,
    Color color,
  ) {
    final upper = Path()
      ..moveTo(-20, centerY - amplitude * .35)
      ..cubicTo(
        size.width * .25,
        centerY - amplitude * 1.7,
        size.width * .34,
        centerY + amplitude * 1.5,
        size.width * .58,
        centerY + amplitude * .55,
      )
      ..cubicTo(
        size.width * .78,
        centerY - amplitude * .25,
        size.width * .87,
        centerY - amplitude * 1.5,
        size.width + 20,
        centerY - amplitude * .65,
      );

    final band = Path()
      ..addPath(upper, Offset.zero)
      ..lineTo(size.width + 20, centerY + amplitude * .25)
      ..cubicTo(
        size.width * .9,
        centerY - amplitude * .8,
        size.width * .79,
        centerY + amplitude * .55,
        size.width * .59,
        centerY + amplitude * 1.35,
      )
      ..cubicTo(
        size.width * .37,
        centerY + amplitude * 2.1,
        size.width * .25,
        centerY - amplitude * .55,
        -20,
        centerY + amplitude * .5,
      )
      ..close();

    canvas.drawPath(
      band,
      Paint()
        ..shader =
            LinearGradient(
              colors: [
                color.withValues(alpha: .02),
                color.withValues(alpha: .19),
                const Color(0xFFB45AFF).withValues(alpha: .09),
                color.withValues(alpha: .025),
              ],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ).createShader(
              Rect.fromLTWH(
                0,
                centerY - amplitude * 2,
                size.width,
                amplitude * 4,
              ),
            ),
    );

    canvas.drawPath(
      upper,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = color.withValues(alpha: .35)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
    );

    canvas.drawPath(
      upper,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = const Color(0xFFD09AFF).withValues(alpha: .5),
    );
  }

  @override
  bool shouldRepaint(covariant _WaveBackgroundPainter oldDelegate) => false;
}

class _HeroWavePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(-15, size.height * .13)
      ..cubicTo(
        size.width * .25,
        size.height * .18,
        size.width * .33,
        size.height * .72,
        size.width * .57,
        size.height * .62,
      )
      ..cubicTo(
        size.width * .76,
        size.height * .55,
        size.width * .86,
        size.height * .2,
        size.width + 15,
        size.height * .12,
      );

    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..color = _violet.withValues(alpha: .23)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12),
    );

    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.1
        ..color = const Color(0xFFB65CFF).withValues(alpha: .58),
    );
  }

  @override
  bool shouldRepaint(covariant _HeroWavePainter oldDelegate) => false;
}


class _PlaylistArt extends StatelessWidget {
  final NexusPlaylist playlist;

  const _PlaylistArt({required this.playlist});

  @override
  Widget build(BuildContext context) {
    final painted = CustomPaint(painter: _ArtworkPainter(playlist.artwork));
    final path = playlist.coverPath;
    if (path == null || path.isEmpty) return painted;

    return Image.file(
      File(path),
      fit: BoxFit.cover,
      cacheWidth: 500,
      gaplessPlayback: true,
      errorBuilder: (_, _, _) => painted,
    );
  }
}