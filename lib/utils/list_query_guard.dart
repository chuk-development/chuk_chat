// Heuristics for detecting open-ended model/product list requests and
// verifying whether the model ran the required discovery searches.

/// Check if the user message appears to be an open-ended product/model list
/// request that requires thorough web research.
bool isOpenEndedModelListQuery(String userMessage) {
  final msg = userMessage.toLowerCase();

  const listHints = <String>[
    'list',
    'all ',
    ' alle ',
    'models',
    'modelle',
    'series',
    'serie',
    'lineup',
    'starting from',
    'ab ',
    'seit ',
    'from ',
  ];

  const modelHints = <String>[
    'model',
    'phone',
    'smartphone',
    'product',
    'version',
    'generation',
    'reihe',
    'devices',
  ];

  final hasListHint = listHints.any((h) => msg.contains(h));
  final hasModelHint = modelHints.any((h) => msg.contains(h));
  return hasListHint && hasModelHint;
}

/// Check if the search queries include both latest-discovery and
/// lineup-discovery searches.
bool hasMandatoryCoverageSearches(List<String> searchQueries) {
  if (searchQueries.isEmpty) return false;

  final hasLatestSearch = searchQueries.any(isLatestDiscoveryQuery);
  final hasLineupSearch = searchQueries.any(isLineupDiscoveryQuery);

  return hasLatestSearch && hasLineupSearch;
}

/// Check if a query is searching for the latest/newest generation.
bool isLatestDiscoveryQuery(String query) {
  final q = query.toLowerCase();

  const latestTerms = <String>[
    'latest',
    'newest',
    'current',
    'most recent',
    'neueste',
    'neuesten',
    'aktuell',
    'aktuelle',
  ];

  final hasLatestKeyword = latestTerms.any((term) => q.contains(term));
  final hasYear = RegExp(r'\b20\d{2}\b').hasMatch(q);

  return hasLatestKeyword || (hasYear && q.contains('model'));
}

/// Check if a query is searching for the full lineup/variants.
bool isLineupDiscoveryQuery(String query) {
  final q = query.toLowerCase();

  const lineupTerms = <String>[
    'lineup',
    'all models',
    'all model',
    'full list',
    'complete list',
    'variants',
    'varianten',
    'series list',
  ];

  if (lineupTerms.any((term) => q.contains(term))) return true;
  return RegExp(r'\ball\b.*\b(models?|variants?)\b').hasMatch(q);
}

/// Build instruction for when the model needs to do coverage searches first.
String buildListCoverageRepairInstruction(String userRequest) {
  final escapedRequest = userRequest
      .replaceAll('\\', '\\\\')
      .replaceAll('"', '\\"')
      .replaceAll('\n', '\\n')
      .replaceAll('\r', '\\r')
      .replaceAll('\t', '\\t');

  return 'Quality gate: The user asked for an open-ended model/product list. '
      'Do NOT answer yet. You must discover coverage first.\n\n'
      'User request: "$escapedRequest"\n\n'
      'Required workflow now:\n'
      '1) Search latest/newest generation first.\n'
      '2) Search full lineup/all variants (base, Pro, XL, a, Fold, etc.).\n'
      '3) Then gather the requested attribute for each model in scope.\n'
      '4) Only then provide the final list.\n\n'
      'Do not assume from memory. Use web_search to verify completeness.';
}
