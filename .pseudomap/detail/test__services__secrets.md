# test/services/secrets · Signaturen

## test/services/secrets/secrets_service_test.dart  (149 Z.)
- L12 `class _Memory implements AgentsSecureKeyValueStore`
  - L13 `final Map<String, String> map = <String, String>{}`
  - L16 `Future<String?> read(String key)`
  - L19 `Future<void> write(String key, String value)`
  - L22 `Future<void> delete(String key)`
- L26 `class _Mirror implements SecretsMirror`  — A mirror that records what it was asked to do and can pre-seed a pull.
  - L27 `_Mirror({this.seed})`
  - L29 `Map<String, String>? seed`
  - L30 `final List<(String, String)> saved = <(String, String)>[]`
  - L31 `final List<String> deleted = <String>[]`
  - L34 `Future<void> save(String name, String value)`
  - L37 `Future<void> delete(String name)`
  - L40 `Future<Map<String, String>?> load()`
- L44 `List<(Map<String, String>, int, String?)> _sink(SecretsService Function() _)`  — Every frame handed to the "host": `(values, revision, requestId)`.
- L49 `List<(String, int, String?)> _flat(List<(Map<String, String>, int, String?)> xs)`  — Records with a Map inside compare by identity; flatten to compare by value.
- L54 `String _j(Map<String, String> m)`
- L56 `void main()`

## test/services/secrets/secrets_store_test.dart  (104 Z.)
- L10 `class _Memory implements AgentsSecureKeyValueStore`  — In-memory secure backend so the set round-trips with no platform channel.
  - L11 `final Map<String, String> map = <String, String>{}`
  - L14 `Future<String?> read(String key)`
  - L17 `Future<void> write(String key, String value)`
  - L20 `Future<void> delete(String key)`
- L23 `void main()`
