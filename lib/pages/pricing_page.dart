// AGENTS STUB. Upstream: chuk_chat/lib/pages/pricing_page.dart @ d31526a229fdde27c82adf3661d5d3a149db8340.
// Reason: hosted-only — there is no Agents subscription: the agent runs on the
// user's own machine. Shown only when an imported dialog offers an upgrade.
// Keep the public API signature-compatible with upstream so the imported chat UI compiles unchanged. Do not "improve" this file.

import 'package:chuk_chat/pages/coming_soon_page.dart';
import 'package:flutter/material.dart';

class PricingPage extends StatelessWidget {
  const PricingPage({super.key});

  @override
  Widget build(BuildContext context) => const ComingSoonPage(title: 'Plans');
}
