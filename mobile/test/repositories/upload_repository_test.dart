import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/repositories/upload.repository.dart';
import 'package:mocktail/mocktail.dart';

class _MockHttpClient extends Mock implements http.Client {}

class _FakeBaseRequest extends Fake implements http.BaseRequest {}

// keeps the FileDownloader singleton off the disk and off the platform channels
class _NoStorage extends Fake implements PersistentStorage {
  @override
  Future<void> initialize() async {}
}

void main() {
  late _MockHttpClient client;
  late UploadRepository sut;
  late File file;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    FileDownloader(persistentStorage: _NoStorage());
    final db = Drift(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    await StoreService.init(storeRepository: StoreRepository(db));
    await Store.put(StoreKey.serverEndpoint, 'http://demo.immich.app/api');
    registerFallbackValue(_FakeBaseRequest());
    registerFallbackValue(Uri.parse('http://example.com'));
    file = File('${Directory.systemTemp.createTempSync().path}/photo.jpg')..writeAsStringSync('bytes');
  });

  setUp(() {
    client = _MockHttpClient();
    sut = UploadRepository();
  });

  // consumes the body like a real client would, so a reused request would blow up on the second send
  void stubSend(FutureOr<http.StreamedResponse> Function(int attempt) answer) {
    var attempt = 0;
    when(() => client.send(any())).thenAnswer((invocation) async {
      final request = invocation.positionalArguments.single as http.BaseRequest;
      await request.finalize().drain<void>();
      return answer(++attempt);
    });
  }

  http.StreamedResponse response(int status, String body) =>
      http.StreamedResponse(Stream.value(utf8.encode(body)), status);

  Future<UploadResult> upload() => sut.uploadFile(
    file: file,
    originalFileName: 'photo.jpg',
    fields: const {'deviceAssetId': 'a1'},
    cancelToken: null,
    logContext: 'a1',
    httpClient: client,
  );

  test('resends once when the first send dies before a response', () async {
    stubSend((attempt) {
      if (attempt == 1) {
        throw http.ClientException('Broken pipe');
      }
      return response(201, '{"id":"remote-1"}');
    });

    final result = await upload();

    expect(result.isSuccess, isTrue);
    expect(result.remoteAssetId, 'remote-1');
    verify(() => client.send(any())).called(2);
  });

  test('a second transport failure is an error, no third send', () async {
    stubSend((_) => throw http.ClientException('Connection reset'));

    final result = await upload();

    expect(result.isSuccess, isFalse);
    expect(result.isCancelled, isFalse);
    verify(() => client.send(any())).called(2);
  });

  test('a cancelled upload is not resent', () async {
    stubSend((_) => throw http.RequestAbortedException());

    final result = await upload();

    expect(result.isCancelled, isTrue);
    verify(() => client.send(any())).called(1);
  });

  test('a cancel during the resend still counts as cancelled', () async {
    stubSend((attempt) {
      if (attempt == 1) {
        throw http.ClientException('Broken pipe');
      }
      throw http.RequestAbortedException();
    });

    final result = await upload();

    expect(result.isCancelled, isTrue);
    verify(() => client.send(any())).called(2);
  });

  test('a server error response is not resent', () async {
    stubSend((_) => response(500, '{"message":"boom"}'));

    final result = await upload();

    expect(result.statusCode, 500);
    expect(result.errorMessage, 'boom');
    verify(() => client.send(any())).called(1);
  });

  group('chunked upload', () {
    late File bigFile;
    const int bigSize = kChunkedUploadThresholdBytes + 1024 * 1024; // 100 MiB

    setUpAll(() {
      bigFile = File('${Directory.systemTemp.createTempSync().path}/big.mp4');
      final randomAccessFile = bigFile.openSync(mode: FileMode.write);
      randomAccessFile.truncateSync(bigSize);
      randomAccessFile.closeSync();
    });

    setUp(() {
      sut = UploadRepository(isChunkedUploadSupported: () => true);
    });

    http.Response httpResponse(String body, [int status = 200]) => http.Response(body, status);

    void stubInit() {
      when(
        () => client.post(
          any(),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
        ),
      ).thenAnswer((_) async => httpResponse('{"uploadId":"upload-1"}', 201));
    }

    Future<UploadResult> uploadBig() => sut.uploadFile(
      file: bigFile,
      originalFileName: 'big.mp4',
      fields: const {'deviceAssetId': 'a1'},
      cancelToken: null,
      logContext: 'big',
      httpClient: client,
    );

    test('falls back to single-shot upload when chunked upload is not supported', () async {
      sut = UploadRepository();

      when(() => client.send(any())).thenAnswer((invocation) async {
        final request = invocation.positionalArguments.single as http.BaseRequest;
        expect(request.url.path, '/api/assets');
        await request.finalize().drain<void>();
        return response(201, '{"id":"remote-1"}');
      });

      final result = await uploadBig();

      expect(result.isSuccess, isTrue);
      expect(result.remoteAssetId, 'remote-1');
      verify(() => client.send(any())).called(1);
      verifyNever(() => client.post(any(), headers: any(named: 'headers'), body: any(named: 'body')));
    });

    test('advertises per-chunk sha256 hashes in the init request', () async {
      String? initBody;
      when(
        () => client.post(
          any(),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
        ),
      ).thenAnswer((invocation) async {
        initBody = invocation.namedArguments[const Symbol('body')] as String?;
        return httpResponse('{"uploadId":"upload-1"}', 201);
      });

      when(() => client.send(any())).thenAnswer((invocation) async {
        final request = invocation.positionalArguments.single as http.BaseRequest;
        if (request.url.path.endsWith('/finalize')) {
          await request.finalize().drain<void>();
          return response(201, '{"id":"remote-1"}');
        }
        final offset = int.parse(request.url.queryParameters['offset']!);
        final committed = offset + (request.contentLength ?? 0);
        await request.finalize().drain<void>();
        return response(200, '{"offset": $committed}');
      });

      await uploadBig();

      final body = jsonDecode(initBody!) as Map<String, dynamic>;
      expect(body['chunkCount'], 2);
      expect(body['chunkSize'], (bigSize / 2).ceil());
      final chunkHashes = body['chunkHashes'] as List;
      expect(chunkHashes, hasLength(2));
      for (final hash in chunkHashes) {
        expect(hash, matches(RegExp(r'^[0-9a-f]{64}$')));
      }
    });

    test('splits into equal parts under the limit and finalizes with the filename', () async {
      stubInit();
      final offsets = <int>[];
      String? finalizedFilename;

      when(() => client.send(any())).thenAnswer((invocation) async {
        final request = invocation.positionalArguments.single as http.BaseRequest;
        if (request.url.path.endsWith('/finalize')) {
          finalizedFilename = (request as http.MultipartRequest).fields['filename'];
          await request.finalize().drain<void>();
          return response(201, '{"id":"remote-1"}');
        }
        final offset = int.parse(request.url.queryParameters['offset']!);
        offsets.add(offset);
        final committed = offset + (request.contentLength ?? 0);
        await request.finalize().drain<void>();
        return response(200, '{"offset": $committed}');
      });

      final result = await uploadBig();

      expect(result.isSuccess, isTrue);
      expect(result.remoteAssetId, 'remote-1');
      expect(offsets, [0, (bigSize / 2).ceil()]);
      expect(offsets.last, lessThan(kChunkedUploadThresholdBytes));
      expect(finalizedFilename, 'big.mp4');
    });

    test('resumes from the committed offset after a transport failure', () async {
      stubInit();
      when(() => client.get(any())).thenAnswer((_) async => httpResponse('{"offset":0}', 200));
      var chunkAttempts = 0;

      when(() => client.send(any())).thenAnswer((invocation) async {
        final request = invocation.positionalArguments.single as http.BaseRequest;
        if (request.url.path.endsWith('/finalize')) {
          await request.finalize().drain<void>();
          return response(201, '{"id":"remote-1"}');
        }
        chunkAttempts++;
        if (chunkAttempts == 1) {
          throw http.ClientException('Broken pipe');
        }
        final offset = int.parse(request.url.queryParameters['offset']!);
        final committed = offset + (request.contentLength ?? 0);
        await request.finalize().drain<void>();
        return response(200, '{"offset": $committed}');
      });

      final result = await uploadBig();

      expect(result.isSuccess, isTrue);
      expect(chunkAttempts, 3);
      verify(() => client.get(any())).called(1);
    });

    test('recovers when the append response omits the offset field', () async {
      stubInit();
      when(() => client.send(any())).thenAnswer((invocation) async {
        final request = invocation.positionalArguments.single as http.BaseRequest;
        if (request.url.path.endsWith('/finalize')) {
          await request.finalize().drain<void>();
          return response(201, '{"id":"remote-1"}');
        }
        await request.finalize().drain<void>();
        return response(200, '{}'); // malformed: no offset field
      });

      final result = await uploadBig();

      expect(result.isSuccess, isTrue);
      expect(result.remoteAssetId, 'remote-1');
    });

    test('cancel mid-chunk deletes the partial and returns cancelled', () async {
      stubInit();
      when(() => client.delete(any())).thenAnswer((_) async => httpResponse('', 204));

      when(() => client.send(any())).thenAnswer((invocation) async {
        final request = invocation.positionalArguments.single as http.BaseRequest;
        if (request.url.path.endsWith('/finalize')) {
          await request.finalize().drain<void>();
          return response(201, '{"id":"remote-1"}');
        }
        throw http.RequestAbortedException();
      });

      final result = await uploadBig();

      expect(result.isCancelled, isTrue);
      verify(() => client.delete(any())).called(1);
    });

    test('reports smooth cumulative progress within each chunk', () async {
      stubInit();
      final progress = <int>[];

      when(() => client.send(any())).thenAnswer((invocation) async {
        final request = invocation.positionalArguments.single as http.BaseRequest;
        if (request.url.path.endsWith('/finalize')) {
          await request.finalize().drain<void>();
          return response(201, '{"id":"remote-1"}');
        }
        final offset = int.parse(request.url.queryParameters['offset']!);
        final committed = offset + (request.contentLength ?? 0);
        await request.finalize().drain<void>();
        return response(200, '{"offset": $committed}');
      });

      final result = await sut.uploadFile(
        file: bigFile,
        originalFileName: 'big.mp4',
        fields: const {'deviceAssetId': 'a1'},
        cancelToken: null,
        logContext: 'big',
        httpClient: client,
        onProgress: (bytes, totalBytes) => progress.add(bytes),
      );

      expect(result.isSuccess, isTrue);
      // Progress must advance smoothly (far more callbacks than the 2 chunks)
      // and be monotonically increasing up to the full file size.
      expect(progress.length, greaterThan(2));
      for (var i = 1; i < progress.length; i++) {
        expect(progress[i], greaterThan(progress[i - 1]));
      }
      expect(progress.last, bigSize);
    });
  });
}
