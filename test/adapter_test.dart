import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:angel_framework/angel_framework.dart';
import 'package:angel_http2/angel_http2.dart';
import 'package:test/test.dart';
import 'http2_client.dart';

// TODO(thosakwe): GZIP encoding
// TODO(thosakwe): server push tests

const String jfk =
    'Ask not what your country can do for you, but what you can do for your country.';

Stream<List<int>> jfkStream() {
  return new Stream.fromIterable([UTF8.encode(jfk)]);
}

void main() {
  var client = new Http2Client();
  Angel app;
  AngelHttp2 http2;
  Uri serverRoot;

  setUp(() async {
    app = new Angel();

    app.get('/', (ResponseContext res) {
      res
        ..write('Hello ')
        ..write('world')
        ..end();
    });

    app.post('/method', (RequestContext req) => req.method);

    app.get('/json', {'foo': 'bar'});

    app.get('/stream', (ResponseContext res) => jfkStream().pipe(res));

    app.get('/headers', (ResponseContext res) {
      res
        ..headers.addAll({'foo': 'bar', 'x-angel': 'http2'})
        ..end();
    });

    app.get('/status', (ResponseContext res) {
      res
        ..statusCode = 1337
        ..end();
    });

    app.get('/body', (RequestContext req) => req.headers);

    var ctx = new SecurityContext()
      ..useCertificateChain('dev.pem')
      ..usePrivateKey('dev.key', password: 'dartdart')
      ..setAlpnProtocols(['h2'], true);

    http2 = new AngelHttp2(app, ctx);

    var server = await http2.startServer();
    serverRoot = Uri.parse('https://127.0.0.1:${server.port}');
  });

  tearDown(() async {
    await http2.close();
  });

  test('buffered response', () async {
    var response = await client.get(serverRoot);
    expect(response.body, 'Hello world');
  });

  test('method parsed', () async {
    var response = await client.delete(serverRoot);
    expect(response.body, JSON.encode('DELETE'));
  });

  test('json response', () async {
    var response = await client.get(serverRoot.replace(path: '/json'));
    expect(response.body, JSON.encode({'foo': 'bar'}));
    expect(ContentType.parse(response.headers['content-type']).mimeType, ContentType.JSON.mimeType);
  });

  test('streamed response', () async {
    var response = await client.get(serverRoot.replace(path: '/stream'));
    expect(response.body, jfk);
  });

  test('status sent', () async {
    var response = await client.get(serverRoot.replace(path: '/status'));
    expect(response.statusCode, 1337);
  });

  test('headers sent', () async {
    var response = await client.get(serverRoot.replace(path: '/headers'));
    expect(response.headers['foo'], 'bar');
    expect(response.headers['x-angel'], 'http2');
  });

  group(
    'body parsing',
    () {
      // TODO(thosakwe): Implement body parsing

      test('urlencoded body parsed', () async {});

      test('json body parsed', () async {});

      test('multipart body parsed', () async {});
    },
    skip: 'Body parsing not yet implemented',
  );
}
