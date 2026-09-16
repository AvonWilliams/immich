import 'dart:math' as math;

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/duration_extensions.dart';
import 'package:immich_mobile/extensions/theme_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/images/thumbnail.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/constants.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/providers/backup/asset_upload_progress.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/timeline/multiselect.provider.dart';

class ThumbnailTile extends ConsumerStatefulWidget {
  const ThumbnailTile(
    this.asset, {
    this.size = kThumbnailResolution,
    this.remoteSize,
    this.fit = BoxFit.cover,
    this.showStorageIndicator = false,
    this.lockSelection = false,
    this.heroOffset,
    this.showStackIndicator = false,
    super.key,
  });

  final BaseAsset? asset;
  final Size size;

  /// Physical size to decode for remote thumbnails.
  final Size? remoteSize;
  final BoxFit fit;
  final bool showStorageIndicator;
  final bool lockSelection;
  final int? heroOffset;
  final bool showStackIndicator;

  @override
  ConsumerState<ThumbnailTile> createState() => _ThumbnailTileState();
}

class _ThumbnailTileState extends ConsumerState<ThumbnailTile> {
  bool _hideIndicators = false;
  bool _showSelectionContainer = false;

  @override
  void dispose() {
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final asset = widget.asset;
    final heroIndex = widget.heroOffset ?? TabsRouterScope.of(context)?.controller.activeIndex ?? 0;
    final isCurrentAsset = ref.watch(assetViewerProvider.select((current) => current.currentAsset == asset));

    final assetContainerColor = context.isDarkTheme
        ? context.primaryColor.darken(amount: 0.4)
        : context.primaryColor.lighten(amount: 0.75);

    final isSelected = ref.watch(
      multiSelectProvider.select((multiselect) => multiselect.selectedAssets.contains(asset)),
    );

    final bool storageIndicator =
        ref.watch(appConfigProvider.select((s) => s.timeline.storageIndicator)) && widget.showStorageIndicator;

    if (!isCurrentAsset) {
      _hideIndicators = false;
    }

    if (isSelected) {
      _showSelectionContainer = true;
    }

    final uploadProgress = asset is LocalAsset
        ? ref.watch(assetUploadProgressProvider.select((map) => map[asset.id]))
        : null;

    return Stack(
      children: [
        Container(
          color: widget.lockSelection
              ? context.colorScheme.surfaceContainerHighest
              : _showSelectionContainer
              ? assetContainerColor
              : Colors.transparent,
        ),
        AnimatedContainer(
          duration: Durations.short4,
          curve: Curves.decelerate,
          onEnd: () {
            if (!isSelected) {
              _showSelectionContainer = false;
            }
          },
          padding: EdgeInsets.all(isSelected || widget.lockSelection ? 6 : 0),
          child: TweenAnimationBuilder<double>(
            tween: Tween<double>(begin: 0.0, end: (isSelected || widget.lockSelection) ? 15.0 : 0.0),
            duration: Durations.short4,
            curve: Curves.decelerate,
            builder: (context, value, child) {
              return ClipRRect(borderRadius: BorderRadius.all(Radius.circular(value)), child: child);
            },
            child: Stack(
              children: [
                Positioned.fill(
                  child: Hero(
                    // This key resets the hero animation when the asset is changed in the asset viewer.
                    // It doesn't seem like the best solution, and only works to reset the hero, not prime the hero of the new active asset for animation,
                    // but other solutions have failed thus far.
                    key: ValueKey(isCurrentAsset),
                    tag: '${asset?.heroTag}_$heroIndex',
                    child: Thumbnail.fromAsset(asset: asset, size: widget.size, remoteSize: widget.remoteSize),
                    // Placeholderbuilder used to hide indicators on first hero animation, since flightShuttleBuilder isn't called until both source and destination hero exist in widget tree.
                    placeholderBuilder: (context, heroSize, child) {
                      if (!_hideIndicators) {
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          setState(() => _hideIndicators = true);
                        });
                      }
                      return const SizedBox();
                    },
                    flightShuttleBuilder: (context, animation, direction, from, to) {
                      void animationStatusListener(AnimationStatus status) {
                        if (!mounted) {
                          return;
                        }
                        final heroInFlight = status == AnimationStatus.forward || status == AnimationStatus.reverse;
                        if (_hideIndicators != heroInFlight) {
                          setState(() => _hideIndicators = heroInFlight);
                        }
                        if (status == AnimationStatus.completed || status == AnimationStatus.dismissed) {
                          animation.removeStatusListener(animationStatusListener);
                        }
                      }

                      animation.addStatusListener(animationStatusListener);
                      return direction == HeroFlightDirection.push ? from.widget : to.widget;
                    },
                  ),
                ),
                if (asset != null)
                  AnimatedOpacity(
                    opacity: _hideIndicators ? 0.0 : 1.0,
                    duration: Durations.short4,
                    child: Align(
                      alignment: Alignment.topRight,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          _AssetTypeIcons(asset: asset),
                          if (widget.showStackIndicator) _StackIndicator(asset: asset),
                        ],
                      ),
                    ),
                  ),
                if (storageIndicator && asset != null)
                  AnimatedOpacity(
                    opacity: _hideIndicators ? 0.0 : 1.0,
                    duration: Durations.short4,
                    child: switch (asset.storage) {
                      AssetState.local => const Align(
                        alignment: Alignment.bottomRight,
                        child: Padding(
                          padding: EdgeInsets.only(right: 10.0, bottom: 6.0),
                          child: _TileOverlayIcon(Icons.cloud_off_outlined),
                        ),
                      ),
                      AssetState.remote => const Align(
                        alignment: Alignment.bottomRight,
                        child: Padding(
                          padding: EdgeInsets.only(right: 10.0, bottom: 6.0),
                          child: _TileOverlayIcon(Icons.cloud_outlined),
                        ),
                      ),
                      AssetState.merged => const Align(
                        alignment: Alignment.bottomRight,
                        child: Padding(
                          padding: EdgeInsets.only(right: 10.0, bottom: 6.0),
                          child: _TileOverlayIcon(Icons.cloud_done_outlined),
                        ),
                      ),
                    },
                  ),

                if (asset != null && asset.isFavorite)
                  AnimatedOpacity(
                    duration: Durations.short4,
                    opacity: _hideIndicators ? 0.0 : 1.0,
                    child: const Align(
                      alignment: Alignment.bottomLeft,
                      child: Padding(
                        padding: EdgeInsets.only(left: 10.0, bottom: 6.0),
                        child: _TileOverlayIcon(Icons.favorite_rounded),
                      ),
                    ),
                  ),
                if (uploadProgress != null)
                  _UploadProgressOverlay(
                    progress: uploadProgress.progress,
                    totalBytes: uploadProgress.totalBytes,
                    speed: uploadProgress.speed,
                    phase: uploadProgress.phase,
                    retryCount: uploadProgress.retryCount,
                  ),
              ],
            ),
          ),
        ),
        TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 0.0, end: (isSelected || widget.lockSelection) ? 1.0 : 0.0),
          duration: Durations.short4,
          curve: Curves.decelerate,
          builder: (context, value, child) {
            return Padding(
              padding: EdgeInsets.all((isSelected || widget.lockSelection) ? value * 3.0 : 3.0),
              child: Align(
                alignment: Alignment.topLeft,
                child: Opacity(
                  opacity: (isSelected || widget.lockSelection) ? 1 : value,
                  child: _SelectionIndicator(
                    isLocked: widget.lockSelection,
                    color: widget.lockSelection ? context.colorScheme.surfaceContainerHighest : assetContainerColor,
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

class _SelectionIndicator extends StatelessWidget {
  final bool isLocked;
  final Color? color;

  const _SelectionIndicator({required this.isLocked, this.color});

  @override
  Widget build(BuildContext context) {
    if (isLocked) {
      return DecoratedBox(
        decoration: BoxDecoration(shape: BoxShape.circle, color: color),
        child: const Icon(Icons.check_circle_rounded, color: Colors.grey),
      );
    } else {
      return DecoratedBox(
        decoration: BoxDecoration(shape: BoxShape.circle, color: color),
        child: Icon(Icons.check_circle_rounded, color: context.primaryColor),
      );
    }
  }
}

class _VideoIndicator extends StatelessWidget {
  final Duration duration;
  const _VideoIndicator(this.duration);

  @override
  Widget build(BuildContext context) {
    return Row(
      spacing: 3,
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.end,
      // CrossAxisAlignment.start looks more centered vertically than CrossAxisAlignment.center
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          duration.format(),
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.bold,
            shadows: [Shadow(blurRadius: 5.0, color: Color.fromRGBO(0, 0, 0, 0.6))],
          ),
        ),
        const _TileOverlayIcon(Icons.play_circle_outline_rounded),
      ],
    );
  }
}

class _TileOverlayIcon extends StatelessWidget {
  final IconData icon;

  const _TileOverlayIcon(this.icon);

  @override
  Widget build(BuildContext context) {
    return Icon(
      icon,
      color: Colors.white,
      size: 16,
      shadows: const [Shadow(blurRadius: 5.0, color: Color.fromRGBO(0, 0, 0, 0.6), offset: Offset.zero)],
    );
  }
}

class _AssetTypeIcons extends StatelessWidget {
  final BaseAsset asset;

  const _AssetTypeIcons({required this.asset});

  @override
  Widget build(BuildContext context) {
    final isLivePhoto = asset.isMotionPhoto;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (asset.isVideo)
          Padding(padding: const EdgeInsets.only(right: 10.0, top: 6.0), child: _VideoIndicator(asset.duration)),
        if (isLivePhoto)
          const Padding(
            padding: EdgeInsets.only(right: 10.0, top: 6.0),
            child: _TileOverlayIcon(Icons.motion_photos_on_rounded),
          ),
        if (asset.isAnimatedImage)
          const Padding(padding: EdgeInsets.only(right: 10.0, top: 6.0), child: _TileOverlayIcon(Icons.gif_rounded)),
      ],
    );
  }
}

