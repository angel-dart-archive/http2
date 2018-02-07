# http2
An [Angel](https://angel-dart.github.io) adapter to serve applications over
HTTP/2.

# Usage
The library `package:angel_http2/angel_http2.dart` exports `AngelHttp2`,
a class that implements a multi-protocol server. HTTP/2 requests will be
handled by the class, while HTTP/1.x requests will be fired out of the
`onHttp1` stream. Typically, you should hook up the `onHttp1` stream to
an instance of `AngelHttp` to serve the same application instance over
multiple protocols.

```dart
main() async {
  var app = new Angel();
  app.logger = new Logger('angel')..onRecord.listen(print);

  app.get('/', 'Hello HTTP/2!!!');

  var ctx = new SecurityContext()
    ..useCertificateChain('dev.pem')
    ..usePrivateKey('dev.key', password: 'dartdart');

  try {
    ctx.setAlpnProtocols(['h2'], true);
  } catch (e, st) {
    app.logger.severe(
      'Cannot set ALPN protocol on server to h2. The server will only serve HTTP/1.x.',
      e,
      st,
    );
  }

  var http1 = new AngelHttp(app);
  var http2 = new AngelHttp2(app, ctx);

  // HTTP/1.x requests will fallback to `AngelHttp`
  http2.onHttp1.listen(http1.handleRequest);

  var server = await http2.startServer('127.0.0.1', 3000);
  print('Listening at https://${server.address.address}:${server.port}');
}
```

## Server Push
