import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:background_downloader/background_downloader.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/repositories/network.repository.dart';
import 'package:immich_mobile/utils/debug_print.dart';
import 'package:logging/logging.dart';

final uploadRepositoryProvider = Provider((ref) => UploadRepository());

class UploadRepository {
  final Logger logger = Logger('UploadRepository');
  void Function(TaskStatusUpdate)? onUploadStatus;
  void Function(TaskProgressUpdate)? onTaskProgress;

  UploadRepository() {
    FileDownloader().registerCallbacks(
      group: kBackupGroup,
      taskStatusCallback: (update) => onUploadStatus?.call(update),
      taskProgressCallback: (update) => onTaskProgress?.call(update),
    );
    FileDownloader().registerCallbacks(
      group: kBackupLivePhotoGroup,
      taskStatusCallback: (update) => onUploadStatus?.call(update),
      taskProgressCallback: (update) => onTaskProgress?.call(update),
    );
    FileDownloader().registerCallbacks(
      group: kManualUploadGroup,
      taskStatusCallback: (update) => onUploadStatus?.call(update),
      taskProgressCallback: (update) => onTaskProgress?.call(update),
    );
  }

  Future<void> enqueueBackground(UploadTask task) {
    return FileDownloader().enqueue(task);
  }

  Future<List<bool>> enqueueBackgroundAll(List<UploadTask> tasks) {
    return FileDownloader().enqueueAll(tasks);
  }

  Future<void> deleteDatabaseRecords(String group) {
    return FileDownloader().database.deleteAllRecords(group: group);
  }

  Future<bool> cancelAll(String group) {
    return FileDownloader().cancelAll(group: group);
  }

  Future<int> reset(String group) {
    return FileDownloader().reset(group: group);
  }

  /// Get a list of tasks that are ENQUEUED or RUNNING
  Future<List<Task>> getActiveTasks(String group) {
    return FileDownloader().allTasks(group: group);
  }

  Future<void> start() {
    return FileDownloader().start();
  }

  Future<void> getUploadInfo() async {
    final [enqueuedTasks, runningTasks, canceledTasks, waitingTasks, pausedTasks] = await Future.wait([
      FileDownloader().database.allRecordsWithStatus(TaskStatus.enqueued, group: kBackupGroup),
      FileDownloader().database.allRecordsWithStatus(TaskStatus.running, group: kBackupGroup),
      FileDownloader().database.allRecordsWithStatus(TaskStatus.canceled, group: kBackupGroup),
      FileDownloader().database.allRecordsWithStatus(TaskStatus.waitingToRetry, group: kBackupGroup),
      FileDownloader().database.allRecordsWithStatus(TaskStatus.paused, group: kBackupGroup),
    ]);

    dPrint(
      () =>
          """
      Upload Info:
      Enqueued: ${enqueuedTasks.length}
      Running: ${runningTasks.length}
      Canceled: ${canceledTasks.length}
      Waiting: ${waitingTasks.length}
      Paused: ${pausedTasks.length}
    """,
    );
  }

  Future<UploadResult> uploadFile({
    required File file,
    required String originalFileName,
    required Map<String, String> fields,
    required Completer<void>? cancelToken,
    void Function(int bytes, int totalBytes)? onProgress,
    required String logContext,
    Client? httpClient,
  }) async {
    if (file.lengthSync() > kChunkedUploadThresholdBytes) {
      return uploadFileChunked(
        file: file,
        originalFileName: originalFileName,
        fields: fields,
        cancelToken: cancelToken,
        onProgress: onProgress,
        logContext: logContext,
        httpClient: httpClient,
      );
    }

    final String savedEndpoint = Store.get(StoreKey.serverEndpoint);

    ProgressMultipartRequest buildRequest() {
      final request = ProgressMultipartRequest(
        'POST',
        Uri.parse('$savedEndpoint/assets'),
        abortTrigger: cancelToken?.future,
        onProgress: onProgress,
      );
      request.fields.addAll(fields);
      request.files.add(MultipartFile("assetData", file.openRead(), file.lengthSync(), filename: originalFileName));
      return request;
    }

    try {
      final client = httpClient ?? NetworkRepository.client;
      StreamedResponse response;
      try {
        response = await client.send(buildRequest());
      } on RequestAbortedException {
        rethrow;
      } on ClientException catch (error) {
        logger.warning("Upload $logContext failed before a response, resending once: $error");
        response = await client.send(buildRequest());
      }

      final responseBodyString = await response.stream.bytesToString();

      if (![200, 201].contains(response.statusCode)) {
        String? errorMessage;

        if (response.statusCode == 413) {
          errorMessage = 'Error(413) File is too large to upload';
          return UploadResult.error(statusCode: response.statusCode, errorMessage: errorMessage);
        }

        try {
          final error = jsonDecode(responseBodyString);
          errorMessage = error['message'] ?? error['error'];
        } catch (_) {
          errorMessage = responseBodyString.isNotEmpty
              ? responseBodyString
              : 'Upload failed with status ${response.statusCode}';
        }

        return UploadResult.error(statusCode: response.statusCode, errorMessage: errorMessage);
      }

      try {
        final responseBody = jsonDecode(responseBodyString);
        return UploadResult.success(remoteAssetId: responseBody['id'] as String);
      } catch (e) {
        return UploadResult.error(errorMessage: 'Failed to parse server response');
      }
    } on RequestAbortedException {
      logger.warning("Upload $logContext was cancelled");
      return UploadResult.cancelled();
    } catch (error, stackTrace) {
      logger.warning("Error uploading $logContext: $error: $stackTrace");
      return UploadResult.error(errorMessage: error.toString());
    }
  }

