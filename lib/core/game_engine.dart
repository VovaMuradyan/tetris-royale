import 'dart:typed_data';

const int boardWidth = 10;
const int visibleRows = 20;
const int hiddenRows = 2;
const int boardHeight = visibleRows + hiddenRows;
const int tickRate = 60;
const int inputDelayTicks = 2;
const int fixedShift = 16;
const int fixedOne = 1 << fixedShift;
const int gravityBaseTicks = 48;
const int minGravityTicks = 4;
const int lockDelayTicks = 30;
const int queueCap = 32;

enum GameAction { none, left, right, rotateCw, rotateCcw, softDrop, hardDrop }

GameAction actionFromCode(int code) {
  if (code < 0 || code >= GameAction.values.length) {
    return GameAction.none;
  }
  return GameAction.values[code];
}

class ClientInput {
  const ClientInput({
    required this.tick,
    required this.seq,
    required this.action,
    this.hash = '',
  });

  final int tick;
  final int seq;
  final GameAction action;
  final String hash;
}

class ActivePiece {
  const ActivePiece({
    required this.kind,
    required this.rotation,
    required this.x,
    required this.y,
  });

  final int kind;
  final int rotation;
  final int x;
  final int y;

  ActivePiece copyWith({int? kind, int? rotation, int? x, int? y}) {
    return ActivePiece(
      kind: kind ?? this.kind,
      rotation: rotation ?? this.rotation,
      x: x ?? this.x,
      y: y ?? this.y,
    );
  }
}

class GameState {
  GameState({
    required this.tick,
    required this.board,
    required this.active,
    required this.queue,
    required this.rng,
    required this.gravityAcc,
    required this.lockTicks,
    required this.lines,
    required this.score,
    required this.gameOver,
    this.serverHash = '',
  });

  factory GameState.newGame(int seed) {
    var state = GameState(
      tick: 0,
      board: _emptyBoard(),
      active: const ActivePiece(kind: 0, rotation: 0, x: 3 * fixedOne, y: 0),
      queue: const [],
      rng: _normalizeSeed(seed),
      gravityAcc: 0,
      lockTicks: 0,
      lines: 0,
      score: 0,
      gameOver: false,
    );
    state = state._ensureQueue(7);
    return state._spawnNext();
  }

  factory GameState.fromSnapshot(Map<dynamic, dynamic> snapshot) {
    final activeMap = snapshot['active'] as Map<dynamic, dynamic>;
    return GameState(
      tick: _asInt(snapshot['tick']),
      board: _decodeBoard(snapshot['board']),
      active: ActivePiece(
        kind: _asInt(activeMap['kind']),
        rotation: _asInt(activeMap['rotation']),
        x: _asInt(activeMap['x']),
        y: _asInt(activeMap['y']),
      ),
      queue: _decodeIntList(snapshot['queue']),
      rng: _asInt(snapshot['rng']),
      gravityAcc: _asInt(snapshot['gravity_acc']),
      lockTicks: _asInt(snapshot['lock_ticks']),
      lines: _asInt(snapshot['lines']),
      score: _asInt(snapshot['score']),
      gameOver: snapshot['game_over'] == true,
      serverHash: (snapshot['hash'] ?? '').toString(),
    );
  }

  final int tick;
  final List<List<int>> board;
  final ActivePiece active;
  final List<int> queue;
  final int rng;
  final int gravityAcc;
  final int lockTicks;
  final int lines;
  final int score;
  final bool gameOver;
  final String serverHash;

  GameState copyWith({
    int? tick,
    List<List<int>>? board,
    ActivePiece? active,
    List<int>? queue,
    int? rng,
    int? gravityAcc,
    int? lockTicks,
    int? lines,
    int? score,
    bool? gameOver,
    String? serverHash,
  }) {
    return GameState(
      tick: tick ?? this.tick,
      board: board ?? _cloneBoard(this.board),
      active: active ?? this.active,
      queue: queue ?? List<int>.from(this.queue),
      rng: rng ?? this.rng,
      gravityAcc: gravityAcc ?? this.gravityAcc,
      lockTicks: lockTicks ?? this.lockTicks,
      lines: lines ?? this.lines,
      score: score ?? this.score,
      gameOver: gameOver ?? this.gameOver,
      serverHash: serverHash ?? this.serverHash,
    );
  }

  GameState step(List<ClientInput> inputs) {
    var state = copyWith();
    final ordered = List<ClientInput>.from(inputs)
      ..sort((a, b) {
        final tickCompare = a.tick.compareTo(b.tick);
        if (tickCompare != 0) {
          return tickCompare;
        }
        return a.seq.compareTo(b.seq);
      });
    for (final input in ordered) {
      state = state.applyInput(input);
    }
    state = state._advanceGravity();
    return state.copyWith(tick: state.tick + 1, serverHash: '');
  }

