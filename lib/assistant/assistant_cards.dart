import 'package:flutter/material.dart';

import 'package:chuk_chat/assistant/assistant_bridge.dart';
import 'package:chuk_chat/assistant/assistant_result.dart';
import 'package:chuk_chat/widgets/icons/icon_map.dart';

/// Renders one [AssistantCard]. Every colour comes from the running theme, so
/// the surface follows whatever accent and background the user picked in Chuk
/// Chat instead of carrying its own palette.
class AssistantCardView extends StatelessWidget {
  const AssistantCardView({super.key, required this.card});

  final AssistantCard card;

  @override
  Widget build(BuildContext context) => switch (card) {
    final AssistantPlacesCard places => _PlacesCardView(card: places),
    final AssistantLinksCard links => _LinksCardView(card: links),
    final AssistantActionCard action => _ActionCardView(card: action),
    final AssistantFactsCard facts => _FactsCardView(card: facts),
  };
}

class _CardHeader extends StatelessWidget {
  const _CardHeader({required this.icon, required this.title, this.trailing});

  final IconData icon;
  final String title;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          AppIcon(icon, size: 16, color: scheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: scheme.onSurface,
                fontSize: 13,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.2,
              ),
            ),
          ),
          if (trailing != null)
            Text(
              trailing!,
              style: TextStyle(
                color: scheme.onSurfaceVariant,
                fontSize: 12,
              ),
            ),
        ],
      ),
    );
  }
}

class _PlacesCardView extends StatelessWidget {
  const _PlacesCardView({required this.card});

  final AssistantPlacesCard card;

  /// More than this and the surface stops being a glance.
  static const int _maxRows = 5;

  @override
  Widget build(BuildContext context) {
    final shown = card.places.take(_maxRows).toList(growable: false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _CardHeader(
          icon: Icons.place_outlined,
          title: card.title,
          trailing: card.places.length > shown.length
              ? '${shown.length}/${card.places.length}'
              : null,
        ),
        for (var i = 0; i < shown.length; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          _PlaceRow(place: shown[i]),
        ],
      ],
    );
  }
}

class _PlaceRow extends StatelessWidget {
  const _PlaceRow({required this.place});

  final AssistantPlace place;

  Future<void> _navigate() async {
    try {
      await AssistantBridge.openMaps(
        query: place.address.isNotEmpty
            ? '${place.name}, ${place.address}'
            : place.name,
        latitude: place.latitude,
        longitude: place.longitude,
      );
    } catch (_) {
      // No native channel (or no maps app). The row simply does nothing.
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final meta = <String>[
      if (place.cuisine.isNotEmpty) place.cuisine,
      if (place.priceRange.isNotEmpty) place.priceRange,
      if (place.openingHours.isNotEmpty) place.openingHours,
    ].join(' · ');

    return InkWell(
      onTap: _navigate,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    place.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: scheme.onSurface,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      height: 1.25,
                    ),
                  ),
                  if (place.address.isNotEmpty)
                    Text(
                      place.address,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 12,
                        height: 1.35,
                      ),
                    ),
                  if (meta.isNotEmpty)
                    Text(
                      meta,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: scheme.onSurfaceVariant.withValues(alpha: 0.75),
                        fontSize: 12,
                        height: 1.35,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            if (place.rating != null)
              _RatingChip(
                rating: place.rating!,
                reviewCount: place.reviewCount,
              ),
            if (place.hasCoordinates)
              Padding(
                padding: const EdgeInsets.only(left: 6, top: 2),
                child: AppIcon(
                  Icons.navigation_outlined,
                  size: 16,
                  color: scheme.primary,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _RatingChip extends StatelessWidget {
  const _RatingChip({required this.rating, this.reviewCount});

  final double rating;
  final int? reviewCount;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppIcon(Icons.star_rounded, size: 13, color: scheme.primary),
          const SizedBox(width: 3),
          Text(
            rating.toStringAsFixed(1),
            style: TextStyle(
              color: scheme.primary,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (reviewCount != null && reviewCount! > 0) ...[
            const SizedBox(width: 4),
            Text(
              '($reviewCount)',
              style: TextStyle(
                color: scheme.primary.withValues(alpha: 0.7),
                fontSize: 11,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _LinksCardView extends StatelessWidget {
  const _LinksCardView({required this.card});

  final AssistantLinksCard card;

  static const int _maxRows = 4;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final shown = card.links.take(_maxRows).toList(growable: false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _CardHeader(icon: Icons.travel_explore_outlined, title: card.title),
        for (var i = 0; i < shown.length; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                shown[i].title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: scheme.onSurface,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  height: 1.25,
                ),
              ),
              if (shown[i].snippet.isNotEmpty)
                Text(
                  shown[i].snippet,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 12,
                    height: 1.35,
                  ),
                ),
              Text(
                _host(shown[i].url),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: scheme.primary.withValues(alpha: 0.85),
                  fontSize: 11,
                  height: 1.5,
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  static String _host(String url) {
    final parsed = Uri.tryParse(url);
    final host = parsed?.host ?? '';
    return host.isEmpty ? url : host;
  }
}

class _ActionCardView extends StatelessWidget {
  const _ActionCardView({required this.card});

  final AssistantActionCard card;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Container(
          width: 36,
          height: 36,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: scheme.primary.withValues(alpha: 0.16),
          ),
          child: AppIcon(card.icon, size: 18, color: scheme.primary),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                card.label,
                style: TextStyle(
                  color: scheme.onSurface,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (card.detail.isNotEmpty)
                Text(
                  card.detail,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 12,
                    height: 1.35,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _FactsCardView extends StatelessWidget {
  const _FactsCardView({required this.card});

  final AssistantFactsCard card;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _CardHeader(icon: card.icon, title: card.title),
        if (card.body.trim().isNotEmpty)
          Text(
            card.body.trim(),
            style: TextStyle(
              color: scheme.onSurfaceVariant,
              fontSize: 13,
              height: 1.4,
            ),
          ),
      ],
    );
  }
}
