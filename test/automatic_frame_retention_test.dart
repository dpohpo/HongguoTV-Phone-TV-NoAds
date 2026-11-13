import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/luna_exo_player.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/player_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'fixtures.dart';
import 'luna_exo_diagnostics_test.dart' show DiagnosticVideoPlatform;
import 'playback_transition_test.dart' show PreparedTransitionRepository;
import 'player_fixtures.dart' show mockPlayerDevice;

class PausingVideoPlatform extends DiagnosticVideoPlatform {
  Completer<void>? pendingPause;
  @override
  Future<void> pause(int playerId) =>
      pendingPause?.future ?? Future<void>.value();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late DiagnosticVideoPlatform platform;
  late VideoPlayerPlatform previous;
  late Uint8List frame;
  final calls = <MethodCall>[];
  final waits = <int, Completer<Map<String, Object>>>{};
  var nativeGeneration = 0;
  var alreadyRendered = false;
  const response = {
    'durationMs': 90000,
    'width': 1280,
    'height': 720,
    'elapsedMs': 250,
    'generation': 999,
  };

  setUpAll(() async {
    final recorder = ui.PictureRecorder();
    Canvas(
      recorder,
    ).drawRect(const Rect.fromLTWH(0, 0, 32, 18), Paint()..color = Colors.blue);
    final picture = recorder.endRecording();
    final image = await picture.toImage(32, 18);
    frame = (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer
        .asUint8List();
    image.dispose();
    picture.dispose();
  });

  setUp(() {
    mockPlayerDevice();
    previous = VideoPlayerPlatform.instance;
    platform = DiagnosticVideoPlatform();
    VideoPlayerPlatform.instance = platform;
    nativeGeneration = 0;
    alreadyRendered = false;
    calls.clear();
    waits.clear();
    messenger.setMockMethodCallHandler(LunaExoPlayer.diagnosticChannel, (
      call,
    ) async {
      calls.add(call);
      if (call.method == 'captureFrame') return frame;
      if (call.method == 'prepareNext') return {'prepared': true};
      if (call.method == 'transition') {
        return {
          ...response,
          'firstFrame': alreadyRendered,
          'transitionGeneration': ++nativeGeneration,
        };
      }
      if (call.method == 'waitForFirstFrame') {
        final generation = call.arguments['generation'] as int;
        return (waits[generation] ??= Completer<Map<String, Object>>()).future;
      }
      return {};
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(LunaExoPlayer.diagnosticChannel, null);
    VideoPlayerPlatform.instance = previous;
  });

  Future<LunaExoPlayer> player({bool television = false}) async {
    final value = LunaExoPlayer(television: () => television);
    addTearDown(value.dispose);
    await value.open(Media('file:///first.mp4'));
    return value;
  }

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 5));

  test(
    'automatic frame survives READY and clears only for its real target frame',
    () async {
      final value = await player();
      expect(await value.retainCurrentFrame(), true);
      final held = value.frameHold.image;
      await value.transitionTo(
        Media('file:///second.mp4'),
        retainPreviousFrame: true,
      );
      expect(value.frameHold.image, same(held));
      expect(value.lastTransitionFirstFrame, false);
      expect(value.state.playing, true);
      expect(waits.keys, [1]);
      waits[1]!.complete({'firstFrame': true, 'generation': 1});
      await settle();
      expect(value.frameHold.active, false);
      expect(value.frameHold.image, null);
      expect(value.lastTransitionFirstFrame, true);
      expect(platform.created, 1);
      expect(platform.peakLive, 1);
    },
  );

  test('manual replacement clears the old frame and late callback cannot clear a newer hold', () async {
    final value = await player();
    expect(await value.retainCurrentFrame(), true);
    await value.transitionTo(
      Media('file:///second.mp4'),
      retainPreviousFrame: true,
    );
    await value.transitionTo(Media('file:///first-again.mp4'));
    expect(value.frameHold.active, false);
    expect(await value.retainCurrentFrame(), true);
    await value.transitionTo(
      Media('file:///third.mp4'),
      retainPreviousFrame: true,
    );
    final newest = value.frameHold.image;
    waits[1]!.complete({'firstFrame': true, 'generation': 1});
    await settle();
    expect(value.frameHold.image, same(newest));
    expect(value.lastTransitionFirstFrame, false);
    waits[3]!.complete({'firstFrame': true, 'generation': 3});
    await settle();
    expect(value.frameHold.active, false);
    expect(platform.created, 1);
  });

  test(
    'already rendered target clears the hold without a second wait',
    () async {
      final value = await player();
      expect(await value.retainCurrentFrame(), true);
      alreadyRendered = true;
      await value.transitionTo(
        Media('file:///second.mp4'),
        retainPreviousFrame: true,
      );
      expect(value.frameHold.active, false);
      expect(waits, isEmpty);
      expect(value.lastTransitionFirstFrame, true);
    },
  );

  test('first-frame timeout releases cover, pauses and reports recovery without fake success', () async {
    final value = await player();
    final errors = <String>[];
    final subscription = value.stream.error.listen(errors.add);
    addTearDown(subscription.cancel);
    expect(await value.retainCurrentFrame(), true);
    await value.transitionTo(
      Media('file:///second.mp4'),
      retainPreviousFrame: true,
    );
    waits[1]!.completeError(PlatformException(code: 'transition_timeout'));
    await settle();
    expect(value.frameHold.image, null);
    expect(value.frameHoldFailure.value, isNotNull);
    expect(value.lastTransitionFirstFrame, false);
    expect(value.state.playing, false);
    expect(errors, hasLength(1));
  });

  test('pause during pending wait clears the image and suppresses late timeout recovery', () async {
    final value = await player();
    final errors = <String>[];
    final subscription = value.stream.error.listen(errors.add);
    addTearDown(subscription.cancel);
    expect(await value.retainCurrentFrame(), true);
    await value.transitionTo(
      Media('file:///second.mp4'),
      retainPreviousFrame: true,
    );
    await value.pause();
    waits[1]!.completeError(PlatformException(code: 'transition_timeout'));
    await settle();
    expect(value.frameHold.active, false);
    expect(value.frameHoldFailure.value, null);
    expect(errors, isEmpty);
  });

  test(
    'superseded recovery cannot report error after its pause finally completes',
    () async {
      final slow = PausingVideoPlatform();
      platform = slow;
      VideoPlayerPlatform.instance = slow;
      final value = await player();
      final errors = <String>[];
      final subscription = value.stream.error.listen(errors.add);
      addTearDown(subscription.cancel);
      expect(await value.retainCurrentFrame(), true);
      await value.transitionTo(
        Media('file:///second.mp4'),
        retainPreviousFrame: true,
      );
      slow.pendingPause = Completer<void>();
      waits[1]!.completeError(PlatformException(code: 'transition_timeout'));
      await settle();
      expect(value.frameHoldFailure.value, isNotNull);
      alreadyRendered = true;
      await value.transitionTo(Media('file:///manual.mp4'));
      slow.pendingPause!.complete();
      await settle();
      expect(value.frameHoldFailure.value, null);
      expect(errors, isEmpty);
      expect(value.state.playing, true);
    },
  );

  test(
    'mismatched native first-frame token never counts as target success',
    () async {
      final value = await player();
      expect(await value.retainCurrentFrame(), true);
      await value.transitionTo(
        Media('file:///second.mp4'),
        retainPreviousFrame: true,
      );
      waits[1]!.complete({'firstFrame': true, 'generation': 999});
      await settle();
      expect(value.lastTransitionFirstFrame, false);
      expect(value.frameHold.active, false);
      expect(value.frameHoldFailure.value, isNotNull);
    },
  );

  test('dispose cancels hold and ignores late first-frame success', () async {
    final value = LunaExoPlayer();
    await value.open(Media('file:///first.mp4'));
    expect(await value.retainCurrentFrame(), true);
    await value.transitionTo(
      Media('file:///second.mp4'),
      retainPreviousFrame: true,
    );
    await value.dispose();
    waits[1]!.complete({'firstFrame': true, 'generation': 1});
    await settle();
    expect(value.frameHold.image, null);
    expect(value.lastTransitionFirstFrame, false);
    expect(platform.disposed, [0]);
  });

  test('TV automatic capture opts in without enabling portrait capture or a second decoder', () async {
    final value = await player(television: true);
    expect(await value.captureFrame(), null);
    expect(calls.where((c) => c.method == 'captureFrame'), isEmpty);
    expect(await value.retainCurrentFrame(), true);
    final call = calls.singleWhere((c) => c.method == 'captureFrame');
    expect(call.arguments['allowTelevision'], true);
    expect(platform.views, [VideoViewType.platformView]);
    expect(platform.peakLive, 1);
  });

  test(
    'new manual transition cancels pending capture and discards its late bytes',
    () async {
      final bytes = Completer<Uint8List?>();
      messenger.setMockMethodCallHandler(LunaExoPlayer.diagnosticChannel, (
        call,
      ) async {
        if (call.method == 'captureFrame') return bytes.future;
        if (call.method == 'transition') {
          return {...response, 'firstFrame': true, 'transitionGeneration': 1};
        }
        return {};
      });
      final value = await player();
      final capture = value.retainCurrentFrame();
      await value.transitionTo(Media('file:///manual.mp4'));
      expect(await capture, false);
      bytes.complete(frame);
      await settle();
      expect(value.frameHold.image, null);
    },
  );

  test(
    'cold fallback releases the previous frame before replacing the controller',
    () async {
      messenger.setMockMethodCallHandler(LunaExoPlayer.diagnosticChannel, (
        call,
      ) async {
        if (call.method == 'captureFrame') return frame;
        if (call.method == 'transition') {
          throw PlatformException(code: 'transition_failed');
        }
        return {};
      });
      final value = await player();
      expect(await value.retainCurrentFrame(), true);
      await value.transitionTo(
        Media('file:///cold.mp4'),
        retainPreviousFrame: true,
      );
      expect(value.frameHold.image, null);
      expect(platform.created, 2);
      expect(platform.peakLive, 1);
    },
  );

  testWidgets(
    'automatic screen overlay remains after READY and shows waiting until first frame',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        tester.view.physicalSize = const Size(960, 540);
        tester.view.devicePixelRatio = 1;
        SharedPreferences.setMockInitialValues({});
        final store = LocalStore(await SharedPreferences.getInstance());
        final repository = PreparedTransitionRepository();
        final value = LunaExoPlayer();
        await tester.pumpWidget(
          RepaintBoundary(
            key: const ValueKey('automatic-frame-capture'),
            child: MaterialApp(
              home: PlayerScreen(
                detail: await repository.detail(FixtureRepository.free),
                initialIndex: 0,
                repository: repository,
                store: store,
                playerFactory: () => value,
                videoBuilder: (controls) => ColoredBox(
                  color: nativeGeneration == 0 ? Colors.blue : Colors.green,
                  child: controls,
                ),
              ),
            ),
          ),
        );
        for (var i = 0; i < 20; i++) {
          await tester.pump(const Duration(milliseconds: 10));
        }
        final controller = value.controller!;
        controller.value = controller.value.copyWith(
          position: controller.value.duration,
        );
        platform.streams[0]!.add(
          VideoEvent(eventType: VideoEventType.completed),
        );
        for (var i = 0; i < 200 && waits.isEmpty; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 1)),
          );
          await tester.pump(const Duration(milliseconds: 1));
        }
        expect(waits.keys, [1]);
        expect(
          find.byKey(const ValueKey('automatic-transition-frame')),
          findsOneWidget,
        );
        expect(value.lastTransitionFirstFrame, false);
        expect(platform.created, 1);
        await _expectFramePixel(
          tester,
          Colors.blue,
          '01-ready-still-old-frame',
        );
        await tester.pump(const Duration(milliseconds: 750));
        expect(find.text('正在衔接下一集…'), findsOneWidget);
        waits[1]!.complete({'firstFrame': true, 'generation': 1});
        await tester.pump();
        await tester.pump();
        expect(
          find.byKey(const ValueKey('automatic-transition-frame')),
          findsNothing,
        );
        expect(find.text('正在衔接下一集…'), findsNothing);
        await _expectFramePixel(tester, Colors.green, '02-target-first-frame');
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.pump();
        expect(value.controller, null);
        store.dispose();
      } finally {
        debugDefaultTargetPlatformOverride = null;
        tester.view.reset();
      }
    },
  );

  testWidgets(
    'last episode does not capture a frame or begin a fake next transition',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final store = LocalStore(await SharedPreferences.getInstance());
      final repository = PreparedTransitionRepository();
      final original = await repository.detail(FixtureRepository.free);
      final detail = DramaDetail(
        const Drama(
          id: 'hongguo:100',
          source: 'hongguo',
          title: '合成连载',
          episodes: 2,
          releaseStatus: 'ongoing',
        ),
        original.episodes,
      );
      final value = LunaExoPlayer();
      await tester.pumpWidget(
        MaterialApp(
          home: PlayerScreen(
            detail: detail,
            initialIndex: 1,
            repository: repository,
            store: store,
            playerFactory: () => value,
            videoBuilder: (controls) =>
                ColoredBox(color: Colors.blueGrey, child: controls),
          ),
        ),
      );
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      final controller = value.controller!;
      controller.value = controller.value.copyWith(
        position: controller.value.duration,
      );
      platform.streams[0]!.add(VideoEvent(eventType: VideoEventType.completed));
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(
        calls.where(
          (c) => c.method == 'captureFrame' || c.method == 'transition',
        ),
        isEmpty,
      );
      expect(value.frameHold.active, false);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump();
      store.dispose();
    },
  );
}

Future<void> _expectFramePixel(
  WidgetTester tester,
  Color color,
  String name,
) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('automatic-frame-capture')),
  );
  final rgba = await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      final directory = Platform.environment['HG_AUTO_CAPTURE_DIR'];
      if (directory != null) {
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        await Directory(directory).create(recursive: true);
        await File('$directory/$name.png')
            .writeAsBytes(png!.buffer.asUint8List());
      }
      final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final at = (100 * image.width + 100) * 4;
      return bytes!.buffer.asUint8List().sublist(at, at + 4);
    } finally {
      image.dispose();
    }
  });
  final expected = [
    (color.r * 255).round(),
    (color.g * 255).round(),
    (color.b * 255).round(),
  ];
  final maximum = expected.reduce((a, b) => a > b ? a : b);
  final channel = expected.indexOf(maximum);
  final controlsDim = rgba![channel] / maximum;
  expect(controlsDim, inInclusiveRange(.4, 1));
  for (var i = 0; i < 3; i++) {
    expect(rgba[i], closeTo(expected[i] * controlsDim, 1.5));
  }
  expect(rgba[3], 255);
}
