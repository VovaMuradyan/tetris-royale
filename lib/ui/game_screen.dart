import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/game_engine.dart';
import '../network/game_client.dart';

const String _defaultWsUrl = String.fromEnvironment(
  'GAME_WS_URL',
  defaultValue: 'ws://10.0.2.2:8080/ws',
);

class GameScreen extends StatefulWidget {
  const GameScreen({super.key});

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen> {
  late final GameClient _client;

  @override
  void initState() {
    super.initState();
    _client = GameClient();
    _client.connect(Uri.parse(_defaultWsUrl));
  }

  @override
  void dispose() {
    _client.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xff0c1017),
      body: SafeArea(
        child: AnimatedBuilder(
          animation: _client,
          builder: (context, _) {
            final state = _client.state;
            return LayoutBuilder(
              builder: (context, constraints) {
                final availableWidth = math.max(
                  160.0,
                  constraints.maxWidth - 32,
                );
                final availableHeight = math.max(
                  320.0,
                  constraints.maxHeight - 172,
                );
                final boardWidthPx = math.min(
                  availableWidth,
                  availableHeight / 2,
                );
                final boardSize = Size(boardWidthPx, boardWidthPx * 2);

                return Column(
                  children: [
                    _Hud(
                      score: state?.score ?? 0,
                      lines: state?.lines ?? 0,
                      status: _client.statusText,
                    ),
                    Expanded(
                      child: Center(
                        child: GestureDetector(
                          onHorizontalDragEnd: (details) {
                            final velocity = details.primaryVelocity ?? 0;
                            if (velocity < -80) {
                              _client.sendAction(GameAction.left);
                            } else if (velocity > 80) {
                              _client.sendAction(GameAction.right);
                            }
                          },
                          onVerticalDragEnd: (details) {
                            final velocity = details.primaryVelocity ?? 0;
                            if (velocity > 220) {
                              _client.sendAction(GameAction.hardDrop);
                            }
                          },
                          onTap: () => _client.sendAction(GameAction.rotateCw),
                          child: SizedBox.fromSize(
                            size: boardSize,
                            child: CustomPaint(painter: BoardPainter(state)),
                          ),
                        ),
                      ),
                    ),
                    _Controls(client: _client),
                  ],
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class _Hud extends StatelessWidget {
  const _Hud({required this.score, required this.lines, required this.status});

  final int score;
  final int lines;
  final String status;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: _HudValue(label: 'SCORE', value: '$score'),
          ),
          Expanded(
            child: _HudValue(label: 'LINES', value: '$lines'),
          ),
          Expanded(
            child: _HudValue(label: 'NET', value: status.toUpperCase()),
          ),
        ],
      ),
    );
  }
}

class _HudValue extends StatelessWidget {
  const _HudValue({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: const Color(0xff7e8da5),
                letterSpacing: 0,
                fontWeight: FontWeight.w700,
              ),
        ),
        const SizedBox(height: 3),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: Colors.white,
                letterSpacing: 0,
                fontWeight: FontWeight.w800,
              ),
        ),
      ],
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls({required this.client});

  final GameClient client;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 18),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _RoundIconButton(
            icon: Icons.keyboard_arrow_left_rounded,
            label: 'Left',
            onPressed: () => client.sendAction(GameAction.left),
          ),
          _RoundIconButton(
            icon: Icons.rotate_left_rounded,
            label: 'Rotate left',
            onPressed: () => client.sendAction(GameAction.rotateCcw),
          ),
          _RoundIconButton(
            icon: Icons.rotate_right_rounded,
            label: 'Rotate right',
            onPressed: () => client.sendAction(GameAction.rotateCw),
          ),
          _RoundIconButton(
            icon: Icons.keyboard_arrow_down_rounded,
            label: 'Soft drop',
            onPressed: () => client.sendAction(GameAction.softDrop),
          ),
          _RoundIconButton(
            icon: Icons.keyboard_arrow_right_rounded,
            label: 'Right',
            onPressed: () => client.sendAction(GameAction.right),
          ),
          _RoundIconButton(
            icon: Icons.vertical_align_bottom_rounded,
            label: 'Hard drop',
            accent: const Color(0xffffd166),
            onPressed: () => client.sendAction(GameAction.hardDrop),
          ),
        ],
      ),
    );
  }
}

