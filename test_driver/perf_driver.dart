// Driver for the on-device speed tests in integration_test/*_perf_test.dart.
// Prints the test's report and writes it to build/integration_response_data.json.

import 'dart:convert';

import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver(
  responseDataCallback: (Map<String, dynamic>? data) async {
    // ignore: avoid_print
    print('PERF_REPORT ${jsonEncode(data)}');
    await writeResponseData(data);
  },
);
