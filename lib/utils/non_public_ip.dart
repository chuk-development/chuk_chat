// lib/utils/non_public_ip.dart
//
// Whether an IP address points into a private, loopback, link-local or
// otherwise non-public network. Pure byte logic, no dart:io — usable on
// every platform and inside isolates.
//
// The same classes of address that the fetch tool refuses
// (lib/tool_handlers/file_fetch_tools.dart); kept as a shared helper so
// image loading can hold AI-supplied URLs to the same rule without going
// through a tool call.

/// True when [ip] must not be connected to on behalf of model-supplied URLs.
bool isNonPublicIp(List<int> ip) {
  if (ip.length == 4) {
    final int a = ip[0], b = ip[1];
    return a == 0 ||
        a == 10 ||
        a == 127 ||
        (a == 100 && b >= 64 && b <= 127) || // CGNAT 100.64/10
        (a == 169 && b == 254) || // link-local
        (a == 172 && b >= 16 && b <= 31) || // private 172.16/12
        (a == 192 && b == 168) || // private 192.168/16
        (a == 198 && (b == 18 || b == 19)) || // benchmark 198.18/15
        a >= 224; // multicast and reserved
  }
  if (ip.length == 16) {
    final bool allZeroHead = ip.sublist(0, 10).every((int x) => x == 0);
    // IPv4-mapped (::ffff:a.b.c.d) and IPv4-compatible (::a.b.c.d).
    if (allZeroHead &&
        ((ip[10] == 0xff && ip[11] == 0xff) || (ip[10] == 0 && ip[11] == 0))) {
      final List<int> v4 = ip.sublist(12);
      if (ip[10] == 0 && v4.every((int x) => x == 0)) return true; // ::
      if (ip[10] == 0 && v4[0] == 0 && v4[1] == 0 && v4[2] == 0) {
        return true; // ::1 and friends
      }
      return isNonPublicIp(v4);
    }
    // NAT64 well-known prefix 64:ff9b::/96 — the last four bytes are IPv4.
    if (ip[0] == 0x00 &&
        ip[1] == 0x64 &&
        ip[2] == 0xff &&
        ip[3] == 0x9b &&
        ip.sublist(4, 12).every((int x) => x == 0)) {
      return isNonPublicIp(ip.sublist(12));
    }
    // 6to4 2002::/16 — bytes 2..5 are the embedded IPv4 address.
    if (ip[0] == 0x20 && ip[1] == 0x02) {
      return isNonPublicIp(ip.sublist(2, 6));
    }
    return (ip[0] & 0xfe) == 0xfc || // fc00::/7 unique local
        (ip[0] == 0xfe && (ip[1] & 0xc0) == 0x80) || // fe80::/10 link-local
        (ip[0] == 0xfe && (ip[1] & 0xc0) == 0xc0) || // fec0::/10 site-local
        ip[0] == 0xff; // multicast
  }
  return true;
}
