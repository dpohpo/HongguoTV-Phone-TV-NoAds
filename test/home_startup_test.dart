import 'dart:async';

import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/main.dart';
import 'package:duanju_app/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

class StartupRepository extends FixtureRepository {
  int calls = 0;
  bool alwaysFail = false;
  Completer<CatalogPage>? first;
  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
  }) async {
    calls++;
    if (calls == 1 && first != null) return first!.future;
    if (calls == 1 || alwaysFail) {
      throw StateError('synthetic first connection failure');
    }
    return CatalogPage([
      const Drama(id: 'hongguo:startup', source: 'hongguo', title: '首次加载成功'),
    ], hasMore: false);
  }
}

void main() {
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
  }

  Future<void> mount(WidgetTester tester, StartupRepository repository) async {
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    await store.setSource('hongguo');
    await tester.pumpWidget(DuanjuApp(repository: repository, store: store));
    await settle(tester);
  }

  testWidgets('cold homepage automatically recovers its first failed request', (
    tester,
  ) async {
    final repository = StartupRepository();
    await mount(tester, repository);
    expect(repository.calls, 1);
    expect(find.text('立即重试'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    await settle(tester);
    expect(repository.calls, 2);
    expect(find.text('首次加载成功'), findsWidgets);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets(
    'cold homepage timeout is cancellable and late response cannot replace the retry',
    (tester) async {
      final repository = StartupRepository()..first = Completer<CatalogPage>();
      await mount(tester, repository);
      await tester.pump(const Duration(seconds: 19));
      await tester.pump(const Duration(seconds: 2));
      await settle(tester);
      expect(repository.calls, 2);
      expect(find.text('首次加载成功'), findsWidgets);
      repository.first!.complete(
        CatalogPage([
          const Drama(id: 'hongguo:stale', source: 'hongguo', title: '过期的旧响应'),
        ]),
      );
      await settle(tester);
      expect(find.text('过期的旧响应'), findsNothing);
      expect(find.text('首次加载成功'), findsWidgets);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets('cold homepage retries are bounded and stop when leaving', (
    tester,
  ) async {
    final repository = StartupRepository()..alwaysFail = true;
    await mount(tester, repository);
    await tester.pump(const Duration(seconds: 2));
    await settle(tester);
    await tester.pump(const Duration(seconds: 4));
    await settle(tester);
    expect(repository.calls, 3);
    expect(find.text('暂时无法加载'), findsOneWidget);
    await tester.pump(const Duration(seconds: 30));
    expect(repository.calls, 3);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
