// lib/utils/word_diff.dart
//
// A word-level diff for prose: a mail or a Slack draft that the agent
// revised. The text is cut into words and the whitespace between them, the
// longest common subsequence keeps what stayed, and the rest comes out as
// removed or inserted runs (bead chuk_chat-gkt9).
//
// `DiffWidget` (lib/widgets/diff_widget.dart) does lines for code. This one
// does words, because a revised mail changes a word here and a sentence
// there, and a line diff would mark the whole paragraph.

/// What happened to one run of text.
enum WordDiffOp { equal, inserted, removed }

/// One run of the result: its text and what happened to it.
class WordDiffSegment {
  const WordDiffSegment(this.op, this.text);

  final WordDiffOp op;
  final String text;

  @override
  bool operator ==(Object other) =>
      other is WordDiffSegment && other.op == op && other.text == text;

  @override
  int get hashCode => Object.hash(op, text);

  @override
  String toString() => 'WordDiffSegment(${op.name}, "$text")';
}

/// Above this many token pairs the table gets too big for a phone; the diff
/// then reports the whole text as replaced. A mail preview is far below it.
const int kWordDiffMaxCells = 400000;

// Whitespace runs, words (letters, digits, inner apostrophes and hyphens),
// and every other character on its own, so "Monday," -> "Tuesday," marks the
// word and keeps the comma.
final RegExp _token = RegExp(
  r"\s+|[\p{L}\p{N}_]+(?:['’\-][\p{L}\p{N}_]+)*|[^\s]",
  unicode: true,
);

/// Words, punctuation and the whitespace runs between them, in order. Joining the result
/// gives the input back exactly.
List<String> wordDiffTokens(String text) => <String>[
  for (final Match m in _token.allMatches(text)) m.group(0)!,
];

/// The word diff from [before] to [after].
///
/// Joining every `equal` and `inserted` segment gives [after]; joining every
/// `equal` and `removed` segment gives [before]. Where one place changed,
/// the removed run comes first, then the inserted one. Adjacent runs of the
/// same kind are merged.
List<WordDiffSegment> wordDiff(String before, String after) {
  if (before == after) {
    return before.isEmpty
        ? const <WordDiffSegment>[]
        : <WordDiffSegment>[WordDiffSegment(WordDiffOp.equal, before)];
  }
  final List<String> a = wordDiffTokens(before);
  final List<String> b = wordDiffTokens(after);

  // Common head and tail are cheap to strip and keep the table small.
  int head = 0;
  while (head < a.length && head < b.length && a[head] == b[head]) {
    head++;
  }
  int tail = 0;
  while (tail < a.length - head &&
      tail < b.length - head &&
      a[a.length - 1 - tail] == b[b.length - 1 - tail]) {
    tail++;
  }
  final List<String> midA = a.sublist(head, a.length - tail);
  final List<String> midB = b.sublist(head, b.length - tail);

  final _Builder out = _Builder();
  for (int i = 0; i < head; i++) {
    out.add(WordDiffOp.equal, a[i]);
  }
  if (midA.length * midB.length > kWordDiffMaxCells) {
    out.add(WordDiffOp.removed, midA.join());
    out.add(WordDiffOp.inserted, midB.join());
  } else {
    _lcsInto(midA, midB, out);
  }
  for (int i = a.length - tail; i < a.length; i++) {
    out.add(WordDiffOp.equal, a[i]);
  }
  return out.result();
}

/// True when [segments] hold a change at all.
bool wordDiffHasChanges(List<WordDiffSegment> segments) =>
    segments.any((WordDiffSegment s) => s.op != WordDiffOp.equal);

void _lcsInto(List<String> a, List<String> b, _Builder out) {
  final int m = a.length;
  final int n = b.length;
  // dp[i][j]: LCS length of a[i..] and b[j..], so the walk goes forward.
  final List<List<int>> dp = List<List<int>>.generate(
    m + 1,
    (_) => List<int>.filled(n + 1, 0),
  );
  for (int i = m - 1; i >= 0; i--) {
    for (int j = n - 1; j >= 0; j--) {
      dp[i][j] = a[i] == b[j]
          ? dp[i + 1][j + 1] + 1
          : (dp[i + 1][j] >= dp[i][j + 1] ? dp[i + 1][j] : dp[i][j + 1]);
    }
  }
  int i = 0;
  int j = 0;
  final StringBuffer removed = StringBuffer();
  final StringBuffer inserted = StringBuffer();
  void flush() {
    if (removed.isNotEmpty) out.add(WordDiffOp.removed, removed.toString());
    if (inserted.isNotEmpty) out.add(WordDiffOp.inserted, inserted.toString());
    removed.clear();
    inserted.clear();
  }

  while (i < m && j < n) {
    if (a[i] == b[j]) {
      flush();
      out.add(WordDiffOp.equal, a[i]);
      i++;
      j++;
    } else if (dp[i + 1][j] >= dp[i][j + 1]) {
      removed.write(a[i]);
      i++;
    } else {
      inserted.write(b[j]);
      j++;
    }
  }
  while (i < m) {
    removed.write(a[i]);
    i++;
  }
  while (j < n) {
    inserted.write(b[j]);
    j++;
  }
  flush();
}

/// Merges runs of the same kind. A lone whitespace run between two changes
/// of the same kind joins them, so "a b c" -> "x y z" reads as one removed
/// and one inserted run, not three of each.
class _Builder {
  final List<WordDiffSegment> _out = <WordDiffSegment>[];

  void add(WordDiffOp op, String text) {
    if (text.isEmpty) return;
    if (_out.isNotEmpty && _out.last.op == op) {
      _out[_out.length - 1] = WordDiffSegment(op, _out.last.text + text);
      return;
    }
    _out.add(WordDiffSegment(op, text));
  }

  List<WordDiffSegment> result() {
    // Fold "removed, equal-space, inserted, removed, equal-space, inserted"
    // into "removed, inserted" where the equal run is whitespace only.
    final List<WordDiffSegment> merged = <WordDiffSegment>[];
    int k = 0;
    while (k < _out.length) {
      final WordDiffSegment s = _out[k];
      if (s.op == WordDiffOp.equal) {
        merged.add(s);
        k++;
        continue;
      }
      final StringBuffer removed = StringBuffer();
      final StringBuffer inserted = StringBuffer();
      int end = k;
      while (end < _out.length) {
        final WordDiffSegment cur = _out[end];
        if (cur.op == WordDiffOp.removed) {
          removed.write(cur.text);
          end++;
        } else if (cur.op == WordDiffOp.inserted) {
          inserted.write(cur.text);
          end++;
        } else if (cur.text.trim().isEmpty &&
            end + 1 < _out.length &&
            _out[end + 1].op != WordDiffOp.equal &&
            removed.isNotEmpty &&
            inserted.isNotEmpty) {
          // A shared space between two replaced words belongs to both.
          removed.write(cur.text);
          inserted.write(cur.text);
          end++;
        } else {
          break;
        }
      }
      if (removed.isNotEmpty) {
        merged.add(WordDiffSegment(WordDiffOp.removed, removed.toString()));
      }
      if (inserted.isNotEmpty) {
        merged.add(WordDiffSegment(WordDiffOp.inserted, inserted.toString()));
      }
      k = end;
    }
    return merged;
  }
}
