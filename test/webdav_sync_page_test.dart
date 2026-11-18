import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/pages/library_backup_page.dart';
import 'package:fqapp/pages/multi_device_sync_page.dart';
import 'package:fqapp/pages/webdav_sync_page.dart';

import 'support/secure_key_storage_mock.dart';

void main() {
  late Map<String, String> secureKeys;

  setUp(() {
    secureKeys = mockSecureKeyStorage();
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('backup page opens safe WebDAV migration guidance', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: LibraryBackupPage()));
    final entry = find.text('WebDAV 同步');
    await tester.drag(
      find.byKey(const ValueKey('backup-scroll')),
      const Offset(0, -180),
    );
    await tester.pumpAndSettle();
    await tester.tap(entry);
    await tester.pumpAndSettle();
    expect(find.byType(WebDavSyncPage), findsOneWidget);
    expect(find.text('旧版 WebDAV 直接同步已停用'), findsOneWidget);
    expect(find.byType(TextFormField), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'legacy WebDAV entry routes to preview-confirmed multi-device setup',
    (tester) async {
      await tester.pumpWidget(const MaterialApp(home: WebDavSyncPage()));
      expect(secureKeys, isEmpty);
      await tester.tap(find.byKey(const ValueKey('open-multi-device-sync')));
      await tester.pumpAndSettle();
      expect(find.byType(MultiDeviceSyncPage), findsOneWidget);
      expect(secureKeys, isEmpty);
      expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
