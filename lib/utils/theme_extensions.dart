import 'package:flutter/material.dart';

extension ThemeDataIconColorX on ThemeData {
  Color get resolvedIconColor =>
      iconTheme.color ?? colorScheme.onSurface;
}