  GameState applyInput(ClientInput input) {
    if (gameOver) {
      return this;
    }
    switch (input.action) {
      case GameAction.left:
        return _move(-1, 0);
      case GameAction.right:
        return _move(1, 0);
      case GameAction.rotateCw:
        return _rotate(1);
      case GameAction.rotateCcw:
        return _rotate(-1);
      case GameAction.softDrop:
        final next = _tryMove(0, 1);
        if (next == null) {
          return this;
        }
        return next.copyWith(score: next.score + 1);
      case GameAction.hardDrop:
        return _hardDrop();
      case GameAction.none:
        return this;
    }
  }

  Iterable<CellPoint> activeCellsForPaint() sync* {
    for (final cell in _activeCells(active)) {
      yield cell;
    }
  }

  String merkleHashHex() {
    final leaves = <BigInt>[];
    for (var y = 0; y < boardHeight; y++) {
      var h = _fnvOffset;
      h = _mixByte(h, y);
      for (var x = 0; x < boardWidth; x++) {
        h = _mixByte(h, board[y][x]);
      }
      leaves.add(h);
    }

    var meta = _fnvOffset;
    meta = _mixU64(meta, tick);
    meta = _mixByte(meta, active.kind);
    meta = _mixByte(meta, active.rotation);
    meta = _mixU64(meta, active.x);
    meta = _mixU64(meta, active.y);
    meta = _mixU64(meta, lines);
    meta = _mixU64(meta, score);
    meta = _mixU64(meta, rng);
    meta = _mixU64(meta, gravityAcc);
    meta = _mixU64(meta, lockTicks);
    meta = _mixU64(meta, queue.length);
    for (final piece in queue) {
      meta = _mixByte(meta, piece);
    }
    meta = _mixByte(meta, gameOver ? 1 : 0);
    leaves.add(meta);

    var level = leaves;
    while (level.length > 1) {
      final next = <BigInt>[];
      for (var i = 0; i < level.length; i += 2) {
        final left = level[i];
        final right = i + 1 < level.length ? level[i + 1] : left;
        var parent = _fnvOffset;
        parent = _mixU64Big(parent, left);
        parent = _mixU64Big(parent, right);
        next.add(parent);
      }
      level = next;
    }
    return level.single.toRadixString(16).padLeft(16, '0');
  }

  int gravityInterval() {
    final level = lines ~/ 10;
    final interval = gravityBaseTicks - level * 4;
    return interval < minGravityTicks ? minGravityTicks : interval;
  }

  GameState _move(int dx, int dy) {
    final next = _tryMove(dx, dy);
    if (next == null) {
      return this;
    }
    if (next._grounded()) {
      return next.copyWith(lockTicks: 0);
    }
    return next;
  }

  GameState? _tryMove(int dx, int dy) {
    final moved = active.copyWith(
      x: active.x + dx * fixedOne,
      y: active.y + dy * fixedOne,
    );
    if (_collides(moved)) {
      return null;
    }
    return copyWith(active: moved);
  }

  GameState _rotate(int dir) {
    if (active.kind == 3) {
      return copyWith(
        active: active.copyWith(rotation: (active.rotation + dir + 4) % 4),
      );
    }
    final from = active.rotation & 3;
    final to = (from + dir + 4) % 4;
    for (final kick in _kicks(active.kind, from, to)) {
      final rotated = active.copyWith(
        rotation: to,
        x: active.x + kick.x * fixedOne,
        y: active.y + kick.y * fixedOne,
      );
      if (!_collides(rotated)) {
        final next = copyWith(active: rotated);
        if (next._grounded()) {
          return next.copyWith(lockTicks: 0);
        }
        return next;
      }
    }
    return this;
  }

  GameState _hardDrop() {
    var state = this;
    var dropped = 0;
    while (true) {
      final next = state._tryMove(0, 1);
      if (next == null) {
        break;
      }
      dropped++;
      state = next;
    }
    return state.copyWith(score: state.score + dropped * 2)._lockPiece();
  }

  GameState _advanceGravity() {
    if (gameOver) {
      return this;
    }

    var state = copyWith(gravityAcc: gravityAcc + 1);
    var movedByGravity = false;
    if (state.gravityAcc >= state.gravityInterval()) {
      final moved = state._tryMove(0, 1);
      state = state.copyWith(gravityAcc: 0);
      if (moved != null) {
        state = moved.copyWith(gravityAcc: 0);
        movedByGravity = true;
      }
    }

    if (state._grounded()) {
      if (!movedByGravity) {
        state = state.copyWith(lockTicks: state.lockTicks + 1);
      }
      if (state.lockTicks >= lockDelayTicks) {
        return state._lockPiece();
      }
    } else {
      state = state.copyWith(lockTicks: 0);
    }
    return state;
  }

