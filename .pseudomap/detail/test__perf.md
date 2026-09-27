# test/perf · Signaturen

## test/perf/agent_switch_data_perf_test.dart  (146 Z.)
- L27 `_catalogueReadsPerSwitch = 5`  — Catalogue reads one mount of the chat screen makes.
- L30 `_messagesPerThread = 80`  — Messages per thread; every third answer carries tool calls.
- L32 `_switches = 9`
- L39 `_dataCeilingMs = 8`  — The median data work of one switch must stay under this. Measured on the
- L41 `List<Map<String, dynamic>> _catalogue()`
- L58 `List<Map<String, String>> _thread()`
- L82 `void main()`

## test/perf/agent_switch_perf_test.dart  (324 Z.)
- L47 `_guard = Timeout(Duration(minutes: 5))`
- L50 `_messagesPerThread = 80`  — Messages per thread.
- L53 `_switches = 24`  — Measured switches.
- L61 `_switchCeilingMs = 350`  — The median switch must stay under this. On the development machine the
- L63 `class _MemoryStore implements AgentsSecureKeyValueStore`
  - L64 `final Map<String, String> map = <String, String>{}`
  - L67 `Future<String?> read(String key)`
  - L70 `Future<void> write(String key, String value)`
  - L73 `Future<void> delete(String key)`
- L77 `class _SignedIn implements AccountSessionSource`  — A signed-in account, so the shell takes its normal paired path.
  - L78 `const _SignedIn()`
  - L81 `AccountSession? current()`
  - L88 `Future<AccountSession?> refresh()`
- L92 `String _marker(int agent)`  — Marker words, one per agent, so the finder knows which thread is shown.
- L94 `String _answer(int agent, int i)`
- L119 `String _toolCalls(int i)`
- L135 `List<Map<String, dynamic>> _transcript(int agent)`
- L147 `void main()`

## test/perf/cold_start_perf_test.dart  (584 Z.)
- L43 `_guard = Timeout(Duration(minutes: 5))`  — A wall-clock guard on every test in this file. A regression that made one
- L47 `_mountRuns = 5`  — Runs per measured quantity. Five is the floor the bead asks for; the mount
- L50 `_microRuns = 9`  — The micro-benchmarks are cheap, so they can afford more samples.
- L54 `_marker = 'rowmark'`  — Every seeded row carries this marker, so one finder recognises the
- L58 `_mountCeilingMs = 6000`  — Ceilings. Generous on purpose — see the file comment. They are here to
- L59 `_microCeilingMs = 400`
- L61 `void main()`

## test/perf/perf_support.dart  (203 Z.)
- L27 `class NoopSaver implements AgentFileSaver`  — A file saver that writes nowhere. No perf test hands a file to it.
  - L29 `Future<String> save(AgentsRelayFile file)`
- L33 `class FakeSessionSource implements AccountSessionSource`  — No Supabase session anywhere — the cold start proper.
  - L34 `const FakeSessionSource()`
  - L37 `AccountSession? current()`
  - L40 `Future<AccountSession?> refresh()`
- L45 `class FakeDisk`  — The local cache, as a map. It outlives [AgentsChatStore.reset] on purpose:
  - L46 `final Map<String, Map<String, dynamic>> rows = <String, Map<String, dynamic>>{}`
  - L48 `final Map<String, String> kv = <String, String>{}`
  - L52 `int payloadBytesOf(String userId, String sessionKey)`  — How many bytes of payload the disk holds for one thread. The parse cost
  - L59 `void install()`  — Points the store at this map. Called again after every reset, because
- L76 `Widget perfApp(Widget child)`
- L96 `void silenceUnrelatedPlugins(WidgetTester tester)`  — The imported chat screen constructs an [AudioRecorder] on mount, which
- L112 `Future<void> releaseIdleTimers(WidgetTester tester)`  — The imported chat screen opens a multiplex session on mount and arms a
- L121 `Future<void> drainNotifyDebounce()`  — `ChatStorageState.notifyChanges` debounces its stream event behind a 100 ms
- L131 `double median(List<double> samples)`  — The median of [samples]. An even count takes the mean of the middle pair.
- L139 `double _minOf(List<double> s)`
- L140 `double _maxOf(List<double> s)`
- L144 `class PerfRow`  — One measured quantity: a label, its samples in milliseconds, and an
  - L145 `PerfRow(this.label, this.samplesMs, {this.note = ''})`
  - L147 `final String label`
  - L148 `final List<double> samplesMs`
  - L149 `final String note`
  - L151 `double get medianMs`
  - L152 `double get minMs`
  - L153 `double get maxMs`
- L157 `class PerfTable`  — Collects [PerfRow]s and prints them as one fixed-width table.
  - L158 `PerfTable(this.title)`
  - L160 `final String title`
  - L161 `final List<PerfRow> rows = <PerfRow>[]`
  - L163 `void add(String label, List<double> samplesMs, {String note = ''})`
  - L166 `void report()`
- L197 `double timedMs(void Function() body)`  — Wall-clock milliseconds of [body], at microsecond resolution.
