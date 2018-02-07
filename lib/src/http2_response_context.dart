import 'dart:async';
import 'dart:io';
import 'package:angel_framework/angel_framework.dart';
import 'package:http2/transport.dart';
import 'http2_request_context.dart';

class Http2ResponseContextImpl extends ResponseContext {
  final Angel app;
  final ServerTransportStream stream;
  final Http2RequestContextImpl _req;
  bool _useStream = false, _isClosed = false;

  Http2ResponseContextImpl(this.app, this.stream, this._req);

  @override
  RequestContext get correspondingRequest => _req;

  @override
  void add(List<int> event) {
    stream.sendData(event);
  }

  @override
  Future addStream(Stream<List<int>> stream) {

  }

  @override
  bool useStream() {
    // TODO:
  }

  @override
  HttpResponse get io => null;

  @override
  bool get streaming => _useStream;

  @override
  bool get isOpen => _!isClosed;
}