class _StackIndicator extends StatelessWidget {
  final BaseAsset asset;

  const _StackIndicator({required this.asset});

  @override
  Widget build(BuildContext context) {
    if (asset is! RemoteAsset || (asset as RemoteAsset).stackId == null) {
      return const SizedBox.shrink();
    }

    return const Padding(
      padding: EdgeInsets.only(right: 10.0, top: 6.0),
      child: _TileOverlayIcon(Icons.burst_mode_rounded),
    );
  }
}

class _UploadProgressOverlay extends StatelessWidget {
  final double progress;
  final int totalBytes;
  final String speed;
  final ChunkedUploadPhase? phase;
  final int retryCount;

  const _UploadProgressOverlay({
    required this.progress,
    this.totalBytes = 0,
    this.speed = '-- MB/s',
    this.phase,
    this.retryCount = 0,
  });

  @override
  Widget build(BuildContext context) {
    final isError = progress < 0;
    final isRejected = phase == ChunkedUploadPhase.chunkRejected;
    final isHashing =
        phase == ChunkedUploadPhase.calculatingChunks || phase == ChunkedUploadPhase.calculatingHashes;
    final isChunked = phase != null;
    final numParts = isChunked ? (totalBytes / kUploadMaxPartSizeBytes).ceil() : 0;
    final currentPart = isChunked ? (progress * numParts).floor().clamp(0, numParts - 1) + 1 : 0;

    return Positioned.fill(
      child: ColoredBox(
        color: isError
            ? Colors.red.withValues(alpha: 0.6)
            : isRejected
                ? Colors.amber.withValues(alpha: 0.6)
                : Colors.black54,
        child: Stack(
          children: [
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (isError)
                    const Icon(Icons.error_outline, color: Colors.white, size: 36)
                  else
                    SizedBox(
                      width: 36,
                      height: 36,
                      child: isChunked
                          ? CustomPaint(
                              painter: _SegmentedRingPainter(
                                progress: progress,
                                numParts: numParts,
                                color: isHashing ? Colors.lightBlueAccent : Colors.greenAccent,
                                dashed: isHashing,
                              ),
                              size: const Size(36, 36),
                            )
                          : CircularProgressIndicator(
                              value: progress,
                              strokeWidth: 3,
                              backgroundColor: Colors.white24,
                              valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
                            ),
                    ),
                  const SizedBox(height: 4),
                  Text(
                    isError ? 'Error' : '${(progress * 100).toInt()}%',
                    style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                  ),
                  if (!isError && phase == ChunkedUploadPhase.sendingChunks)
                    Text(
                      context.t.upload_status.sending_chunk_progress(current: currentPart, total: numParts),
                      style: const TextStyle(color: Colors.white70, fontSize: 9),
                    )
                  else if (!isError && phase == ChunkedUploadPhase.calculatingHashes)
                    Text(
                      context.t.upload_status.hashing_part_progress(current: currentPart, total: numParts),
                      style: const TextStyle(color: Colors.white70, fontSize: 9),
                    )
                  else if (!isError && phase != null)
                    Text(
                      phase == ChunkedUploadPhase.chunkRejected && retryCount > 0
                          ? context.t.upload_status.chunk_rejected_retry(count: retryCount)
                          : phase!.localized(),
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white70, fontSize: 9),
                    ),
                  if (!isError) Text(speed, style: const TextStyle(color: Colors.white54, fontSize: 9)),
                ],
              ),
            ),
            if (isRejected)
              const Positioned(
                top: 2,
                left: 2,
                child: Icon(Icons.warning_amber_rounded, color: Colors.white, size: 16),
              ),
          ],
        ),
      ),
    );
  }
}

