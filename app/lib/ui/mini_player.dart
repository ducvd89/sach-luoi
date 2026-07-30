/// Thanh phát thu nhỏ, hiện ở các màn hình khác khi đang nghe dở.
library;

import 'package:flutter/material.dart';

import 'app_scope.dart';
import 'home_shell.dart';
import 'theme.dart';

class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final player = state.player;
    final book = state.currentBook;
    if (book == null) return const SizedBox.shrink();

    return AnimatedBuilder(
      animation: player,
      builder: (context, _) {
        final total = player.totalSeconds;
        final fraction = total > 0 ? (player.elapsedSeconds / total).clamp(0.0, 1.0) : 0.0;

        return Material(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: InkWell(
            onTap: () => HomeShellState.of(context)?.goTo(1),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                LinearProgressIndicator(value: fraction, minHeight: 2),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(book.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
                            Text(
                              player.currentChapter?.title ?? 'Đoạn ${player.index + 1}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor),
                            ),
                          ],
                        ),
                      ),
                      Text(formatTime(player.elapsedSeconds),
                          style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
                      const SizedBox(width: 8),
                      IconButton(
                        onPressed: player.previous,
                        icon: const Icon(Icons.skip_previous, size: 21),
                      ),
                      player.isLoading
                          ? const Padding(
                              padding: EdgeInsets.all(12),
                              child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                            )
                          : IconButton(
                              onPressed: player.togglePlay,
                              icon: Icon(player.isPlaying ? Icons.pause_circle : Icons.play_circle, size: 30),
                            ),
                      IconButton(
                        onPressed: player.next,
                        icon: const Icon(Icons.skip_next, size: 21),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
