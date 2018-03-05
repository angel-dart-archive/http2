import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:angel_framework/angel_framework.dart' hide Header;
import 'package:angel_http2/angel_http2.dart';
import 'package:http/src/multipart_file.dart' as http;
import 'package:http/src/multipart_request.dart' as http;
import 'package:http/http.dart' as http;
import 'package:http2/transport.dart';
import 'package:http_parser/http_parser.dart';
import 'package:test/test.dart';
import 'http2_client.dart';

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
    app = new Angel()
      ..storeOriginalBuffer = true
      ..injectEncoders({'gzip': GZIP.encoder});

    app.get('/', (ResponseContext res) {
      res
        ..write('Hello world')
        ..end();
    });

    app.all('/method', (RequestContext req) => req.method);

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

    app.post('/body', (RequestContext req) => req.lazyBody());

    app.post('/upload', (RequestContext req) async {
      var body = await req.lazyBody(), files = await req.lazyFiles();
      stdout.add(req.originalBuffer);
      var file = files.firstWhere((f) => f.name == 'file');
      return [file.data.length, file.mimeType, body];
    });

    app.get('/push', (ResponseContext res) async {
      res
        ..useStream()
        ..write('ok')
        ..close();

      if (res is Http2ResponseContext && res.canPush) {
        res.push('a')
          ..useStream()
          ..write('a')
          ..close();

        res.push('b')
          ..useStream()
          ..write('b')
          ..close();
      }
    });

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

  test('streamed response', () async {
    var response = await client.get(serverRoot.replace(path: '/stream'));
    expect(response.body, jfk);
  });

  group('gzip', () {
    test('buffered response', () async {
      var response = await client
          .get(serverRoot, headers: {'accept-encoding': 'gzip, deflate, br'});
      expect(response.headers['content-encoding'], 'gzip');
      var decoded = GZIP.decode(response.bodyBytes);
      expect(UTF8.decode(decoded), 'Hello world');
    });

    test('streamed response', () async {
      var response = await client.get(serverRoot.replace(path: '/stream'),
          headers: {'accept-encoding': 'gzip'});
      expect(response.headers['content-encoding'], 'gzip');
      var decoded = GZIP.decode(response.bodyBytes);
      expect(UTF8.decode(decoded), jfk);
    });
  });

  test('method parsed', () async {
    var response = await client.delete(serverRoot.replace(path: '/method'));
    expect(response.body, JSON.encode('DELETE'));
  });

  test('json response', () async {
    var response = await client.get(serverRoot.replace(path: '/json'));
    expect(response.body, JSON.encode({'foo': 'bar'}));
    expect(ContentType.parse(response.headers['content-type']).mimeType,
        ContentType.JSON.mimeType);
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

  test('server push', () async {
    var socket = await SecureSocket.connect(
      serverRoot.host,
      serverRoot.port ?? 443,
      onBadCertificate: (_) => true,
      supportedProtocols: ['h2'],
    );

    var connection = new ClientTransportConnection.viaSocket(
      socket,
      settings: new ClientSettings(allowServerPushes: true),
    );

    var headers = <Header>[
      new Header.ascii(':authority', serverRoot.authority),
      new Header.ascii(':method', 'GET'),
      new Header.ascii(':path', serverRoot.replace(path: '/push').path),
      new Header.ascii(':scheme', serverRoot.scheme),
    ];

    var stream = await connection.makeRequest(headers, endStream: true);

    var bb = await stream.incomingMessages
        .where((s) => s is DataStreamMessage)
        .cast<DataStreamMessage>()
        .fold<BytesBuilder>(
            new BytesBuilder(), (out, msg) => out..add(msg.bytes));

    // Check that main body was sent
    expect(UTF8.decode(bb.takeBytes()), 'ok');

    var pushes = await stream.peerPushes.toList();
    expect(pushes, hasLength(2));

    var pushA = pushes[0], pushB = pushes[1];

    String getPath(TransportStreamPush p) => ASCII.decode(p.requestHeaders
        .firstWhere((h) => ASCII.decode(h.name) == ':path')
        .value);

    /*
    Future<String> getBody(ClientTransportStream stream) async {
      await stream.outgoingMessages.close();
      var bb = await stream.incomingMessages
          .map((s) {
            if (s is HeadersStreamMessage) {
              for (var h in s.headers) {
                print('${ASCII.decode(h.name)}: ${ASCII.decode(h.value)}');
              }
            } else if (s is DataStreamMessage) {
              print(UTF8.decode(s.bytes));
            }

            return s;
          })
          .where((s) => s is DataStreamMessage)
          .cast<DataStreamMessage>()
          .fold<BytesBuilder>(
              new BytesBuilder(), (out, msg) => out..add(msg.bytes));
      return UTF8.decode(bb.takeBytes());
    }
    */

    expect(getPath(pushA), '/a');
    expect(getPath(pushB), '/b');

    // TODO: Dart http/2 client seems to not be able to get body
    // However, Chrome, Firefox, Edge all can
    //expect(await getBody(pushA.stream), 'a');
    //expect(await getBody(pushB.stream), 'b');
  });

  group('body parsing', () {
    test('urlencoded body parsed', () async {
      var response = await client.post(
        serverRoot.replace(path: '/body'),
        headers: {
          'accept': 'application/json',
          'content-type': 'application/x-www-form-urlencoded'
        },
        body: 'foo=bar',
      );
      expect(response.body, JSON.encode({'foo': 'bar'}));
    });

    test('json body parsed', () async {
      var response = await client.post(serverRoot.replace(path: '/body'),
          headers: {
            'accept': 'application/json',
            'content-type': 'application/json'
          },
          body: JSON.encode({'foo': 'bar'}));
      expect(response.body, JSON.encode({'foo': 'bar'}));
    });

    test('multipart body parsed', () async {
      var rq = new http.MultipartRequest(
          'POST', serverRoot.replace(path: '/upload'));
      rq.headers.addAll({'accept': 'application/json'});

      rq.fields['foo'] = 'bar';
      rq.files.add(new http.MultipartFile(
          'file', new Stream.fromIterable([UTF8.encode('hello world')]), 11,
          contentType: new MediaType('angel', 'framework')));

      var response = await client.send(rq);
      var responseBody = await response.stream.transform(UTF8.decoder).join();

      expect(
          responseBody,
          JSON.encode([
            11,
            'angel/framework',
            {'foo': 'bar'}
          ]));
    });
  });
}
