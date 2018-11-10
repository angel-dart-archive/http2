# DEPRECATED
As of Angel 2, HTTP/2 support is included out-of-the-box. Just import `package:angel_framework/http2.dart`, and you're ready to go!

# http2
[![Pub](https://img.shields.io/pub/v/angel_http2.svg)](https://pub.dartlang.org/packages/angel_http2)
[![build status](https://travis-ci.org/angel-dart/http2.svg)](https://travis-ci.org/angel-dart/http2)

An [Angel](https://angel-dart.github.io) adapter to serve applications over
HTTP/2.
Supports server push, falling back to HTTP/1.x, and more.

Requires SSL.

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
      'Cannot set ALPN protocol on server to `h2`. The server will only serve HTTP/1.x.',
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
In HTTP/2, the server can send down resources, even if they were not explicitly requested.
This can be very useful for SPA's, and to decrease initial load times in general.

This is also essential for an implementation of the
[PRPL](https://developers.google.com/web/fundamentals/performance/prpl-pattern/) pattern.

To push a resource, call `Http2ResponseContextImpl.push`. This method itself returns an
`Http2ResponseContextImpl`, which means that pushed resources also can be used with API's
like `sendFile`, `serialize`, and everything available for use with a `ResponseContext`.

You **must** use streaming methods to push content via server push.
i.e. `addStream`, `pipe`, `streamFile`.

Response buffering does not work with server push.

```dart
configureServer(Angel app) async {
    var publicDir = new Directory('example/public');
    var indexHtml = new File.fromUri(publicDir.uri.resolve('index.html'));
    var styleCss = new File.fromUri(publicDir.uri.resolve('style.css'));
    var appJs = new File.fromUri(publicDir.uri.resolve('app.js'));
    
    // Send files when requested
    app
      ..get('/style.css', (res) => res.sendFile(styleCss))
      ..get('/app.js', (res) => res.sendFile(appJs));
    
    app.get('/', (ResponseContext res) async {
      // Regardless of whether we pushed other resources, let's still send /index.html.
      await res.streamFile(indexHtml);
  
      // If the client is HTTP/2 and supports server push, let's
      // send down /style.css and /app.js as well, to improve initial load time.
      if (res is Http2ResponseContext && res.canPush) {
        await res.push('/style.css').streamFile(styleCss);
        await res.push('/app.js').streamFile(appJs);
      }
    });
}
```
