import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:angel_framework/angel_framework.dart' hide Header;
import 'package:combinator/combinator.dart';
import 'package:http2/src/artificial_server_socket.dart';
import 'package:http2/transport.dart';
import 'http2_request_context.dart';
import 'http2_response_context.dart';
import 'package:pool/pool.dart';
import 'package:tuple/tuple.dart';

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
    var res = new Http2ResponseContextImpl(app, stream, req);

    try {
      var path = req.path;
      if (path == '/') path = '';

      Tuple3<List, Map, ParseResult<Map<String, String>>> resolveTuple() {
        Router r = app.optimizedRouter;
        var resolved =
            r.resolveAbsolute(path, method: req.method, strip: false);

        return new Tuple3(
          new MiddlewarePipeline(resolved).handlers,
          resolved.fold<Map>({}, (out, r) => out..addAll(r.allParams)),
          resolved.isEmpty ? null : resolved.first.parseResult,
        );
      }

      var cacheKey = req.method + path;
      var tuple = app.isProduction
          ? app.handlerCache.putIfAbsent(cacheKey, resolveTuple)
          : resolveTuple();

      //req.inject(Zone, zone);
      //req.inject(ZoneSpecification, zoneSpec);
      req.params.addAll(tuple.item2);
      req.inject(ParseResult, tuple.item3);

      if (app.logger != null) req.inject(Stopwatch, new Stopwatch()..start());

      var pipeline = tuple.item1;

      for (var handler in pipeline) {
        try {
          if (handler == null || !await app.executeHandler(handler, req, res))
            break;
        } on AngelHttpException catch (e, st) {
          e.stackTrace ??= st;
          return await handleAngelHttpException(e, st, req, res, stream);
        }
      }

      try {
        await sendResponse(stream, req, res);
      } on AngelHttpException catch (e, st) {
        e.stackTrace ??= st;
        return await handleAngelHttpException(
          e,
          st,
          req,
          res,
          stream,
          ignoreFinalizers: true,
        );
      }
    } on FormatException catch (error, stackTrace) {
      var e = new AngelHttpException.badRequest(message: error.message);

      if (app.logger != null) {
        app.logger.severe(e.message ?? e.toString(), error, stackTrace);
      }

      return await handleAngelHttpException(e, stackTrace, req, res, stream);
    } catch (error, stackTrace) {
      var e = new AngelHttpException(error,
          stackTrace: stackTrace, message: error?.toString());

      if (app.logger != null) {
        app.logger.severe(e.message ?? e.toString(), error, stackTrace);
      }

      return await handleAngelHttpException(e, stackTrace, req, res, stream);
    } finally {
      res.dispose();
    }
  }

  /// Handles an [AngelHttpException].
  Future handleAngelHttpException(
      AngelHttpException e,
      StackTrace st,
      Http2RequestContextImpl req,
      Http2ResponseContextImpl res,
      ServerTransportStream stream,
      {bool ignoreFinalizers: false}) async {
    if (req == null || res == null) {
      try {
        app.logger?.severe(e, st);

        stream
          ..sendHeaders([
            new Header.ascii(':status', '500'),
            new Header.ascii('content-type', 'text/plain; charset=utf8'),
          ])
          ..sendData(UTF8.encode('500 Internal Server Error'));
        await stream.outgoingMessages.close();
      } finally {
        return null;
      }
    }

    if (res.isOpen) {
      res.statusCode = e.statusCode;
      var result = await app.errorHandler(e, req, res);
      await app.executeHandler(result, req, res);
      res.end();
    }

    return await sendResponse(stream, req, res,
        ignoreFinalizers: ignoreFinalizers == true);
  }

  /// Sends a response.
  Future sendResponse(ServerTransportStream stream, Http2RequestContextImpl req,
      Http2ResponseContextImpl res,
      {bool ignoreFinalizers: false}) {
    if (res.willCloseItself) return new Future.value();

    Future finalizers = ignoreFinalizers == true
        ? new Future.value()
        : app.responseFinalizers.fold<Future>(
            new Future.value(), (out, f) => out.then((_) => f(req, res)));

    if (res.isOpen) res.end();

    var headers = <Header>[];
    res.finalize();

    headers.add(
      new Header.ascii('content-length', res.buffer.length.toString()),
    );

    // TODO: Support chunked transfer encoding in HTTP/2?
    // request.response.headers.chunkedTransferEncoding = res.chunked ?? true;

    List<int> outputBuffer = res.buffer.toBytes();

    if (res.encoders.isNotEmpty) {
      var allowedEncodings =
          req.headers[HttpHeaders.ACCEPT_ENCODING]?.map((str) {
        // Ignore quality specifications in accept-encoding
        // ex. gzip;q=0.8
        if (!str.contains(';')) return str;
        return str.split(';')[0];
      });

      if (allowedEncodings != null) {
        for (var encodingName in allowedEncodings) {
          Converter<List<int>, List<int>> encoder;
          String key = encodingName;

          if (res.encoders.containsKey(encodingName))
            encoder = res.encoders[encodingName];
          else if (encodingName == '*') {
            encoder = res.encoders[key = res.encoders.keys.first];
          }

          if (encoder != null) {
            outputBuffer = res.encoders[key].convert(outputBuffer);
            headers.addAll([
              new Header.ascii('content-encoding', key),
              new Header.ascii(
                  'content-length', outputBuffer.length.toString()),
            ]);
            break;
          }
        }
      }
    }

    stream
      ..sendHeaders(headers)
      ..sendData(res.buffer.takeBytes());

    return finalizers.then((_) async {
      await stream.outgoingMessages.close();

      if (req.injections.containsKey(PoolResource)) {
        req.injections[PoolResource].release();
      }

      if (app.logger != null) {
        var sw = req.grab<Stopwatch>(Stopwatch);

        if (sw.isRunning) {
          sw?.stop();
          app.logger.info("${res.statusCode} ${req.method} ${req.uri} (${sw
              ?.elapsedMilliseconds ?? 'unknown'} ms)");
        }
      }

      // Close all pushes
      for (var push in res.pushes) {
        await sendResponse(push.stream, req, push);
      }
    });
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
