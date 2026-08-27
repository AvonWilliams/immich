import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Per-asset upload progress: [progress] is 0.0..1.0 (or -1.0 for error) and
/// [totalBytes] is the total file size (used to detect chunked uploads).
typedef AssetUploadProgress = ({double progress, int totalBytes});

/// Tracks per-asset upload progress.
/// Key: local asset ID
class AssetUploadProgressNotifier extends Notifier<Map<String, AssetUploadProgress>> {
  static const double errorValue = -1.0;

  @override
  Map<String, AssetUploadProgress> build() => {};

  void setProgress(String localAssetId, double progress, {int totalBytes = 0}) {
    state = {...state, localAssetId: (progress: progress, totalBytes: totalBytes)};
  }

  void setError(String localAssetId) {
    state = {...state, localAssetId: (progress: errorValue, totalBytes: 0)};
  }

  void remove(String localAssetId) {
    state = Map.from(state)..remove(localAssetId);
  }

  void clear() {
    state = {};
  }
}

final assetUploadProgressProvider = NotifierProvider<AssetUploadProgressNotifier, Map<String, AssetUploadProgress>>(
  AssetUploadProgressNotifier.new,
);

final manualUploadCancelTokenProvider = StateProvider<Completer<void>?>((ref) => null);
