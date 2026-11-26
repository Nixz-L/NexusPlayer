import "dart:typed_data";

import "package:material_ui/material_ui.dart";

import "../services/media_library_service.dart";

/// Mostra a capa da faixa; enquanto carrega ou sem capa, mostra [fallback].
class TrackCover extends StatelessWidget {
  const TrackCover({
    super.key,
    required this.trackId,
    required this.fallback,
    this.size = 400,
    this.borderRadius = BorderRadius.zero,
  });

  final String trackId;
  final Widget fallback;
  final int size;
  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      key: ValueKey<String>("cover-$trackId-$size"),
      future: MediaLibraryService.loadCover(trackId, size: size),
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        if (bytes == null || bytes.isEmpty) {
          return fallback;
        }
        return ClipRRect(
          borderRadius: borderRadius,
          child: Image.memory(
            bytes,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            filterQuality: FilterQuality.medium,
          ),
        );
      },
    );
  }
}