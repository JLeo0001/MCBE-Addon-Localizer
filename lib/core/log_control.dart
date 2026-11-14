import 'package:flutter/foundation.dart';

/// Append-only log buffer shared between services and the log panel.
class LogControl extends ChangeNotifier {
  LogControl({this.maxLines = 800});

  final int maxLines;
  final List<String> _lines = <String>[];

  List<String> get lines => List<String>.unmodifiable(_lines);
  String get text => _lines.join('\n');

  void add(String message) {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final stamp = '${two(now.hour)}:${two(now.minute)}:${two(now.second)}';
    _lines.add('[$stamp] $message');
    if (_lines.length > maxLines) {
      _lines.removeRange(0, _lines.length - maxLines);
    }
    notifyListeners();
  }

  void clear() {
    _lines.clear();
    notifyListeners();
  }
}
