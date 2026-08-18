// lib/utils/phone_linkify.dart
//
// Turns bare phone numbers in AI markdown into `tel:` links so a tap opens
// the dialer instead of the number sitting there as dead text.
//
// The model writes numbers as prose ("**+41 61 317 40 00**"), not as markdown
// links, so the renderer has to find them. The scan skips every region where a
// digit run is not a phone number: fenced code, inline code, existing links,
// autolinks and bare URLs.
//
// Only international numbers (leading `+`) are linked. A national form like
// "061 317 40 00" is indistinguishable from an order number or a grouped
// amount ("12 000 000 000"), and a wrong dialer link is worse than plain text.

/// One pass over the text. Each alternative is a region copied through
/// untouched, except the last one — the phone number itself.
///
/// Order matters: the skip regions come first, so a number inside a code
/// span or an existing link is consumed by that alternative and never
/// reaches the phone branch.
final RegExp _scanPattern = RegExp(
  // Fenced code blocks.
  r'```[\s\S]*?```'
  r'|~~~[\s\S]*?~~~'
  // Inline code span.
  r'|`[^`\n]*`'
  // Markdown link or image — including one that is already `tel:`.
  r'|!?\[[^\]\n]*\]\([^)\n]*\)'
  // Whole visual-output block (<map>…</map>, <chart>…</chart>, …). The JSON
  // between the tags holds phone values that must NOT become link syntax, or
  // the block stops parsing. Skip the tag AND its body in one go.
  r'|<(map|chart|image|weather|news|email|diff)\b[^>]*>[\s\S]*?</\1>'
  // Autolink or raw tag.
  r'|<[^>\s]+>'
  // Bare URL.
  r'|(?:https?://|www\.)\S+'
  // Phone number: `+`, country code, then digits and the usual separators,
  // ending on a digit.
  r'|(?<phone>(?<![\w+./-])\+\d[\d ()./-]{4,20}\d)',
  multiLine: true,
);

/// Digit count of a dialable international number, per E.164.
const int _minDigits = 7;
const int _maxDigits = 15;

/// Rewrites every bare phone number in [markdown] as `[display](tel:+…)`.
///
/// The display text stays exactly as written, so grouping like
/// `+41 61 317 40 00` survives; only the `tel:` target is normalised to
/// digits with a leading `+`.
String linkifyPhoneNumbers(String markdown) {
  // Cheap bail-out: no international prefix, nothing to link.
  if (!markdown.contains('+')) return markdown;

  final buffer = StringBuffer();
  var lastEnd = 0;

  for (final match in _scanPattern.allMatches(markdown)) {
    buffer.write(markdown.substring(lastEnd, match.start));
    lastEnd = match.end;

    final phone = match.namedGroup('phone');
    if (phone == null) {
      // A skip region — copy it through unchanged.
      buffer.write(match[0]);
      continue;
    }

    final uri = telUriForDisplay(phone);
    if (uri == null) {
      buffer.write(phone);
      continue;
    }
    buffer
      ..write('[')
      ..write(phone)
      ..write('](')
      ..write(uri)
      ..write(')');
  }

  buffer.write(markdown.substring(lastEnd));
  return buffer.toString();
}

/// Normalises a written number to a `tel:` URI, or returns `null` when the
/// digit run is not a plausible phone number (too short or too long).
String? telUriForDisplay(String display) {
  final digits = display.replaceAll(RegExp(r'[^0-9]'), '');
  if (digits.length < _minDigits || digits.length > _maxDigits) return null;
  return 'tel:+$digits';
}
