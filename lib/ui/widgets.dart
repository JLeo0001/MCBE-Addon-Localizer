import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/log_control.dart';

export '../core/log_control.dart';

/// Fixed-height scrolling log with copy / clear actions.
class LogPanel extends StatefulWidget {
  const LogPanel({super.key, required this.control, this.height = 190});

  final LogControl control;
  final double height;

  @override
  State<LogPanel> createState() => _LogPanelState();
}

class _LogPanelState extends State<LogPanel> {
  final ScrollController _scroll = ScrollController();
  bool _collapsed = false;

  @override
  void initState() {
    super.initState();
    widget.control.addListener(_onLog);
  }

  @override
  void dispose() {
    widget.control.removeListener(_onLog);
    _scroll.dispose();
    super.dispose();
  }

  void _onLog() {
    if (!mounted) return;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          children: <Widget>[
            IconButton(
              tooltip: _collapsed ? '展开日志' : '收起日志',
              onPressed: () => setState(() => _collapsed = !_collapsed),
              icon: Icon(_collapsed ? Icons.expand_more : Icons.expand_less, size: 20),
              visualDensity: VisualDensity.compact,
            ),
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() => _collapsed = !_collapsed),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text('运行日志${_collapsed ? '（已收起）' : ''}',
                        style: textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: scheme.onSurfaceVariant,
                        )),
                    if (!_collapsed)
                      Text('服务层输出会同步显示在这里',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
                  ],
                ),
              ),
            ),
            if (!_collapsed)
              TextButton.icon(
                onPressed: () async {
                  final messenger = ScaffoldMessenger.of(context);
                  final text = widget.control.text;
                  if (text.trim().isEmpty) {
                    messenger.showSnackBar(const SnackBar(content: Text('日志为空')));
                    return;
                  }
                  await _copy(text);
                  messenger.showSnackBar(const SnackBar(content: Text('日志已复制到剪贴板')));
                },
                icon: const Icon(Icons.content_copy, size: 16),
                label: const Text('复制'),
              ),
            if (!_collapsed)
              IconButton(
                tooltip: '清空日志',
                onPressed: widget.control.clear,
                icon: const Icon(Icons.delete_sweep_outlined, size: 18),
              ),
          ],
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: _collapsed
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Container(
                    height: widget.height,
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerLowest,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: scheme.outlineVariant),
                    ),
                    child: Scrollbar(
                      controller: _scroll,
                      child: ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.all(8),
                        itemCount: widget.control.lines.length,
                        itemBuilder: (context, index) => SelectableText(
                          widget.control.lines[index],
                          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                        ),
                      ),
                    ),
                  ),
                ),
        ),
      ],
    );
  }

  Future<void> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
  }
}

/// Outlined card with a bold title and vertical body.
class SectionCard extends StatelessWidget {
  const SectionCard({super.key, required this.title, required this.children, this.trailing});

  final String title;
  final List<Widget> children;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                ),
                if (trailing != null) trailing!,
              ],
            ),
            const SizedBox(height: 10),
            ...children,
          ],
        ),
      ),
    );
  }
}

/// Progress bar + "done/total" label row.
class ProgressRow extends StatelessWidget {
  const ProgressRow({super.key, required this.value, required this.label});

  final double? value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Expanded(
          child: LinearProgressIndicator(value: value, minHeight: 6, borderRadius: BorderRadius.circular(3)),
        ),
        const SizedBox(width: 10),
        SizedBox(
          width: 90,
          child: Text(label, style: const TextStyle(fontSize: 12), textAlign: TextAlign.end),
        ),
      ],
    );
  }
}

void showToast(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(message), duration: const Duration(seconds: 4)),
  );
}

void showError(BuildContext context, String message) {
  final scheme = Theme.of(context).colorScheme;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(message),
      backgroundColor: scheme.error,
      duration: const Duration(seconds: 6),
    ),
  );
}

Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String yesText = '确认',
  String noText = '取消',
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: message.isEmpty ? null : Text(message),
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(noText)),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(yesText)),
      ],
    ),
  );
  return result ?? false;
}

