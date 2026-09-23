// The specs the goldens are built from, written exactly as an agent would
// emit them. Keeping them here means the golden test and the parsing test
// argue about the same JSON.

/// The picture he showed: Sachsen-Anhalt, party colours, a 5 % rule.
const Map<String, Object?> kSachsenAnhalt = <String, Object?>{
  'kind': 'bar',
  'title': 'Landtagswahl Sachsen-Anhalt',
  'subtitle': 'Vorläufiges Ergebnis, Zweitstimmen in Prozent',
  'unit': '%',
  'decimal_separator': ',',
  'decimals': 1,
  'reference_line': <String, Object?>{'value': 5, 'label': '5 %-Hürde'},
  'source': 'Landeswahlleiter Sachsen-Anhalt',
  'retrieved_at': '2026-09-12T20:15:00',
  'points': <Map<String, Object?>>[
    <String, Object?>{'label': 'AfD', 'value': 43.8, 'color': '#009EE0'},
    <String, Object?>{'label': 'CDU', 'value': 17.2, 'color': '#32302E'},
    <String, Object?>{'label': 'SPD', 'value': 9.3, 'color': '#E3000F'},
    <String, Object?>{'label': 'Grüne', 'value': 8.9, 'color': '#46962B'},
    <String, Object?>{'label': 'Linke', 'value': 8.6, 'color': '#BE3075'},
    <String, Object?>{'label': 'BSW', 'value': 5.3, 'color': '#792350'},
    <String, Object?>{'label': 'FDP', 'value': 2.6, 'color': '#FFED00'},
    <String, Object?>{'label': 'FW', 'value': 1.2, 'color': '#FF8000'},
    <String, Object?>{'label': 'Tierschutz', 'value': 1.1, 'color': '#00543D'},
    <String, Object?>{'label': 'Sonst.', 'value': 2.1, 'color': '#8C8C8C'},
  ],
};

/// The other half of his picture: what each party won or lost.
const Map<String, Object?> kGainsAndLosses = <String, Object?>{
  'kind': 'column_delta',
  'title': 'Gewinne und Verluste',
  'subtitle': 'Veränderung gegenüber 2021, in Prozentpunkten',
  'unit': '%',
  'decimal_separator': ',',
  'decimals': 1,
  'source': 'Landeswahlleiter Sachsen-Anhalt',
  'points': <Map<String, Object?>>[
    <String, Object?>{'label': 'AfD', 'value': 22.4},
    <String, Object?>{'label': 'CDU', 'value': -19.8},
    <String, Object?>{'label': 'SPD', 'value': 0.2},
    <String, Object?>{'label': 'Grüne', 'value': 3.0},
    <String, Object?>{'label': 'Linke', 'value': -2.4},
    <String, Object?>{'label': 'BSW', 'value': 5.3},
    <String, Object?>{'label': 'FDP', 'value': -3.7},
    <String, Object?>{'label': 'FW', 'value': -1.7},
  ],
};

/// A crypto week: one coin up, one down, the theme's pair doing the talking.
const Map<String, Object?> kCryptoWeek = <String, Object?>{
  'kind': 'line',
  'title': 'BTC und ETH, 7 Tage',
  'subtitle': 'Schlusskurs je Tag',
  'unit': r'$',
  'source': 'Crypto.com',
  'retrieved_at': '2026-09-12T20:15:00',
  'series': <Map<String, Object?>>[
    <String, Object?>{
      'name': 'BTC',
      'direction': 'up',
      'points': <Map<String, Object?>>[
        <String, Object?>{'label': 'Fr', 'value': 61200},
        <String, Object?>{'label': 'Sa', 'value': 60450},
        <String, Object?>{'label': 'So', 'value': 62100},
        <String, Object?>{'label': 'Mo', 'value': 63750},
        <String, Object?>{'label': 'Di', 'value': 63100},
        <String, Object?>{'label': 'Mi', 'value': 65400},
        <String, Object?>{'label': 'Do', 'value': 67980},
      ],
    },
    <String, Object?>{
      'name': 'ETH ×20',
      'direction': 'down',
      'points': <Map<String, Object?>>[
        <String, Object?>{'label': 'Fr', 'value': 68200},
        <String, Object?>{'label': 'Sa', 'value': 67100},
        <String, Object?>{'label': 'So', 'value': 65900},
        <String, Object?>{'label': 'Mo', 'value': 66300},
        <String, Object?>{'label': 'Di', 'value': 63400},
        <String, Object?>{'label': 'Mi', 'value': 61800},
        <String, Object?>{'label': 'Do', 'value': 59950},
      ],
    },
  ],
};

/// A malformed spec: the right idea, none of it usable.
const Map<String, Object?> kMalformed = <String, Object?>{
  'kind': 'bar',
  'title': 'Umsatz nach Quartal',
  'points': <Map<String, Object?>>[
    <String, Object?>{'label': 'Q1', 'value': 'viel'},
    <String, Object?>{'label': 'Q2'},
    <String, Object?>{'value': null},
  ],
};

/// Two series side by side — the cheap kind that fell out of the same model.
const Map<String, Object?> kGrouped = <String, Object?>{
  'kind': 'grouped',
  'title': 'Downloads je Plattform',
  'unit': 'k',
  'series': <Map<String, Object?>>[
    <String, Object?>{
      'name': 'iOS',
      'color': '#2962FF',
      'points': <Map<String, Object?>>[
        <String, Object?>{'label': 'Jun', 'value': 12.4},
        <String, Object?>{'label': 'Jul', 'value': 15.1},
        <String, Object?>{'label': 'Aug', 'value': 18.9},
        <String, Object?>{'label': 'Sep', 'value': 22.3},
      ],
    },
    <String, Object?>{
      'name': 'Android',
      'color': '#00C853',
      'points': <Map<String, Object?>>[
        <String, Object?>{'label': 'Jun', 'value': 9.8},
        <String, Object?>{'label': 'Jul', 'value': 11.2},
        <String, Object?>{'label': 'Aug', 'value': 16.4},
        <String, Object?>{'label': 'Sep', 'value': 25.7},
      ],
    },
  ],
};

/// The same election with the rule high up: at 40 % only the winner's bar is
/// anywhere near it, so the label has to find a corner it does not usually
/// use.
final Map<String, Object?> kHighReference = <String, Object?>{
  ...kSachsenAnhalt,
  'title': 'Landtagswahl Sachsen-Anhalt',
  'subtitle': 'Zweitstimmen, mit der Marke für die absolute Mehrheit',
  'reference_line': <String, Object?>{'value': 40, 'label': 'Regierungsmarke'},
};

/// Gains and losses with a rule BELOW zero: the label has the whole upper
/// half free and the bottom half full of losing bars.
final Map<String, Object?> kGainsAndLossesWithRule = <String, Object?>{
  ...kGainsAndLosses,
  'reference_line': <String, Object?>{'value': -2, 'label': '−2 Punkte'},
};
