import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:angel_framework/angel_framework.dart';
import 'package:body_parser/body_parser.dart';
import 'package:http2/transport.dart';
import 'package:mock_request/mock_request.dart';

class Http2RequestContextImpl extends RequestContext {
  // TODO: Make this immutable
  final List<Cookie> cookies = [];
  BytesBuilder _buf;
  HttpHeaders _headers;
  String _method, _override, _path;
  HttpSession _session;
  Socket _socket;
  ServerTransportStream _stream;
  Uri _uri;

  static Future<Http2RequestContextImpl> from(
      ServerTransportStream stream, Socket socket, Angel app) async {
    var req = new Http2RequestContextImpl()
      .._socket = socket
      .._stream = stream;

    var buf = req._buf = new BytesBuilder();
    var headers = req._headers = new MockHttpHeaders();
    var uri = req._uri =
        Uri.parse('https://${socket.address.address}:${socket.port}');

    await for (var msg in stream.incomingMessages) {
      if (msg is DataStreamMessage) {
        buf.add(msg.bytes);
      } else if (msg is HeadersStreamMessage) {
        for (var header in msg.headers) {
          var name = ASCII.decode(header.name).toLowerCase();
          var value = ASCII.decode(header.value);

          switch (name) {
            case ':method':
              req._method = value;
              break;
            case ':path':
              uri = uri.replace(path: value);
              break;
            case ':scheme':
              uri = uri.replace(scheme: value);
              break;
            case ':authority':
              var authorityUri = Uri.parse(value);
              uri = uri.replace(
                host: authorityUri.host,
                port: authorityUri.port,
                userInfo: authorityUri.userInfo,
              );
              break;
            default:
              headers.add(ASCII.decode(header.name), value);
              break;
          }
        }
      }

      if (msg.endStream) break;
    }

    return req;
  }

  /// The underlying HTTP/2 [ServerTransportStream].
  ServerTransportStream get stream => _stream;

  @override
  bool get xhr {
    return headers.value("X-Requested-With")?.trim()?.toLowerCase() ==
        'xmlhttprequest';
  }

  @override
  Uri get uri => _uri;

  @override
  HttpSession get session {
    // TODO: Real session, stored in memory via MapService?
    return _session;
  }

  @override
  InternetAddress get remoteAddress => _socket.remoteAddress;

  @override
  String get path {
    // TODO: Get normalized path
    return _path;
  }

  @override
  ContentType get contentType => headers.contentType;

  @override
  String get originalMethod {
    return _method;
  }

  @override
  String get method {
    return _override ?? _method;
  }

  @override
  HttpRequest get io => null;

  @override
  String get hostname => _headers.value('host');

  @override
  HttpHeaders get headers => _headers;

  @override
  Future<BodyParseResult> parseOnce() {
    return null;
  }

  @override
  Future close() {
    return super.close();
  }
}
