import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:duanju_app/app_layout.dart';
import 'package:duanju_app/episode_swipe_surface.dart';
import 'package:duanju_app/player_interactions.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

import 'player_fixtures.dart';

void main() {
  testWidgets(
    'portrait edges switch episodes with drag, commit and rebound; never change brightness or media volume',
    (tester) async {
      tester.view.physicalSize = const Size(390, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final methods = <String>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(AppDevice.channel, (call) async {
        methods.add(call.method);
        return .5;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(AppDevice.channel, null),
      );
      final platform = ScriptedPlayer();
      final player = Player(platformPlayer: platform);
      await player.open(Media('https://synthetic.test/video.mp4'));
      final directions = <int>[];
      final pending = Completer<void>();
      final interactions = PlayerInteractions(
        player: player,
        available: () => true,
        baseSpeed: () => 1,
        onTogglePlayback: () {},
        onFullscreen: () {},
        onEpisode: (_) => '',
        onEpisodeSwipe: (direction) async {
          directions.add(direction);
          await pending.future;
        },
      );
      await tester.pump();
      await tester.pumpWidget(
        MaterialApp(
          home: EpisodeSwipeSurface(
            enabled: true,
            interactions: interactions,
            previousLabel: '第 1 集',
            nextLabel: '第 3 集',
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: (e) => interactions.pointerDown(
                e,
                swipeEnabled: true,
                fullscreen: false,
                width: 390,
                height: 600,
              ),
              onPointerMove: interactions.pointerMove,
              onPointerUp: interactions.pointerUp,
              onPointerCancel: interactions.pointerCancel,
              child: const ColoredBox(
                color: Colors.blueGrey,
                child: Center(child: Text('合成第 2 集')),
              ),
            ),
          ),
        ),
      );
      double offset() => tester
          .widget<Transform>(find.byKey(const ValueKey('episode-swipe-page')))
          .transform
          .storage[13];
      final short = await tester.startGesture(const Offset(20, 350));
      await short.moveBy(const Offset(0, -35));
      await tester.pump();
      expect(offset(), closeTo(-35, .1));
      await short.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 220));
      expect(offset(), closeTo(0, .1));
      expect(directions, isEmpty);
      final swipe = await tester.startGesture(const Offset(375, 350));
      await swipe.moveBy(const Offset(0, -110));
      await tester.pump();
      expect(offset(), closeTo(-110, .1));
      expect(find.text('第 3 集'), findsOneWidget);
      await swipe.up();
      expect(directions, [1]);
      await tester.pump();
      expect(offset(), closeTo(490, .1));
      expect(find.text('正在准备播放'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 110));
      expect(offset(), inExclusiveRange(0, 490));
      await tester.pump(const Duration(milliseconds: 120));
      expect(directions, [1]);
      expect(offset(), closeTo(0, .1));
      expect(interactions.episodeNavigationPending, isTrue);
      expect(find.text('正在准备播放'), findsOneWidget);
      pending.complete();
      await tester.pump();
      expect(interactions.episodeCommit, 0);
      await tester.pump();
      expect(offset(), closeTo(0, .1));
      expect(
        methods.where((m) => m == 'setBrightness' || m == 'setMediaVolume'),
        isEmpty,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      interactions.dispose();
      await player.dispose();
    },
  );

  testWidgets(
    'ready incoming content keeps moving without remounting or snapping early',
    (tester) async {
      tester.view.physicalSize = const Size(390, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      mockPlayerDevice();
      final fixture = await _fixture();
      final pending = Completer<void>();
      final ready = ValueNotifier<bool>(true);
      final episode = ValueNotifier<int>(2);
      var navigations = 0;
      late Uint8List previousFrame;
      final interactions = _interactions(
        fixture.player,
        captureEpisodeFrame: () async => previousFrame,
        onEpisodeSwipe: (_) async {
          navigations++;
          ready.value = false;
          await pending.future;
          episode.value = 3;
          ready.value = true;
        },
      );
      final contentKey = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: await _swipePreviewTheme(tester),
          builder: (context, child) => Material(child: child),
          home: RepaintBoundary(
            key: const ValueKey('swipe-capture'),
            child: ValueListenableBuilder<bool>(
              valueListenable: ready,
              builder: (context, isReady, child) => EpisodeSwipeSurface(
                interactions: interactions,
                enabled: true,
                previousLabel: '第 1 集',
                nextLabel: '第 3 集',
                currentLabel: '合成短剧\n第 ${episode.value} 集',
                contentReady: isReady,
                child: child!,
              ),
              child: SizedBox(
                key: contentKey,
                child: ValueListenableBuilder<int>(
                  valueListenable: episode,
                  builder: (context, number, child) =>
                      _syntheticEpisode(number),
                ),
              ),
            ),
          ),
        ),
      );
      final element = contentKey.currentContext;
      previousFrame = await _syntheticSwipeFrame(tester);
      _down(interactions, 1);
      await tester.pump();
      expect(interactions.episodeFrameBytes, isNotNull);
      await _waitForOutgoingFrame(tester);
      _move(interactions, 1, -120);
      await tester.pump();
      await _captureSwipe(tester, '01-drag');
      _up(interactions, 1, -120);
      expect(navigations, 1);
      await tester.pump();
      double offset() => tester
          .widget<Transform>(find.byKey(const ValueKey('episode-swipe-page')))
          .transform
          .storage[13];
      expect(offset(), closeTo(480, .1));
      final outgoingImage = tester
          .widget<RawImage>(
            find.byKey(const ValueKey('episode-swipe-outgoing-frame')),
          )
          .image!;
      expect(outgoingImage.debugDisposed, isFalse);
      expect(find.text('正在切换剧集'), findsNothing);
      await _captureSwipe(tester, '02-commit-start-loading');
      await tester.pump(const Duration(milliseconds: 80));
      final movingOffset = offset();
      expect(movingOffset, inExclusiveRange(0, 480));
      await _captureSwipe(tester, '03-mid-commit-loading');
      pending.complete();
      await tester.pump();
      expect(interactions.episodeCommit, 1);
      expect(find.text('正在准备播放'), findsNothing);
      expect(offset(), closeTo(movingOffset, .1));
      expect(contentKey.currentContext, same(element));
      expect(
        tester
            .widget<RawImage>(
              find.byKey(const ValueKey('episode-swipe-outgoing-frame')),
            )
            .image,
        same(outgoingImage),
      );
      final outgoingOffset = tester
          .widget<Transform>(
            find.byKey(const ValueKey('episode-swipe-outgoing')),
          )
          .transform
          .storage[13];
      expect(offset() - outgoingOffset, closeTo(600, .1));
      expect(find.text('合成第 3 集'), findsOneWidget);
      expect(find.text('合成第 2 集'), findsNothing);
      await _captureSwipe(tester, '04-ready-during-motion');
      await tester.pump(const Duration(milliseconds: 150));
      expect(interactions.episodeCommit, 0);
      expect(offset(), closeTo(0, .1));
      expect(contentKey.currentContext, same(element));
      expect(
        find.byKey(const ValueKey('episode-swipe-outgoing')),
        findsNothing,
      );
      expect(interactions.episodeFrameBytes, isNull);
      expect(outgoingImage.debugDisposed, isTrue);
      await _captureSwipe(tester, '05-settled');
      await tester.pumpWidget(const SizedBox.shrink());
      interactions.dispose();
      ready.dispose();
      episode.dispose();
      await fixture.player.dispose();
    },
  );

  testWidgets(
    'frame capture starts on touch-down and canceled or older gestures cannot leak a frame',
    (tester) async {
      mockPlayerDevice();
      final fixture = await _fixture();
      final requests = <Completer<Uint8List?>>[];
      final directions = <int>[];
      final interactions = _interactions(
        fixture.player,
        captureEpisodeFrame: () {
          final pending = Completer<Uint8List?>();
          requests.add(pending);
          return pending.future;
        },
        onEpisodeSwipe: (direction) async => directions.add(direction),
      );
      await tester.pump();
      _down(interactions, 1);
      expect(requests, hasLength(1));
      _move(interactions, 1, -120);
      expect(requests, hasLength(1));
      interactions.pointerCancel(const PointerCancelEvent(pointer: 1));
      _down(interactions, 2);
      expect(requests, hasLength(2));
      requests[0].complete(Uint8List.fromList([1, 2, 3]));
      await tester.pump();
      expect(interactions.episodeFrameBytes, isNull);
      final current = Uint8List.fromList([4, 5, 6]);
      requests[1].complete(current);
      await tester.pump();
      expect(interactions.episodeFrameBytes, orderedEquals([4, 5, 6]));
      current[0] = 99;
      expect(interactions.episodeFrameBytes!.first, 4);
      expect(
        () => interactions.episodeFrameBytes![0] = 99,
        throwsUnsupportedError,
      );
      _move(interactions, 2, -120);
      _move(interactions, 2, -50, milliseconds: 150);
      _up(interactions, 2, -50);
      expect(interactions.episodeFrameBytes, isNull);
      expect(directions, isEmpty);
      _down(interactions, 3);
      interactions.cancel();
      _up(interactions, 3, 0);
      requests[2].complete(Uint8List.fromList([7, 8, 9]));
      await tester.pump();
      expect(interactions.episodeFrameBytes, isNull);
      _down(interactions, 4);
      interactions.dispose();
      requests[3].complete(Uint8List.fromList([10, 11, 12]));
      await tester.pump();
      expect(interactions.episodeFrameBytes, isNull);
      expect(tester.takeException(), isNull);
      await fixture.player.dispose();
    },
  );

  testWidgets(
    'late capture never delays navigation and is cleared at the visual boundary while loading',
    (tester) async {
      mockPlayerDevice();
      final fixture = await _fixture();
      final capture = Completer<Uint8List?>();
      final navigation = Completer<void>();
      var navigations = 0;
      late final PlayerInteractions interactions;
      interactions = _interactions(
        fixture.player,
        captureEpisodeFrame: () => capture.future,
        onEpisodeSwipe: (_) async {
          navigations++;
          interactions.cancel();
          await navigation.future;
        },
      );
      await tester.pump();
      _down(interactions, 1);
      _move(interactions, 1, -120);
      _up(interactions, 1, -120);
      expect(navigations, 1);
      expect(interactions.episodeFrameBytes, isNull);
      await tester.pump(const Duration(milliseconds: 50));
      capture.complete(Uint8List.fromList([1, 2, 3]));
      await tester.pump();
      expect(interactions.episodeFrameBytes, orderedEquals([1, 2, 3]));
      await tester.pump(const Duration(milliseconds: 180));
      expect(interactions.episodeNavigationPending, isTrue);
      expect(interactions.episodeFrameBytes, isNull);
      navigation.complete();
      await tester.pump();
      expect(interactions.episodeCommit, 0);
      interactions.dispose();
      await fixture.player.dispose();
    },
  );

  testWidgets(
    'unavailable stale or timed-out capture uses fallback without blocking navigation',
    (tester) async {
      mockPlayerDevice();
      final fixture = await _fixture();
      final capture = Completer<Uint8List?>();
      var navigations = 0;
      final interactions = _interactions(
        fixture.player,
        captureEpisodeFrame: () => capture.future,
        onEpisodeSwipe: (_) async => navigations++,
      );
      await tester.pump();
      _down(interactions, 1);
      await tester.pump(const Duration(milliseconds: 190));
      capture.complete(Uint8List.fromList([1, 2, 3]));
      await tester.pump();
      expect(interactions.episodeFrameBytes, isNull);
      _move(interactions, 1, -120);
      _up(interactions, 1, -120);
      expect(navigations, 1);
      await tester.pump(PlayerInteractions.episodeTransitionDuration);
      interactions.dispose();
      await fixture.player.dispose();
    },
  );

  testWidgets(
    'leaving portrait resets motion without replaying a pending swipe on return',
    (tester) async {
      tester.view.physicalSize = const Size(390, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      mockPlayerDevice();
      final fixture = await _fixture();
      final pending = Completer<void>();
      final enabled = ValueNotifier<bool>(true);
      var calls = 0;
      final interactions = _interactions(
        fixture.player,
        onEpisodeSwipe: (_) async {
          calls++;
          await pending.future;
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: ValueListenableBuilder<bool>(
            valueListenable: enabled,
            builder: (context, isEnabled, child) => EpisodeSwipeSurface(
              interactions: interactions,
              enabled: isEnabled,
              previousLabel: '第 1 集',
              nextLabel: '第 3 集',
              child: const ColoredBox(color: Colors.blueGrey),
            ),
          ),
        ),
      );
      double offset() => tester
          .widget<Transform>(find.byKey(const ValueKey('episode-swipe-page')))
          .transform
          .storage[13];
      _down(interactions, 1);
      _move(interactions, 1, -120);
      _up(interactions, 1, -120);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(offset(), greaterThan(0));
      enabled.value = false;
      await tester.pump();
      expect(offset(), 0);
      expect(find.text('正在准备播放'), findsNothing);
      enabled.value = true;
      await tester.pump();
      interactions.hint('合成状态更新');
      await tester.pump();
      expect(offset(), 0);
      expect(find.text('正在准备播放'), findsNothing);
      expect(calls, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      interactions.dispose();
      enabled.dispose();
      pending.complete();
      await tester.pump();
      expect(tester.takeException(), isNull);
      await fixture.player.dispose();
    },
  );

  testWidgets(
    'flings commit below the position threshold, slow short drags and reversals rebound',
    (tester) async {
      mockPlayerDevice();
      final fixture = await _fixture();
      final directions = <int>[];
      final interactions = _interactions(
        fixture.player,
        onEpisodeSwipe: (direction) async => directions.add(direction),
      );
      await tester.pump();
      _down(interactions, 1);
      _move(interactions, 1, -30, milliseconds: 500);
      _up(interactions, 1, -30, milliseconds: 650);
      expect(directions, isEmpty);
      _down(interactions, 2);
      _move(interactions, 2, -12, milliseconds: 10);
      _move(interactions, 2, -24, milliseconds: 20);
      _move(interactions, 2, -36, milliseconds: 30);
      _up(interactions, 2, -40, milliseconds: 35);
      expect(directions, [1]);
      await tester.pump(PlayerInteractions.episodeTransitionDuration);
      _down(interactions, 3);
      _move(interactions, 3, -150, milliseconds: 100);
      _move(interactions, 3, -90, milliseconds: 180);
      _up(interactions, 3, -90, milliseconds: 250);
      expect(directions, [1]);
      expect(interactions.episodeDrag, 0);
      _down(interactions, 4);
      _move(interactions, 4, -130, milliseconds: 100);
      _move(interactions, 4, 110, milliseconds: 400);
      _up(interactions, 4, 110, milliseconds: 450);
      expect(directions, [1, -1]);
      await tester.pump(PlayerInteractions.episodeTransitionDuration);
      interactions.dispose();
      await fixture.player.dispose();
    },
  );

  testWidgets(
    'first and last episode edges resist dragging without dispatching navigation',
    (tester) async {
      mockPlayerDevice();
      final fixture = await _fixture();
      final directions = <int>[];
      var index = 0;
      final interactions = _interactions(
        fixture.player,
        canNavigateEpisode: (direction) =>
            index + direction >= 0 && index + direction < 3,
        onEpisodeSwipe: (direction) async => directions.add(direction),
      );
      await tester.pump();
      _down(interactions, 1);
      _move(interactions, 1, 120);
      expect(interactions.episodeDrag, closeTo(26.4, .01));
      _up(interactions, 1, 120);
      expect(directions, isEmpty);
      expect(interactions.episodeCommit, 0);
      expect(interactions.feedback, '已经是第一集');
      index = 2;
      _down(interactions, 2);
      _move(interactions, 2, -120);
      expect(interactions.episodeDrag, closeTo(-26.4, .01));
      _up(interactions, 2, -120);
      expect(directions, isEmpty);
      expect(interactions.feedback, '已经是最后一集');
      _down(interactions, 3);
      _move(interactions, 3, 120);
      _up(interactions, 3, 120);
      expect(directions, [-1]);
      await tester.pump(PlayerInteractions.episodeTransitionDuration);
      interactions.dispose();
      await fixture.player.dispose();
    },
  );

  testWidgets(
    'pending navigation rejects repeated swipes and completion survives pause and disposal',
    (tester) async {
      mockPlayerDevice();
      final fixture = await _fixture();
      final pending = Completer<void>();
      final directions = <int>[];
      var available = true;
      late final PlayerInteractions interactions;
      interactions = _interactions(
        fixture.player,
        available: () => available,
        onEpisodeSwipe: (direction) async {
          directions.add(direction);
          interactions.cancel();
          await pending.future;
        },
      );
      await tester.pump();
      _down(interactions, 1);
      _move(interactions, 1, -120);
      _up(interactions, 1, -120);
      expect(directions, [1]);
      available = false;
      await fixture.player.pause();
      await tester.pump(const Duration(milliseconds: 300));
      expect(interactions.episodeCommit, 1);
      available = true;
      _down(interactions, 2);
      _move(interactions, 2, -120);
      _up(interactions, 2, -120);
      expect(directions, [1]);
      expect(interactions.episodeNavigationPending, isTrue);
      interactions.dispose();
      pending.complete();
      await tester.pump();
      expect(tester.takeException(), isNull);
      await fixture.player.dispose();
    },
  );

  testWidgets(
    'multitouch, cancellation and foreground loss never turn a drag into navigation',
    (tester) async {
      mockPlayerDevice();
      final fixture = await _fixture();
      final directions = <int>[];
      var available = true;
      final interactions = _interactions(
        fixture.player,
        available: () => available,
        onEpisodeSwipe: (direction) async => directions.add(direction),
      );
      await tester.pump();
      _down(interactions, 1);
      _move(interactions, 1, -120);
      _down(interactions, 2);
      _up(interactions, 1, -120);
      _up(interactions, 2, -120);
      expect(directions, isEmpty);
      expect(interactions.episodeDragging, isFalse);
      _down(interactions, 3);
      _move(interactions, 3, -120);
      interactions.pointerCancel(const PointerCancelEvent(pointer: 3));
      expect(directions, isEmpty);
      _down(interactions, 4);
      _move(interactions, 4, -120);
      available = false;
      interactions.cancel();
      _up(interactions, 4, -120);
      available = true;
      expect(directions, isEmpty);
      _down(interactions, 5);
      _move(interactions, 5, -120);
      _up(interactions, 5, -120);
      expect(directions, [1]);
      await tester.pump(PlayerInteractions.episodeTransitionDuration);
      interactions.dispose();
      await fixture.player.dispose();
    },
  );

  testWidgets(
    'navigation errors release the swipe lock and allow a later retry',
    (tester) async {
      mockPlayerDevice();
      final fixture = await _fixture();
      var calls = 0;
      final interactions = _interactions(
        fixture.player,
        onEpisodeSwipe: (_) async {
          calls++;
          if (calls == 1) throw StateError('synthetic failure');
        },
      );
      await tester.pump();
      _down(interactions, 1);
      _move(interactions, 1, -120);
      _up(interactions, 1, -120);
      await tester.pump(PlayerInteractions.episodeTransitionDuration);
      expect(interactions.feedback, '切换失败，请重试');
      expect(interactions.episodeSwipeBusy, isFalse);
      expect(tester.takeException(), isNull);
      _down(interactions, 2);
      _move(interactions, 2, -120);
      _up(interactions, 2, -120);
      expect(calls, 2);
      await tester.pump(PlayerInteractions.episodeTransitionDuration);
      interactions.dispose();
      await fixture.player.dispose();
    },
  );

  testWidgets(
    'fullscreen volume reads and writes system media volume and displays the actual returned step',
    (tester) async {
      final writes = <double>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(AppDevice.channel, (call) async {
        if (call.method == 'getBrightness') return .5;
        if (call.method == 'getMediaVolume') return .3;
        if (call.method == 'setMediaVolume') {
          writes.add((call.arguments as Map)['volume'] as double);
          return .4;
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(AppDevice.channel, null),
      );
      final platform = ScriptedPlayer();
      final player = Player(platformPlayer: platform);
      await player.open(Media('https://synthetic.test/video.mp4'));
      await player.setVolume(20);
      final interactions = PlayerInteractions(
        player: player,
        available: () => true,
        baseSpeed: () => 1,
        onTogglePlayback: () {},
        onFullscreen: () {},
        onEpisode: (_) => '',
      );
      await tester.pump();
      interactions.pointerDown(
        const PointerDownEvent(
          pointer: 1,
          position: Offset(330, 300),
          kind: PointerDeviceKind.touch,
          buttons: kPrimaryButton,
        ),
        swipeEnabled: true,
        fullscreen: true,
        width: 390,
        height: 600,
      );
      interactions.pointerMove(
        const PointerMoveEvent(pointer: 1, position: Offset(330, 250)),
      );
      await tester.pump();
      expect(writes.single, closeTo(.3 + 50 / 360, .001));
      expect(interactions.hudState.value, .4);
      expect(platform.state.volume, 100);
      interactions.pointerUp(
        const PointerUpEvent(pointer: 1, position: Offset(330, 250)),
      );
      interactions.dispose();
      await player.dispose();
    },
  );
}

Future<({Player player, ScriptedPlayer platform})> _fixture() async {
  final platform = ScriptedPlayer();
  final player = Player(platformPlayer: platform);
  await player.open(Media('https://synthetic.test/video.mp4'));
  return (player: player, platform: platform);
}

PlayerInteractions _interactions(
  Player player, {
  bool Function()? available,
  bool Function(int)? canNavigateEpisode,
  Future<void> Function(int)? onEpisodeSwipe,
  Future<Uint8List?> Function()? captureEpisodeFrame,
}) => PlayerInteractions(
  player: player,
  available: available ?? () => true,
  baseSpeed: () => 1,
  onTogglePlayback: () {},
  onFullscreen: () {},
  onEpisode: (_) => '',
  onEpisodeSwipe: onEpisodeSwipe,
  canNavigateEpisode: canNavigateEpisode,
  captureEpisodeFrame: captureEpisodeFrame,
);

void _down(PlayerInteractions interactions, int pointer) =>
    interactions.pointerDown(
      PointerDownEvent(
        pointer: pointer,
        position: const Offset(190, 300),
        kind: PointerDeviceKind.touch,
        buttons: kPrimaryButton,
      ),
      swipeEnabled: true,
      width: 390,
      height: 600,
    );

void _move(
  PlayerInteractions interactions,
  int pointer,
  double delta, {
  int milliseconds = 100,
}) => interactions.pointerMove(
  PointerMoveEvent(
    pointer: pointer,
    position: Offset(190, 300 + delta),
    timeStamp: Duration(milliseconds: milliseconds),
  ),
);

void _up(
  PlayerInteractions interactions,
  int pointer,
  double delta, {
  int milliseconds = 200,
}) => interactions.pointerUp(
  PointerUpEvent(
    pointer: pointer,
    position: Offset(190, 300 + delta),
    timeStamp: Duration(milliseconds: milliseconds),
  ),
);

Widget _syntheticEpisode(int number) => ColoredBox(
  color: number == 2 ? const Color(0xFF284D68) : const Color(0xFF315F4F),
  child: Stack(
    fit: StackFit.expand,
    children: [
      Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.play_circle_outline,
              size: 72,
              color: Colors.white,
            ),
            const SizedBox(height: 20),
            Text(
              '合成第 $number 集',
              style: const TextStyle(fontSize: 28, color: Colors.white),
            ),
            const SizedBox(height: 12),
            const Text(
              '仅用于手势动画验证',
              style: TextStyle(fontSize: 16, color: Colors.white70),
            ),
          ],
        ),
      ),
      Positioned(
        left: 20,
        top: 24,
        child: Text(
          '合成短剧 · 第 $number 集',
          style: const TextStyle(fontSize: 16, color: Colors.white),
        ),
      ),
      const Positioned(
        left: 20,
        right: 20,
        bottom: 28,
        child: LinearProgressIndicator(value: .35, color: Colors.white70),
      ),
    ],
  ),
);

