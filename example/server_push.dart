import 'dart:io';
import 'package:angel_framework/angel_framework.dart';
import 'package:angel_http2/angel_http2.dart';
import 'package:logging/logging.dart';
import 'pretty_logging.dart';

main() async {
  var app = new Angel();
  app.logger = new Logger('angel')..onRecord.listen(prettyLog);

  var publicDir = new Directory('example/public');
  var indexHtml = new File.fromUri(publicDir.uri.resolve('index.html'));
  var styleCss = new File.fromUri(publicDir.uri.resolve('style.css'));
  var appJs = new File.fromUri(publicDir.uri.resolve('app.js'));

  // Send files when requested
  app
    ..get('/style.css', (res) => res.streamFile(styleCss))
    ..get('/app.js', (res) => res.streamFile(appJs));

  app.get('/', (ResponseContext res) async {
    // Regardless of whether we pushed other resources, let's still send /index.html.
    await res.streamFile(indexHtml);

    // If the client is HTTP/2 and supports server push, let's
    // send down /style.css and /app.js as well, to improve initial load time.
    if (res is Http2ResponseContextImpl && res.canPush) {
      await res.push('/style.css').streamFile(styleCss);
      await res.push('/app.js').streamFile(appJs);
    }
  });

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
