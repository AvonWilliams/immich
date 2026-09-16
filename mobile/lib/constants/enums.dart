import 'package:immich_mobile/generated/translations.g.dart';

enum SortOrder {
  asc,
  desc;

  SortOrder reverse() {
    return this == SortOrder.asc ? SortOrder.desc : SortOrder.asc;
  }
}

enum TextSearchType { context, filename, description, ocr }

enum ActionSource { timeline, viewer }

enum ShareAssetType { original, preview }

enum CleanupStep { selectDate, scan, delete }

enum AssetKeepType { none, photosOnly, videosOnly }

enum AssetDateAggregation { start, end }

enum SlideshowLook { contain, cover, blurredBackground }

enum SlideshowDirection { forward, backward, shuffle }

enum PartnerDirection { sharedBy, sharedWith }

enum DevicePermission { photos, videos, storage, mediaLocation }

enum DevicePermissionStatus {
  denied,
  granted,
  limited,
  permanentlyDenied;

  bool get hasAccess => this == granted || this == limited;
}
enum ChunkedUploadPhase {
  calculatingChunks,
  calculatingHashes,
  sendingHashes,
  sendingChunks,
  checking,
  chunkRejected,
  finalizing;

  String localized() {
    final t = StaticTranslations.instance.upload_status;
    return switch (this) {
      ChunkedUploadPhase.calculatingChunks => t.calculating_chunks,
      ChunkedUploadPhase.calculatingHashes => t.calculating_hashes,
      ChunkedUploadPhase.sendingHashes => t.sending_hashes,
      ChunkedUploadPhase.sendingChunks => t.sending_chunks,
      ChunkedUploadPhase.checking => t.checking,
      ChunkedUploadPhase.chunkRejected => t.chunk_rejected,
      ChunkedUploadPhase.finalizing => t.finalizing,
    };
  }
}
