import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:msgpack_dart/msgpack_dart.dart' as msgpack;
import 'package:web_socket_channel/status.dart' as status;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../core/game_engine.dart';

class GameClient extends ChangeNotifier {
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _tickTimer;
  final List<ClientInput> _pendingInputs = <ClientInput>[];

  GameState? _state;
  int _seq = 0;
  int _serverTick = 0;
  bool _connected = false;
  String _statusText = 'connecting';
  DateTime? _lastResyncAt;

  GameState? get state => _state;
  bool get connected => _connected;
  String get statusText => _statusText;
  DateTime? get lastResyncAt => _lastResyncAt;

  Future<void> connect(Uri uri) async {
    await disconnect();
    _statusText = 'connecting';
    notifyListeners();

    final channel = WebSocketChannel.connect(uri);
    _channel = channel;
    await channel.ready;
    _connected = true;
    _statusText = 'online';

    _subscription = channel.stream.listen(
      _handleMessage,
      onError: (Object error) {
        _connected = false;
        _statusText = 'network_error';
        notifyListeners();
      },
      onDone: () {
        _connected = false;
        _statusText = channel.closeReason ?? 'offline';
        notifyListeners();
      },
    );

    _tickTimer = Timer.periodic(
      const Duration(microseconds: 1000000 ~/ tickRate),
      (_) => _predictTick(),
    );
    notifyListeners();
  }

  Future<void> disconnect({String reason = 'client_closed'}) async {
    _tickTimer?.cancel();
    _tickTimer = null;
    await _subscription?.cancel();
    _subscription = null;
    final channel = _channel;
    _channel = null;
    if (channel != null) {
      await channel.sink.close(status.normalClosure, reason);
    }
    _connected = false;
  }

  void sendAction(GameAction action) {
    final current = _state;
    final channel = _channel;
    if (current == null || channel == null || !_connected) {
      return;
    }

    final targetTick =
        (_serverTick > current.tick ? _serverTick : current.tick) +
            inputDelayTicks;
    final input = ClientInput(
      tick: targetTick,
      seq: ++_seq,
      action: action,
      hash: current.merkleHashHex(),
    );
    _pendingInputs.add(input);

    channel.sink.add(
      msgpack.serialize(<String, Object>{
        't': 'input',
        'tick': input.tick,
        'seq': input.seq,
        'action': input.action.index,
        'hash': input.hash,
      }),
    );

    _state = current.applyInput(input);
    notifyListeners();
  }

  void _predictTick() {
    final current = _state;
    if (current == null) {
      return;
    }
    _state = current.step(const <ClientInput>[]);
    notifyListeners();
  }

  void _handleMessage(dynamic message) {
    final bytes = _messageBytes(message);
    if (bytes == null) {
      return;
    }
    final decoded = msgpack.deserialize(bytes);
    if (decoded is! Map) {
      return;
    }
    final type = decoded['t']?.toString();
    if (type == 'hello') {
      _serverTick = 0;
      _statusText = 'online';
      notifyListeners();
      return;
    }
    if (type != 'state') {
      return;
    }

    final statePayload = decoded['state'];
    if (statePayload is! Map) {
      return;
    }

    final serverState = GameState.fromSnapshot(statePayload);
    final serverHash = serverState.serverHash;
    if (serverHash.isNotEmpty && serverHash != serverState.merkleHashHex()) {
      _statusText = 'cheat_detected';
      unawaited(disconnect(reason: 'cheat_detected'));
      notifyListeners();
      return;
    }

    _serverTick = serverState.tick;
    final local = _state;
    final localTick = local?.tick ?? serverState.tick;
    final localMismatch = local != null &&
        local.tick == serverState.tick &&
        local.merkleHashHex() != serverHash;

    _pendingInputs.removeWhere((input) => input.tick <= serverState.tick);
    var reconciled = serverState.copyWith(serverHash: '');
    for (final input in _pendingInputs) {
      reconciled = reconciled.applyInput(input);
    }
    while (reconciled.tick < localTick) {
      reconciled = reconciled.step(const <ClientInput>[]);
    }

    if (localMismatch) {
      _lastResyncAt = DateTime.now();
    }
    _state = reconciled;
    _statusText = localMismatch ? 'resynced' : 'online';
    notifyListeners();
  }

  Uint8List? _messageBytes(dynamic message) {
    if (message is Uint8List) {
      return message;
    }
    if (message is List<int>) {
      return Uint8List.fromList(message);
    }
    return null;
  }

  @override
  void dispose() {
    unawaited(disconnect());
    super.dispose();
  }
}