class _RoundIconButton extends StatelessWidget {
  const _RoundIconButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.accent = const Color(0xff00d2ff),
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: 48,
      child: Tooltip(
        message: label,
        child: IconButton.filledTonal(
          color: accent,
          icon: Icon(icon),
          onPressed: onPressed,
        ),
      ),
    );
  }
}

class BoardPainter extends CustomPainter {
  BoardPainter(this.state);

  final GameState? state;

  static const List<Color> pieceColors = [
    Color(0xff2dd4ff),
    Color(0xff4f7cff),
    Color(0xffffa24c),
    Color(0xffffdc4c),
    Color(0xff46df8f),
    Color(0xffb875ff),
    Color(0xffff5d73),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final cell = math.min(size.width / boardWidth, size.height / visibleRows);
    final boardPaint = Paint()..color = const Color(0xff111824);
    final gridPaint = Paint()
      ..color = const Color(0xff263248)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    final boardRect = RRect.fromRectAndRadius(
      Offset.zero & Size(cell * boardWidth, cell * visibleRows),
      const Radius.circular(8),
    );
    canvas.drawRRect(boardRect, boardPaint);

    for (var y = 0; y < visibleRows; y++) {
      for (var x = 0; x < boardWidth; x++) {
        _drawCell(canvas, x, y, cell, 0, gridPaint);
      }
    }

    final current = state;
    if (current == null) {
      return;
    }

    for (var y = hiddenRows; y < boardHeight; y++) {
      for (var x = 0; x < boardWidth; x++) {
        final value = current.board[y][x];
        if (value > 0) {
          _drawCell(canvas, x, y - hiddenRows, cell, value, null);
        }
      }
    }

    for (final active in current.activeCellsForPaint()) {
      final visibleY = active.y - hiddenRows;
      if (visibleY >= 0 && visibleY < visibleRows) {
        _drawCell(
          canvas,
          active.x,
          visibleY,
          cell,
          current.active.kind + 1,
          null,
        );
      }
    }

    if (current.gameOver) {
      final overlay = Paint()..color = const Color(0xaa0c1017);
      canvas.drawRRect(boardRect, overlay);
      final textPainter = TextPainter(
        text: const TextSpan(
          text: 'GAME OVER',
          style: TextStyle(
            color: Colors.white,
            fontSize: 28,
            fontWeight: FontWeight.w900,
            letterSpacing: 0,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: size.width);
      textPainter.paint(
        canvas,
        Offset(
          (size.width - textPainter.width) / 2,
          (size.height - textPainter.height) / 2,
        ),
      );
    }
  }

  void _drawCell(
    Canvas canvas,
    int x,
    int y,
    double cell,
    int value,
    Paint? strokePaint,
  ) {
    final rect = Rect.fromLTWH(x * cell + 1, y * cell + 1, cell - 2, cell - 2);
    if (value <= 0) {
      if (strokePaint != null) {
        canvas.drawRect(rect, strokePaint);
      }
      return;
    }
    final color = pieceColors[(value - 1) % pieceColors.length];
    final fill = Paint()..color = color;
    final shine = Paint()..color = Colors.white.withValues(alpha: 0.16);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(5)),
      fill,
    );
    canvas.drawRect(
      Rect.fromLTWH(rect.left + 3, rect.top + 3, rect.width - 6, 2),
      shine,
    );
  }

  @override
  bool shouldRepaint(covariant BoardPainter oldDelegate) {
    return oldDelegate.state != state;
  }
}
