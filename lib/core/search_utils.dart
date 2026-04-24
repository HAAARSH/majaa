/// Tokenized search helpers.
///
/// A query is split on whitespace; every non-empty token must appear in at
/// least one of the haystack fields (case-insensitive). So "kick 50 cool"
/// matches "RO COOL KICK 50ML" because each of the three tokens is a
/// substring of the combined field text.
library;

List<String> _tokenize(String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return const [];
  return q.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
}

/// Returns true when every token in [query] is a substring of at least one
/// of the given [fields]. Empty / whitespace-only queries match everything.
bool tokenMatch(String query, List<String?> fields) {
  final tokens = _tokenize(query);
  if (tokens.isEmpty) return true;
  final haystacks =
      fields.map((f) => (f ?? '').toLowerCase()).toList(growable: false);
  for (final token in tokens) {
    var hit = false;
    for (final h in haystacks) {
      if (h.contains(token)) {
        hit = true;
        break;
      }
    }
    if (!hit) return false;
  }
  return true;
}

/// Convenience for single-field token matching.
bool tokenMatchSingle(String query, String? field) =>
    tokenMatch(query, [field]);

/// Loose match: returns true if AT LEAST ONE token in [query] is a
/// substring of any field. Useful as a fallback when the strict
/// every-token match returns nothing — lets a misspelled / over-typed
/// query like "vishal kumar enterprises" still surface a customer named
/// just "Kumar Stores".
bool tokenMatchAny(String query, List<String?> fields) {
  final tokens = _tokenize(query);
  if (tokens.isEmpty) return true;
  final haystacks =
      fields.map((f) => (f ?? '').toLowerCase()).toList(growable: false);
  for (final token in tokens) {
    for (final h in haystacks) {
      if (h.contains(token)) return true;
    }
  }
  return false;
}

/// Tokens of a query — useful for callers that build custom matchers.
List<String> searchTokens(String query) => _tokenize(query);
