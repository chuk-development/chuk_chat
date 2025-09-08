import 'package:flutter/material.dart';
import 'dart:async'; // For the timer
import 'dart:math'; // For min/max/round and Random

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Responsive Progress UI Demo',
      theme: ThemeData(
        brightness: Brightness.dark,
        primarySwatch: Colors.blue,
        scaffoldBackgroundColor: const Color(0xFF1C1C1C),
      ),
      home: const DynamicProgressScreen(),
    );
  }
}

class DynamicProgressScreen extends StatefulWidget {
  const DynamicProgressScreen({super.key});

  @override
  State<DynamicProgressScreen> createState() => _DynamicProgressScreenState();
}

class _DynamicProgressScreenState extends State<DynamicProgressScreen> {
  late Timer _countdownTimer;
  Timer? _progressTimer;
  int _secondsRemaining = 17;
  double _rawProgress = 0.0;

  static const int _rows = 5;
  static const double _dotSize = 3.0;
  static const double _dotSpacing = 3.0;

  final Random _random = Random();
  late List<double> _rowProgressOffsets;
  late List<int> _currentFilledDotCounts;
  static const double _maxRandomOffset = 0.20;
  static const int _randomUpdateInterval = 20;
  int _randomUpdateCounter = 0;

  int _actualDotsPerRow = 0;

  @override
  void initState() {
    super.initState();
    _currentFilledDotCounts = List.generate(_rows, (index) => 0);
    _generateRandomRowOffsets();
    _startCountdownTimer();
  }

  void _generateRandomRowOffsets() {
    _rowProgressOffsets = List.generate(
      _rows,
      (index) =>
          _random.nextDouble() * (_maxRandomOffset * 2) - _maxRandomOffset,
    );
  }

  void _startCountdownTimer() {
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_secondsRemaining > 0) {
        setState(() {
          _secondsRemaining--;
        });
      } else {
        _countdownTimer.cancel();
      }
    });
  }

  void _startProgressBar() {
    _progressTimer?.cancel();

    const Duration progressDuration = Duration(seconds: 30);
    const int updateIntervalMs = 50;
    final int totalUpdates = progressDuration.inMilliseconds ~/ updateIntervalMs;
    int currentUpdate = 0;

    _progressTimer = Timer.periodic(
        const Duration(milliseconds: updateIntervalMs), (timer) {
      if (_rawProgress < 1.0) {
        setState(() {
          currentUpdate++;
          _rawProgress = (currentUpdate / totalUpdates).clamp(0.0, 1.0);

          _randomUpdateCounter++;
          if (_randomUpdateCounter >= _randomUpdateInterval) {
            _generateRandomRowOffsets();
            _randomUpdateCounter = 0;
          }

          for (int r = 0; r < _rows; r++) {
            final double randomOffset = _rowProgressOffsets[r];
            final double adjustedProgress =
                (_rawProgress + randomOffset).clamp(0.0, 1.0);

            final int targetFilledDots =
                (_actualDotsPerRow * adjustedProgress).round();

            _currentFilledDotCounts[r] =
                max(_currentFilledDotCounts[r], targetFilledDots);
          }
        });
      } else {
        setState(() {
          for (int r = 0; r < _rows; r++) {
            _currentFilledDotCounts[r] = _actualDotsPerRow;
          }
          _rawProgress = 1.0;
        });
        _progressTimer?.cancel();
        _progressTimer = null;
      }
    });
  }

  @override
  void dispose() {
    _countdownTimer.cancel();
    _progressTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final double screenWidth = MediaQuery.of(context).size.width;
    final double containerWidth = screenWidth * 0.90;

    final double availableWidthForDots = containerWidth - (2 * 16.0);
    final double effectiveDotItemWidth = _dotSize + _dotSpacing;
    _actualDotsPerRow = (availableWidthForDots / effectiveDotItemWidth).floor();

    if ((_progressTimer == null || !_progressTimer!.isActive) &&
        _actualDotsPerRow > 0) {
      _startProgressBar();
    }

    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: containerWidth,
                padding: const EdgeInsets.all(16.0),
                decoration: BoxDecoration(
                  color: const Color(0xFF2B2B2B),
                  borderRadius: BorderRadius.circular(12.0),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8.0,
                      runSpacing: 4.0,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 8.0,
                              height: 8.0,
                              decoration: const BoxDecoration(
                                color: Colors.green,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 8.0),
                            const Text(
                              'Agents Working',
                              style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 14.0,
                                  fontWeight: FontWeight.w500),
                            ),
                          ],
                        ),
                        const Text(
                          '•',
                          style: TextStyle(color: Colors.grey, fontSize: 14.0),
                        ),
                        const SizedBox(width: 8.0),
                        const Text(
                          'Qwen3 235B A22B Thinking',
                          style: TextStyle(color: Colors.grey, fontSize: 14.0),
                        ),
                        const SizedBox(width: 8.0),
                        const Text(
                          '•',
                          style: TextStyle(color: Colors.grey, fontSize: 14.0),
                        ),
                        const SizedBox(width: 8.0),
                        Text(
                          '${_secondsRemaining}S',
                          style: TextStyle(color: Colors.grey, fontSize: 14.0),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16.0),
                    ProgressDotsGrid(
                      rows: _rows,
                      dotsPerRow: _actualDotsPerRow,
                      dotSize: _dotSize,
                      spacing: _dotSpacing,
                      filledDotCounts: _currentFilledDotCounts,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ProgressDotsGrid extends StatelessWidget {
  final int rows;
  final int dotsPerRow;
  final double dotSize;
  final double spacing;
  final List<int> filledDotCounts;

  const ProgressDotsGrid({
    super.key,
    required this.rows,
    required this.dotsPerRow,
    this.dotSize = 4.0,
    this.spacing = 4.0,
    required this.filledDotCounts,
  });

  @override
  Widget build(BuildContext context) {
    if (dotsPerRow <= 0 || rows <= 0) {
      return const SizedBox();
    }

    // Prepare dot rows
    final List<Widget> dotRows = List.generate(rows, (r) {
      final int filledDotsInThisRow =
          (r < filledDotCounts.length) ? filledDotCounts[r] : 0;

      // Prepare dots for the current row
      final List<Widget> currentRowDots = List.generate(dotsPerRow, (i) {
        final Color dotColor = i < filledDotsInThisRow
            ? const Color.fromARGB(255, 194, 18, 18)
            : const Color(0xFF424242);

        return Container(
          width: dotSize,
          height: dotSize,
          decoration: BoxDecoration(
            color: dotColor,
            shape: BoxShape.circle,
          ),
        );
      });

      // Wrap dots with spacing
      return Padding(
        padding: EdgeInsets.only(bottom: r < rows - 1 ? spacing : 0),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: List.generate(
            currentRowDots.length,
            (index) => Padding(
              padding:
                  EdgeInsets.only(right: index < currentRowDots.length - 1 ? spacing : 0),
              child: currentRowDots[index],
            ),
          ),
        ),
      );
    });

    return Column(children: dotRows);
  }
}