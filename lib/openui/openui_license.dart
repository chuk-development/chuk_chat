// The licence of OpenUI Lang (thesysdev/openui) for the in-app licence
// page. The Flutter port (vendor/openui, vendor/openui_core) ships its own
// LICENSE files; Flutter adds those by itself.

import 'package:flutter/foundation.dart';

/// The package name the licence page shows for OpenUI Lang.
const String kOpenUiLicensePackage = 'OpenUI Lang (thesysdev/openui)';

/// The MIT licence of OpenUI Lang, Copyright (c) 2011-2024 Thesys Inc.
const String kOpenUiLicenseText = '''
MIT License

Copyright (c) 2011-2024 Thesys Inc.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.''';

bool _registered = false;

/// Adds the OpenUI Lang licence to [LicenseRegistry]. Call it once at
/// start; a second call does nothing.
void registerOpenUiLicense() {
  if (_registered) return;
  _registered = true;
  LicenseRegistry.addLicense(
    () => Stream<LicenseEntry>.value(
      const LicenseEntryWithLineBreaks(<String>[
        kOpenUiLicensePackage,
      ], kOpenUiLicenseText),
    ),
  );
}
