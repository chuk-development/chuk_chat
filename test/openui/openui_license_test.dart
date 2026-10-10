import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/openui/openui_license.dart';

void main() {
  test('the OpenUI Lang licence is in the registry, once', () async {
    registerOpenUiLicense();
    registerOpenUiLicense();
    final entries = await LicenseRegistry.licenses
        .where((e) => e.packages.contains(kOpenUiLicensePackage))
        .toList();
    expect(entries, hasLength(1));
    final text = entries.single.paragraphs.map((p) => p.text).join('\n');
    expect(text, contains('Copyright (c) 2011-2024 Thesys Inc.'));
    expect(text, contains('MIT License'));
  });
}
