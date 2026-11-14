import 'package:flutter/foundation.dart';

import 'log_control.dart';

/// App-wide runner for long localization tasks.
///
/// The job lives here instead of inside a page, so switching tabs, opening
/// settings or going back to the mod list never cancels it — the owning page
/// only renders the shared state.
class TaskCenter extends ChangeNotifier {
  TaskCenter._();

  static final TaskCenter instance = TaskCenter._();

  final LogControl log = LogControl(maxLines: 3000);

  bool _running = false;
  bool _cancelRequested = false;
  double? _progress;
  String _progressLabel = '';
  String _stage = '';

  bool get running => _running;
  bool get cancelRequested => _cancelRequested;
  double? get progress => _progress;
  String get progressLabel => _progressLabel;
  String get stage => _stage;

  void addLog(String message) => log.add(message);

  /// Starts [task] unless something is already running.
  Future<bool> start(String stage, Future<void> Function() task) async {
    if (_running) {
      log.add('已有任务在运行，请等待完成后再试');
      return false;
    }
    _running = true;
    _cancelRequested = false;
    _progress = 0;
    _progressLabel = '';
    _stage = stage;
    notifyListeners();

    try {
      await task();
    } catch (e, st) {
      log.add('发生错误: $e');
      log.add('$st'.split('\n').take(4).join('\n'));
    } finally {
      _running = false;
      _progress = null;
      _progressLabel = '';
      notifyListeners();
    }
    return true;
  }

  void requestCancel() {
    if (!_running) return;
    _cancelRequested = true;
    log.add('已请求停止，当前批次完成后结束');
    notifyListeners();
  }

  void setProgress(int done, int total) {
    _progress = total == 0 ? null : (done / total).clamp(0.0, 1.0);
    _progressLabel = total == 0 ? '' : '$done/$total';
    notifyListeners();
  }

  void setStage(String stage) {
    _stage = stage;
    notifyListeners();
  }

  void resetProgress() {
    _progress = 0;
    _progressLabel = '';
    notifyListeners();
  }
}
