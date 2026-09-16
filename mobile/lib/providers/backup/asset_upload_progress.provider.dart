import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/enums.dart';

/// Per-asset upload progress: [progress] is 0.0..1.0 (or -1.0 for error),
/// [totalBytes] is the total file size (used to detect chunked uploads),
/// [speed] is a human-readable transfer rate, and [phase] is the current
/// chunked-upload phase (null for non-chunked uploads).
typedef AssetUploadProgress = ({double progress, int totalBytes, String speed, ChunkedUploadPhase? phase, int retryCount});

/// Tracks per-asset upload progress.
/// Key: local asset ID
class AssetUploadProgressNotifier extends Notifier<Map<String, AssetUploadProgress>> {
  static const double errorValue = -1.0;

  @override
  Map<String, AssetUploadProgress> build() => {};

  void setProgress(String localAssetId, double progress, {int totalBytes = 0, String speed = '-- MB/s'}) {
    final current = state[localAssetId];
    state = {
      ...state,
      localAssetId: (
        progress: progress,
        totalBytes: totalBytes,
        speed: speed,
        phase: current?.phase,
        retryCount: current?.retryCount ?? 0,
      ),
    };
  }

  void setPhase(String localAssetId, ChunkedUploadPhase phase, [int retryCount = 0]) {
    final current = state[localAssetId];
    if (current == null) {
      return;
    }
    state = {
      ...state,
      localAssetId: (
        progress: current.progress,
        totalBytes: current.totalBytes,
        speed: current.speed,
        phase: phase,
        retryCount: retryCount,
      ),
    };
  }

  void setError(String localAssetId) {
    state = {
      ...state,
      localAssetId: (progress: errorValue, totalBytes: 0, speed: '-- MB/s', phase: null, retryCount: 0),
    };
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