  bool _grounded() {
    return _collides(active.copyWith(y: active.y + fixedOne));
  }

  GameState _lockPiece() {
    if (gameOver) {
      return this;
    }

    final nextBoard = _cloneBoard(board);
    for (final cell in _activeCells(active)) {
      if (cell.y < 0 ||
          cell.y >= boardHeight ||
          cell.x < 0 ||
          cell.x >= boardWidth) {
        return copyWith(gameOver: true);
      }
      nextBoard[cell.y][cell.x] = active.kind + 1;
    }

    var state = copyWith(board: nextBoard, lockTicks: 0, gravityAcc: 0);
    state = state._clearLines();
    return state._spawnNext();
  }

  GameState _clearLines() {
    final next = _emptyBoard();
    var writeY = boardHeight - 1;
    var cleared = 0;

    for (var y = boardHeight - 1; y >= 0; y--) {
      var full = true;
      for (var x = 0; x < boardWidth; x++) {
        if (board[y][x] == 0) {
          full = false;
          break;
        }
      }
      if (full) {
        cleared++;
        continue;
      }
      next[writeY] = List<int>.from(board[y]);
      writeY--;
    }

    if (cleared == 0) {
      return copyWith(board: next);
    }
    final scoreTable = <int>[0, 100, 300, 500, 800];
    final safeCleared = cleared > 4 ? 4 : cleared;
    final level = lines ~/ 10 + 1;
    return copyWith(
      board: next,
      lines: lines + cleared,
      score: score + scoreTable[safeCleared] * level,
    );
  }

  GameState _spawnNext() {
    var state = _ensureQueue(7);
    final nextQueue = List<int>.from(state.queue);
    final piece = nextQueue.removeAt(0);
    state = state.copyWith(
      queue: nextQueue,
      active: ActivePiece(kind: piece, rotation: 0, x: 3 * fixedOne, y: 0),
    );
    if (state._collides(state.active)) {
      state = state.copyWith(gameOver: true);
    }
    return state._ensureQueue(7);
  }

  GameState _ensureQueue(int min) {
    var state = this;
    while (state.queue.length < min) {
      state = state._appendBag();
    }
    return state;
  }

  GameState _appendBag() {
    final bag = <int>[0, 1, 2, 3, 4, 5, 6];
    var nextRng = rng;
    for (var i = bag.length - 1; i > 0; i--) {
      nextRng = _nextRand(nextRng);
      final j = nextRng % (i + 1);
      final tmp = bag[i];
      bag[i] = bag[j];
      bag[j] = tmp;
    }
    final nextQueue = <int>[...queue, ...bag];
    if (nextQueue.length > queueCap) {
      nextQueue.removeRange(queueCap, nextQueue.length);
    }
    return copyWith(rng: nextRng, queue: nextQueue);
  }

  bool _collides(ActivePiece candidate) {
    if (candidate.kind < 0 || candidate.kind > 6) {
      return true;
    }
    for (final cell in _activeCells(candidate)) {
      if (cell.x < 0 || cell.x >= boardWidth || cell.y >= boardHeight) {
        return true;
      }
      if (cell.y >= 0 && board[cell.y][cell.x] != 0) {
        return true;
      }
    }
    return false;
  }
}

class CellPoint {
  const CellPoint(this.x, this.y);

  final int x;
  final int y;
}

List<CellPoint> _activeCells(ActivePiece active) {
  final baseX = active.x ~/ fixedOne;
  final baseY = active.y ~/ fixedOne;
  final cells = _pieceCells[active.kind][active.rotation & 3];
  return [for (final cell in cells) CellPoint(baseX + cell.x, baseY + cell.y)];
}

List<CellPoint> _kicks(int piece, int from, int to) {
  final key = (from & 3) * 4 + (to & 3);
  if (piece == 0) {
    return _iKicks[key]!;
  }
  return _normalKicks[key]!;
}

List<List<int>> _emptyBoard() {
  return List<List<int>>.generate(
    boardHeight,
    (_) => List<int>.filled(boardWidth, 0),
  );
}

List<List<int>> _cloneBoard(List<List<int>> board) {
  return [for (final row in board) List<int>.from(row)];
}

