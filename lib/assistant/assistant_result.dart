import 'package:flutter/material.dart';

/// A visual result the assistant surface renders next to (or instead of) the
/// spoken answer.
///
/// Tools build these from the data they already hold. Waiting for the model to
/// copy an address or a rating into a tag costs a round trip and gets it wrong
/// often enough to matter — the same reason `map_tools` builds its own `<map>`
/// block for the chat.
sealed class AssistantCard {
  const AssistantCard();
}

/// One place from the Brave Local proxy.
@immutable
class AssistantPlace {
  const AssistantPlace({
    required this.name,
    this.address = '',
    this.rating,
    this.reviewCount,
    this.openingHours = '',
    this.priceRange = '',
    this.cuisine = '',
    this.description = '',
    this.phone = '',
    this.latitude,
    this.longitude,
  });

  factory AssistantPlace.fromBrave(Map<String, dynamic> raw) {
    String text(String key) => (raw[key] ?? '').toString().trim();
    double? number(String key) {
      final value = raw[key];
      if (value is num) return value.toDouble();
      if (value is String) return double.tryParse(value.trim());
      return null;
    }

    return AssistantPlace(
      name: text('name'),
      address: text('address'),
      rating: number('rating'),
      reviewCount: number('review_count')?.round(),
      openingHours: text('opening_hours'),
      priceRange: text('price_range'),
      cuisine: text('cuisine'),
      description: text('description'),
      phone: text('phone'),
      latitude: number('lat'),
      longitude: number('lon'),
    );
  }

  final String name;
  final String address;
  final double? rating;
  final int? reviewCount;
  final String openingHours;
  final String priceRange;
  final String cuisine;
  final String description;
  final String phone;
  final double? latitude;
  final double? longitude;

  bool get hasCoordinates => latitude != null && longitude != null;
}

/// A list of places — restaurants, shops, anything from a local lookup.
/// Tapping a row hands the place to the device maps app.
class AssistantPlacesCard extends AssistantCard {
  const AssistantPlacesCard({required this.title, required this.places});

  final String title;
  final List<AssistantPlace> places;
}

/// One web result.
@immutable
class AssistantLink {
  const AssistantLink({
    required this.title,
    required this.url,
    this.snippet = '',
  });

  final String title;
  final String url;
  final String snippet;
}

/// Ranked web results from the Brave Search proxy.
class AssistantLinksCard extends AssistantCard {
  const AssistantLinksCard({required this.title, required this.links});

  final String title;
  final List<AssistantLink> links;
}

/// A device action that happened: a timer was set, maps opened, an app
/// launched. Short confirmation, no body text.
class AssistantActionCard extends AssistantCard {
  const AssistantActionCard({
    required this.icon,
    required this.label,
    this.detail = '',
  });

  final IconData icon;
  final String label;
  final String detail;
}

/// Anything with a heading and a block of prepared text — weather, a summary,
/// the current track.
class AssistantFactsCard extends AssistantCard {
  const AssistantFactsCard({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;
}

/// What one tool call produced: the JSON the model reads back, and the card
/// the user sees.
@immutable
class AssistantToolOutcome {
  const AssistantToolOutcome(this.modelResult, {this.card});

  /// JSON-encodable value returned to the model as the `role: "tool"` content.
  final Object? modelResult;

  /// Optional visual result. Null for tools with nothing worth drawing.
  final AssistantCard? card;
}
