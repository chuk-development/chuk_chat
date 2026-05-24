import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/artifact_storage_service.dart';

void main() {
  group('ArtifactStorageService.repairVersionChain (no-op paths)', () {
    test('empty artifactId returns 0 without touching Supabase', () async {
      final result = await ArtifactStorageService.repairVersionChain('');
      expect(
        result,
        0,
        reason: 'empty id is filtered before any network call',
      );
    });

    test(
      'whitespace-only artifactId returns 0 without touching Supabase',
      () async {
        final result = await ArtifactStorageService.repairVersionChain(
          '   \t   ',
        );
        expect(result, 0);
      },
    );

    // Non-empty inputs reach `loadArtifactById` → SupabaseService.client,
    // which is not available under `flutter test` without a backend.
    // The rich-path behaviour is exercised by the integration / app-driven
    // tests; here we only need to prove the entry-point input validation
    // matches the documented contract.
  });
}
