/// The lab's logo in front of a model's name, as the model menu shows it.
///
/// The SVGs in `assets/model_logos/` are the same files the website uses
/// (chuk.chat `static/logos/models/`), so the app and the site draw the same
/// marks. They are bundled: nothing is fetched at run time. Each one is drawn
/// as a single-colour silhouette in the colour of the row's text, the way the
/// website masks them, so a brand's own colours never enter the menu.
library;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// The lab prefix of a model id (`deepseek/…`) → the logo file stem.
const Map<String, String> kModelLogoByLab = <String, String>{
  'deepseek': 'deepseek',
  'moonshotai': 'moonshot',
  'qwen': 'qwen',
  'z-ai': 'zai',
  'minimax': 'minimax',
  'mistralai': 'mistral',
  'openai': 'openai',
  'meta-llama': 'meta',
  'google': 'google',
  'xiaomi': 'xiaomi',
  'black-forest-labs': 'bfl',
};

/// The bundled logo for [modelId], or null when its lab has no logo.
///
/// `moonshotai/kimi-k3` → `assets/model_logos/moonshot.svg`.
String? modelLogoAsset(String modelId) {
  final int slash = modelId.indexOf('/');
  if (slash <= 0) return null;
  final String? stem =
      kModelLogoByLab[modelId.substring(0, slash).trim().toLowerCase()];
  return stem == null ? null : 'assets/model_logos/$stem.svg';
}

/// A model row's leading glyph: the lab logo at [logoSize] inside a
/// [size] box, tinted [color]. A model whose lab has no logo keeps the empty
/// box, so every name in the list starts at the same x.
class ModelLogo extends StatelessWidget {
  const ModelLogo({
    super.key,
    required this.modelId,
    required this.color,
    this.size = 18,
    this.logoSize = 14,
  });

  final String modelId;
  final Color color;

  /// The slot, the same width as the icon column of the other menu rows.
  final double size;

  /// The drawn mark. Smaller than the slot: a logo fills its viewBox edge to
  /// edge, where a line icon leaves air, so 14 in 18 reads as the same weight.
  final double logoSize;

  @override
  Widget build(BuildContext context) {
    final String? asset = modelLogoAsset(modelId);
    return SizedBox.square(
      dimension: size,
      child: asset == null
          ? null
          : Center(
              child: SizedBox.square(
                dimension: logoSize,
                child: SvgPicture.asset(
                  asset,
                  width: logoSize,
                  height: logoSize,
                  fit: BoxFit.contain,
                  excludeFromSemantics: true,
                  colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
                ),
              ),
            ),
    );
  }
}