  Future<UploadResult> uploadFileChunked({
    required File file,
    required String originalFileName,
    required Map<String, String> fields,
    required Completer<void>? cancelToken,
    void Function(int bytes, int totalBytes)? onProgress,
    required String logContext,
    Client? httpClient,
  }) async {
    final String savedEndpoint = Store.get(StoreKey.serverEndpoint);
    final client = httpClient ?? NetworkRepository.client;
    final int totalBytes = file.lengthSync();
    final int numParts = (totalBytes / kUploadMaxPartSizeBytes).ceil();
    final int partSize = (totalBytes / numParts).ceil();

    String? uploadId;

    Future<void> cleanup() async {
      final String? id = uploadId;
      if (id == null) {
        return;
      }
      try {
        await client.delete(Uri.parse('$savedEndpoint/assets/upload/$id'));
      } catch (error) {
        logger.warning("Failed to clean up chunked upload $logContext: $error");
      }
    }

    try {
      // Initialize the chunked upload session.
      Response initResponse;
      try {
        initResponse = await client.post(
          Uri.parse('$savedEndpoint/assets/upload'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'filename': originalFileName, 'totalSize': totalBytes}),
        );
      } on ClientException catch (error) {
        logger.warning("Chunked upload $logContext init failed before a response, retrying once: $error");
        initResponse = await client.post(
          Uri.parse('$savedEndpoint/assets/upload'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'filename': originalFileName, 'totalSize': totalBytes}),
        );
      }

      if (![200, 201].contains(initResponse.statusCode)) {
        return UploadResult.error(
          statusCode: initResponse.statusCode,
          errorMessage: _parseUploadError(initResponse.statusCode, initResponse.body),
        );
      }

      uploadId = (jsonDecode(initResponse.body) as Map<String, dynamic>)['uploadId'] as String;

      // Upload the file in equal-size parts, streaming each part from disk so
      // only a small read buffer is held at a time. Buffering a whole ~99 MiB
      // chunk per concurrent upload was exhausting the app's memory.
      int offset = 0;
      int retries = 0;
      const int maxRetries = 5;

      while (offset < totalBytes) {
        final int readLength = min(partSize, totalBytes - offset);

        try {
          final request = ProgressStreamRequest(
            'PUT',
            Uri.parse('$savedEndpoint/assets/upload/$uploadId?offset=$offset'),
            bodyStream: file.openRead(offset, offset + readLength),
            contentLength: readLength,
            abortTrigger: cancelToken?.future,
            onProgress: (inChunkBytes, _) => onProgress?.call(offset + inChunkBytes, totalBytes),
          );
          request.headers['Content-Type'] = 'application/octet-stream';

          final StreamedResponse response = await client.send(request).timeout(const Duration(seconds: 120));
          final responseBodyString = await response.stream.bytesToString();

          if (response.statusCode == 200 || response.statusCode == 201) {
            offset += readLength;
            retries = 0;
          } else if (response.statusCode == 409) {
            // Server committed fewer bytes than we sent; resync and re-read.
            offset = (jsonDecode(responseBodyString) as Map<String, dynamic>)['offset'] as int;
            retries = 0;
          } else {
            await cleanup();
            return UploadResult.error(
              statusCode: response.statusCode,
              errorMessage: _parseUploadError(response.statusCode, responseBodyString),
            );
          }
        } on RequestAbortedException {
          rethrow;
        } on Exception catch (error) {
          retries++;
          if (retries > maxRetries) {
            rethrow;
          }
          offset = await _getChunkedUploadOffset(client, savedEndpoint, uploadId);
          logger.warning("Chunked upload $logContext failed, resuming from offset $offset: $error");
        }
      }

      // Finalize the upload with the same metadata fields as the single-shot path.
      final ProgressMultipartRequest request = ProgressMultipartRequest(
        'POST',
        Uri.parse('$savedEndpoint/assets/upload/$uploadId/finalize'),
        abortTrigger: cancelToken?.future,
      );
      request.fields.addAll(fields);
      // The finalize request has no file part, so the filename must travel as a form field.
      request.fields['filename'] = originalFileName;

      StreamedResponse response;
      try {
        response = await client.send(request);
      } on RequestAbortedException {
        rethrow;
      } on ClientException catch (error) {
        logger.warning("Chunked upload $logContext finalize failed before a response, retrying once: $error");
        response = await client.send(request);
      }

