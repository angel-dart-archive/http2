import 'dart:async';
import 'dart:io';
import 'package:angel_framework/angel_framework.dart';
import 'package:http2/src/artificial_server_socket.dart';
import 'package:http2/transport.dart';
import 'http2_request_context.dart';

class AngelHttp2 {
  final Angel app;
  final SecurityContext securityContext;
  final StreamController<HttpRequest> _onHttp1 = new StreamController();
  ArtificialServerSocket _artificial;
  HttpServer _httpServer;
  StreamController<SecureSocket> _http1;
  SecureServerSocket _socket;
  StreamSubscription _sub;
  Future<SecureServerSocket> Function(dynamic, int, SecurityContext)
      _serverGenerator;

  AngelHttp2(this.app, this.securityContext) {
    _serverGenerator = SecureServerSocket.bind;
  }

  factory AngelHttp2.custom(
      Angel app,
      SecurityContext ctx,
      Future<SecureServerSocket> serverGenerator(
          address, int port, SecurityContext ctx)) {
    return new AngelHttp2(app, ctx).._serverGenerator = serverGenerator;
  }

  /// Fires when an HTTP/1.x request is received.
  Stream<HttpRequest> get onHttp1 => _onHttp1.stream;

  // TODO: Add fromSecurityContext, secure
  Future<SecureServerSocket> startServer(
      [address, port, ServerSettings settings]) async {
    _socket = await _serverGenerator(
        address ?? '127.0.0.1', port ?? 0, securityContext);

    _http1 = new StreamController<SecureSocket>();
    _artificial = new ArtificialServerSocket(
        _socket.address, _socket.port, _http1.stream);
    _httpServer = new HttpServer.listenOn(_artificial);
    _httpServer.pipe(_onHttp1);

    _sub = _socket.listen((socket) {
      if (socket.selectedProtocol == null ||
          socket.selectedProtocol == 'http/1.0' ||
          socket.selectedProtocol == 'http/1.1') {
        _http1.add(socket);
      } else if (socket.selectedProtocol == 'h2' ||
          socket.selectedProtocol == 'h2-14') {
        print('huh');
        var connection =
            new ServerTransportConnection.viaSocket(socket, settings: settings);
        connection.incomingStreams.listen((stream) async {
          return handleClient(stream, socket);
        });
      } else {
        socket.destroy();
        throw new Exception('AngelHttp2 does not support ${socket
            .selectedProtocol} as an ALPN protocol.');
      }
    }, onError: (e, st) {
      app.logger.warning('HTTP/2 incoming connection failure', e, st);
    });

    return _socket;
  }

  Future handleClient(ServerTransportStream stream, SecureSocket socket) async {
    var req = await Http2RequestContextImpl.from(stream, socket, app);
    print(req.uri);
  }

  Future close() async {
    _http1.close();
    _artificial.close();
    _httpServer.close(force: true);
    _onHttp1.close();
    _sub?.cancel();
    await _socket.close();
  }
}