/// A chunked-upload progress ring drawn as separate rounded "worm" arcs — one per
/// chunk — with a gap between them, instead of a continuous ring with divider ticks.
class _SegmentedRingPainter extends CustomPainter {
  final double progress;
  final int numParts;
  final Color color;
  final bool dashed;

  const _SegmentedRingPainter({required this.progress, required this.numParts, required this.color, this.dashed = false});

  @override
  void paint(Canvas canvas, Size size) {
    final strokeWidth = dashed ? 2.4 : 3.9;
    final strokeCap = dashed ? StrokeCap.square : StrokeCap.round;
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.shortestSide - strokeWidth) / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);

    final segmentAngle = math.pi * 2 / numParts;
    // The rounded caps extend `strokeWidth / radius` radians into the gap on each
    // side, so keep the gap at least that wide to avoid overlapping heads/tails.
    final gapAngle = math.max(segmentAngle * 0.125, strokeWidth / radius);
    final sweepAngle = math.max(segmentAngle - gapAngle, 0.0);

    final trackPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = strokeCap
      ..color = Colors.white24;

    final progressPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = strokeCap
      ..color = color;

    final overallUnits = progress * numParts;

    for (var i = 0; i < numParts; i++) {
      final startAngle = -math.pi / 2 + i * segmentAngle + gapAngle / 2;
      canvas.drawArc(rect, startAngle, sweepAngle, false, trackPaint);
      final fill = (overallUnits - i).clamp(0.0, 1.0);
      if (fill > 0) {
        canvas.drawArc(rect, startAngle, sweepAngle * fill, false, progressPaint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _SegmentedRingPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.numParts != numParts ||
      oldDelegate.color != color ||
      oldDelegate.dashed != dashed;
}