      final responseBodyString = await response.stream.bytesToString();

      if (![200, 201].contains(response.statusCode)) {
        await cleanup();
        return UploadResult.error(
          statusCode: response.statusCode,
          errorMessage: _parseUploadError(response.statusCode, responseBodyString),
        );
      }

      try {
        final responseBody = jsonDecode(responseBodyString);
        return UploadResult.success(remoteAssetId: responseBody['id'] as String);
      } catch (e) {
        return UploadResult.error(errorMessage: 'Failed to parse server response');
      }
    } on RequestAbortedException {
      logger.warning("Upload $logContext was cancelled");
      await cleanup();
      return UploadResult.cancelled();
    } catch (error, stackTrace) {
      logger.warning("Error uploading $logContext: $error: $stackTrace");
      await cleanup();
      return UploadResult.error(errorMessage: error.toString());
    }
  }

  String? _parseUploadError(int statusCode, String responseBody) {
    if (statusCode == 413) {
      return 'Error(413) File is too large to upload';
    }

    try {
      final error = jsonDecode(responseBody);
      return error['message'] ?? error['error'];
    } catch (_) {
      return responseBody.isNotEmpty ? responseBody : 'Upload failed with status $statusCode';
    }
  }

  Future<int> _getChunkedUploadOffset(Client client, String savedEndpoint, String uploadId) async {
    // Retry with a delay so a transient network drop (e.g. airplane mode) doesn't
    // abort the upload before the network returns. A single immediate query would
    // fail while the network is still down and force the whole upload to restart.
    const int maxAttempts = 10;
    const Duration retryDelay = Duration(seconds: 3);
    for (var attempt = 0; ; attempt++) {
      try {
        final response = await client
            .get(Uri.parse('$savedEndpoint/assets/upload/$uploadId'))
            .timeout(const Duration(seconds: 15));
        if (response.statusCode != 200) {
          throw ClientException(
            'Failed to query chunked upload status: ${response.statusCode}',
            Uri.parse('$savedEndpoint/assets/upload/$uploadId'),
          );
        }
        return (jsonDecode(response.body) as Map<String, dynamic>)['offset'] as int;
      } catch (error) {
        if (attempt >= maxAttempts - 1) {
          rethrow;
        }
        await Future.delayed(retryDelay);
      }
    }
  }
}

class ProgressMultipartRequest extends MultipartRequest with Abortable {
  ProgressMultipartRequest(super.method, super.url, {this.abortTrigger, this.onProgress});

  @override
  final Future<void>? abortTrigger;

  final void Function(int bytes, int totalBytes)? onProgress;

  @override
  ByteStream finalize() {
    final byteStream = super.finalize();
    if (onProgress == null) {
      return byteStream;
    }

    final total = contentLength;
    var bytes = 0;
    final stream = byteStream.transform(
      StreamTransformer.fromHandlers(
        handleData: (List<int> data, EventSink<List<int>> sink) {
          bytes += data.length;
          onProgress!(bytes, total);
          sink.add(data);
        },
      ),
    );
    return ByteStream(stream);
  }
}

class ProgressStreamRequest extends BaseRequest with Abortable {
  ProgressStreamRequest(
    super.method,
    super.url, {
    required this.bodyStream,
    required int contentLength,
    this.abortTrigger,
    this.onProgress,
  }) {
    this.contentLength = contentLength;
  }

  @override
  final Future<void>? abortTrigger;

  final Stream<List<int>> bodyStream;
  final void Function(int bytes, int totalBytes)? onProgress;

  @override
  ByteStream finalize() {
    super.finalize();
    final byteStream = ByteStream(bodyStream);
    if (onProgress == null) {
      return byteStream;
    }

    final total = contentLength ?? 0;
    var bytes = 0;
    final stream = byteStream.transform(
      StreamTransformer.fromHandlers(
        handleData: (List<int> data, EventSink<List<int>> sink) {
          bytes += data.length;
          onProgress!(bytes, total);
          sink.add(data);
        },
      ),
    );
    return ByteStream(stream);
  }
}

class UploadResult {
  final bool isSuccess;
  final bool isCancelled;
  final String? remoteAssetId;
  final String? errorMessage;
  final int? statusCode;

  const UploadResult({
    required this.isSuccess,
    required this.isCancelled,
    this.remoteAssetId,
    this.errorMessage,
    this.statusCode,
  });

  factory UploadResult.success({required String remoteAssetId}) {
    return UploadResult(isSuccess: true, isCancelled: false, remoteAssetId: remoteAssetId);
  }

  factory UploadResult.error({String? errorMessage, int? statusCode}) {
    return UploadResult(isSuccess: false, isCancelled: false, errorMessage: errorMessage, statusCode: statusCode);
  }

  factory UploadResult.cancelled() {
    return const UploadResult(isSuccess: false, isCancelled: true);
  }
}