List<List<int>> _decodeBoard(dynamic value) {
  final rows = <List<int>>[];
  if (value is Iterable) {
    for (final row in value) {
      if (row is Uint8List) {
        rows.add(_normalizeRow(row.toList()));
      } else if (row is Iterable) {
        rows.add(_normalizeRow([for (final cell in row) _asInt(cell)]));
      }
    }
  }
  while (rows.length < boardHeight) {
    rows.add(List<int>.filled(boardWidth, 0));
  }
  return rows.take(boardHeight).toList();
}

List<int> _normalizeRow(List<int> row) {
  final next = List<int>.filled(boardWidth, 0);
  for (var i = 0; i < boardWidth && i < row.length; i++) {
    next[i] = row[i];
  }
  return next;
}

List<int> _decodeIntList(dynamic value) {
  if (value is Uint8List) {
    return value.toList();
  }
  if (value is Iterable) {
    return [for (final item in value) _asInt(item)];
  }
  return const [];
}

int _asInt(dynamic value) {
  if (value is int) {
    return value;
  }
  if (value is BigInt) {
    return value.toInt();
  }
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

int _normalizeSeed(int seed) {
  if (seed == 0) {
    return 0x9e3779b97f4a7c15;
  }
  return seed & _mask64Int;
}

int _nextRand(int x) {
  var next = _normalizeSeed(x);
  next = (next ^ ((next << 13) & _mask64Int)) & _mask64Int;
  next = (next ^ (next >> 7)) & _mask64Int;
  next = (next ^ ((next << 17) & _mask64Int)) & _mask64Int;
  return _normalizeSeed(next);
}

const int _mask64Int = 0xffffffffffffffff;
final BigInt _mask64 = BigInt.parse('ffffffffffffffff', radix: 16);
final BigInt _fnvOffset = BigInt.parse('14695981039346656037');
final BigInt _fnvPrime = BigInt.parse('1099511628211');

BigInt _mixByte(BigInt h, int b) {
  final mixed = h ^ BigInt.from(b & 0xff);
  return (mixed * _fnvPrime) & _mask64;
}

BigInt _mixU64(BigInt h, int value) {
  var v = BigInt.from(value);
  if (value < 0) {
    v += BigInt.one << 64;
  }
  return _mixU64Big(h, v);
}

BigInt _mixU64Big(BigInt h, BigInt value) {
  var next = h;
  final v = value & _mask64;
  for (var i = 0; i < 8; i++) {
    final byte = ((v >> (8 * i)) & BigInt.from(0xff)).toInt();
    next = _mixByte(next, byte);
  }
  return next;
}

const List<List<List<CellPoint>>> _pieceCells = [
  [
    [CellPoint(0, 1), CellPoint(1, 1), CellPoint(2, 1), CellPoint(3, 1)],
    [CellPoint(2, 0), CellPoint(2, 1), CellPoint(2, 2), CellPoint(2, 3)],
    [CellPoint(0, 2), CellPoint(1, 2), CellPoint(2, 2), CellPoint(3, 2)],
    [CellPoint(1, 0), CellPoint(1, 1), CellPoint(1, 2), CellPoint(1, 3)],
  ],
  [
    [CellPoint(0, 0), CellPoint(0, 1), CellPoint(1, 1), CellPoint(2, 1)],
    [CellPoint(1, 0), CellPoint(2, 0), CellPoint(1, 1), CellPoint(1, 2)],
    [CellPoint(0, 1), CellPoint(1, 1), CellPoint(2, 1), CellPoint(2, 2)],
    [CellPoint(1, 0), CellPoint(1, 1), CellPoint(0, 2), CellPoint(1, 2)],
  ],
  [
    [CellPoint(2, 0), CellPoint(0, 1), CellPoint(1, 1), CellPoint(2, 1)],
    [CellPoint(1, 0), CellPoint(1, 1), CellPoint(1, 2), CellPoint(2, 2)],
    [CellPoint(0, 1), CellPoint(1, 1), CellPoint(2, 1), CellPoint(0, 2)],
    [CellPoint(0, 0), CellPoint(1, 0), CellPoint(1, 1), CellPoint(1, 2)],
  ],
  [
    [CellPoint(1, 0), CellPoint(2, 0), CellPoint(1, 1), CellPoint(2, 1)],
    [CellPoint(1, 0), CellPoint(2, 0), CellPoint(1, 1), CellPoint(2, 1)],
    [CellPoint(1, 0), CellPoint(2, 0), CellPoint(1, 1), CellPoint(2, 1)],
    [CellPoint(1, 0), CellPoint(2, 0), CellPoint(1, 1), CellPoint(2, 1)],
  ],
  [
    [CellPoint(1, 0), CellPoint(2, 0), CellPoint(0, 1), CellPoint(1, 1)],
    [CellPoint(1, 0), CellPoint(1, 1), CellPoint(2, 1), CellPoint(2, 2)],
    [CellPoint(1, 1), CellPoint(2, 1), CellPoint(0, 2), CellPoint(1, 2)],
    [CellPoint(0, 0), CellPoint(0, 1), CellPoint(1, 1), CellPoint(1, 2)],
  ],
  [
    [CellPoint(1, 0), CellPoint(0, 1), CellPoint(1, 1), CellPoint(2, 1)],
    [CellPoint(1, 0), CellPoint(1, 1), CellPoint(2, 1), CellPoint(1, 2)],
    [CellPoint(0, 1), CellPoint(1, 1), CellPoint(2, 1), CellPoint(1, 2)],
    [CellPoint(1, 0), CellPoint(0, 1), CellPoint(1, 1), CellPoint(1, 2)],
  ],
  [
    [CellPoint(0, 0), CellPoint(1, 0), CellPoint(1, 1), CellPoint(2, 1)],
    [CellPoint(2, 0), CellPoint(1, 1), CellPoint(2, 1), CellPoint(1, 2)],
    [CellPoint(0, 1), CellPoint(1, 1), CellPoint(1, 2), CellPoint(2, 2)],
    [CellPoint(1, 0), CellPoint(0, 1), CellPoint(1, 1), CellPoint(0, 2)],
  ],
];

const Map<int, List<CellPoint>> _normalKicks = {
  1: [
    CellPoint(0, 0),
    CellPoint(-1, 0),
    CellPoint(-1, -1),
    CellPoint(0, 2),
    CellPoint(-1, 2),
  ],
  4: [
    CellPoint(0, 0),
    CellPoint(1, 0),
    CellPoint(1, 1),
    CellPoint(0, -2),
    CellPoint(1, -2),
  ],
  6: [
    CellPoint(0, 0),
    CellPoint(1, 0),
    CellPoint(1, 1),
    CellPoint(0, -2),
    CellPoint(1, -2),
  ],
  9: [
    CellPoint(0, 0),
    CellPoint(-1, 0),
    CellPoint(-1, -1),
    CellPoint(0, 2),
    CellPoint(-1, 2),
  ],
  11: [
    CellPoint(0, 0),
    CellPoint(1, 0),
    CellPoint(1, -1),
    CellPoint(0, 2),
    CellPoint(1, 2),
  ],
  14: [
    CellPoint(0, 0),
    CellPoint(-1, 0),
    CellPoint(-1, 1),
    CellPoint(0, -2),
    CellPoint(-1, -2),
  ],
  12: [
    CellPoint(0, 0),
    CellPoint(-1, 0),
    CellPoint(-1, 1),
    CellPoint(0, -2),
    CellPoint(-1, -2),
  ],
  3: [
    CellPoint(0, 0),
    CellPoint(1, 0),
    CellPoint(1, -1),
    CellPoint(0, 2),
    CellPoint(1, 2),
  ],
};

const Map<int, List<CellPoint>> _iKicks = {
  1: [
    CellPoint(0, 0),
    CellPoint(-2, 0),
    CellPoint(1, 0),
    CellPoint(-2, -1),
    CellPoint(1, 2),
  ],
  4: [
    CellPoint(0, 0),
    CellPoint(2, 0),
    CellPoint(-1, 0),
    CellPoint(2, 1),
    CellPoint(-1, -2),
  ],
  6: [
    CellPoint(0, 0),
    CellPoint(-1, 0),
    CellPoint(2, 0),
    CellPoint(-1, 2),
    CellPoint(2, -1),
  ],
  9: [
    CellPoint(0, 0),
    CellPoint(1, 0),
    CellPoint(-2, 0),
    CellPoint(1, -2),
    CellPoint(-2, 1),
  ],
  11: [
    CellPoint(0, 0),
    CellPoint(2, 0),
    CellPoint(-1, 0),
    CellPoint(2, 1),
    CellPoint(-1, -2),
  ],
  14: [
    CellPoint(0, 0),
    CellPoint(-2, 0),
    CellPoint(1, 0),
    CellPoint(-2, -1),
    CellPoint(1, 2),
  ],
  12: [
    CellPoint(0, 0),
    CellPoint(1, 0),
    CellPoint(-2, 0),
    CellPoint(1, -2),
    CellPoint(-2, 1),
  ],
  3: [
    CellPoint(0, 0),
    CellPoint(-1, 0),
    CellPoint(2, 0),
    CellPoint(-1, 2),
    CellPoint(2, -1),
  ],
};
