import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:duanju_app/app_updates.dart';
import 'package:flutter_test/flutter_test.dart';

import 'app_updates_test.dart' show installed, releaseJson;

class TestHeaders implements HttpHeaders {
  final values = <String, String>{};
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    values[name.toLowerCase()] = value.toString();
  }

  @override
  String? value(String name) => values[name.toLowerCase()];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class TestResponse extends Stream<List<int>> implements HttpClientResponse {
  TestResponse(
    this.chunks, {
    this.statusCode = 200,
    this.contentLength = -1,
    Map<String, String> headers = const {},
  }) {
    this.headers.values.addAll(headers);
  }
  final List<List<int>> chunks;
  @override
  final int statusCode;
  @override
  final int contentLength;
  @override
  final TestHeaders headers = TestHeaders();
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream.fromIterable(chunks).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class TestRequest implements HttpClientRequest {
  TestRequest(this.response);
  final TestResponse response;
  @override
  final TestHeaders headers = TestHeaders();
  @override
  bool followRedirects = true;
  @override
  Future<HttpClientResponse> close() async => response;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class TestClient implements HttpClient {
  TestClient(this.responses);
  final List<TestResponse> responses;
  final requests = <TestRequest>[];
  final urls = <Uri>[];
  @override
  Duration? connectionTimeout;
  @override
  bool autoUncompress = true;
  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    urls.add(url);
    final request = TestRequest(responses.removeAt(0));
    requests.add(request);
    return request;
  }

  @override
  void close({bool force = false}) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('metadata uses identity encoding and refuses encoded bytes', () async {
    final client = TestClient([
      TestResponse([utf8.encode(jsonEncode(releaseJson()))]),
    ]);
    final transport = GithubUpdateTransport(clientFactory: () => client);
    expect((await transport.latest())['tag_name'], 'app-v0.1.6-28');
    expect(client.requests.single.headers.value('accept-encoding'), 'identity');
    expect(client.requests.single.followRedirects, isFalse);
    final compressed = TestClient([
      TestResponse(
        [
          [1, 2],
        ],
        headers: {'content-encoding': 'gzip'},
      ),
    ]);
    await expectLater(
      GithubUpdateTransport(clientFactory: () => compressed).latest(),
      throwsFormatException,
    );
  });
  test('metadata rejects large body, rate limits and malformed JSON', () async {
    for (final response in [
      TestResponse([List.filled(1024 * 1024 + 1, 32)]),
      TestResponse([], statusCode: 403),
      TestResponse([], statusCode: 429),
      TestResponse([utf8.encode('not JSON')]),
    ]) {
      await expectLater(
        GithubUpdateTransport(clientFactory: () => TestClient([response]))
            .latest(),
        throwsA(isA<Exception>()),
      );
    }
  });
  test('APK follows only controlled redirects and rejects untrusted origin before request', () async {
    final candidate = AppRelease.parse(releaseJson(), installed)!;
    final dir = await Directory.systemTemp.createTemp('updater-transport-');
    addTearDown(() => dir.delete(recursive: true));
    for (final destination in [
      'http://release-assets.githubusercontent.com/a',
      'https://evil.test/a',
      'https://127.0.0.1/a',
    ]) {
      final client = TestClient([
        TestResponse([], statusCode: 302, headers: {'location': destination}),
      ]);
      final transport = GithubUpdateTransport(clientFactory: () => client);
      await expectLater(
        transport.download(candidate, File('${dir.path}/x'), (_) {}),
        throwsFormatException,
      );
      expect(client.urls.length, 1);
    }
    final client = TestClient([
      TestResponse(
        [],
        statusCode: 302,
        headers: {
          'location':
              'https://release-assets.githubusercontent.com/a?signature=short',
        },
      ),
      TestResponse([
        [1, 2],
        [3, 4],
      ], contentLength: 4),
    ]);
    final output = File('${dir.path}/good');
    await GithubUpdateTransport(clientFactory: () => client)
        .download(candidate, output, (_) {});
    expect(await output.readAsBytes(), [1, 2, 3, 4]);
    expect(
      client.requests.every(
        (request) => request.headers.value('accept-encoding') == 'identity',
      ),
      isTrue,
    );
  });
  test('APK rejects content length mismatch, oversized stream, short stream, compression and redirect loop', () async {
    final candidate = AppRelease.parse(releaseJson(), installed)!;
    final dir = await Directory.systemTemp.createTemp('updater-transport-');
    addTearDown(() => dir.delete(recursive: true));
    for (final responses in [
      [
        TestResponse([
          [1, 2, 3, 4],
        ], contentLength: 5),
      ],
      [
        TestResponse([
          [1, 2, 3, 4, 5],
        ]),
      ],
      [
        TestResponse([
          [1, 2, 3],
        ]),
      ],
      [
        TestResponse(
          [
            [1, 2, 3, 4],
          ],
          headers: {'content-encoding': 'gzip'},
        ),
      ],
      List.generate(
        6,
        (_) => TestResponse(
          [],
          statusCode: 302,
          headers: {
            'location': 'https://release-assets.githubusercontent.com/a',
          },
        ),
      ),
    ]) {
      final client = TestClient(responses);
      await expectLater(
        GithubUpdateTransport(clientFactory: () => client)
            .download(candidate, File('${dir.path}/x'), (_) {}),
        throwsFormatException,
      );
    }
  });
}