Future<ThemeData> _swipePreviewTheme(WidgetTester tester) async {
  if (Platform.environment['HG_SWIPE_CAPTURE_DIR'] == null) {
    return ThemeData.dark();
  }
  await tester.runAsync(() async {
    final font = await File(
      '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc',
    ).readAsBytes();
    await (FontLoader(
      'SwipePreviewCJK',
    )..addFont(Future.value(ByteData.sublistView(font)))).load();
    final icons = await File(
      '${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    ).readAsBytes();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(Future.value(ByteData.sublistView(icons)))).load();
  });
  return ThemeData.dark().copyWith(
    textTheme: ThemeData.dark().textTheme.apply(fontFamily: 'SwipePreviewCJK'),
  );
}

Future<void> _captureSwipe(WidgetTester tester, String name) async {
  final directory = Platform.environment['HG_SWIPE_CAPTURE_DIR'];
  if (directory == null) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('swipe-capture')),
  );
  await tester.runAsync(() async {
    await Directory(directory).create(recursive: true);
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await File('$directory/$name.png')
        .writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

Future<Uint8List> _syntheticSwipeFrame(WidgetTester tester) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('swipe-capture')),
  );
  return (await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      return bytes!.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  }))!;
}

Future<void> _waitForOutgoingFrame(WidgetTester tester) async {
  final frame = find.byKey(
    const ValueKey('episode-swipe-outgoing-frame'),
    skipOffstage: false,
  );
  for (var attempt = 0; attempt < 200; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1)),
    );
    await tester.pump();
    if (frame.evaluate().isNotEmpty) return;
  }
  fail('Synthetic outgoing frame did not decode');
}
