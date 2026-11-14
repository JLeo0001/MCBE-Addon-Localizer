import 'package:flutter/material.dart';

import '../core/config.dart';
import '../core/health.dart';
import '../core/env.dart';

/// Static quality report for the selected mod.
class HealthPage extends StatefulWidget {
  const HealthPage({super.key, required this.config});

  final HubConfig config;

  @override
  State<HealthPage> createState() => _HealthPageState();
}

class _HealthPageState extends State<HealthPage> {
  HealthReport? _report;
  bool _running = false;

  List<String> get _packs => <String>[
        if (Env.resolvePackDir(widget.config.str('resource_pack_path')) != null)
          Env.resolvePackDir(widget.config.str('resource_pack_path'))!,
        if (Env.resolvePackDir(widget.config.str('behavior_pack_path')) != null)
          Env.resolvePackDir(widget.config.str('behavior_pack_path'))!,
      ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  void _run() {
    final packs = _packs;
    if (packs.isEmpty) {
      setState(() => _report = HealthReport(<HealthIssue>[], 0));
      return;
    }
    setState(() => _running = true);
    final report = HealthChecker.run(packs, widget.config.str('target_language'));
    if (!mounted) return;
    setState(() {
      _report = report;
      _running = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final report = _report;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text('对当前模组做一次静态体检：manifest、语言文件、JSON 与图片。',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ),
            IconButton(
              tooltip: '重新检查',
              onPressed: _running ? null : _run,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (_running) const LinearProgressIndicator(minHeight: 4),
        if (report == null)
          const SizedBox.shrink()
        else if (report.packs == 0)
          Expanded(
            child: Center(
              child: Text('当前没有选中模组',
                  style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
            ),
          )
        else ...<Widget>[
          _scoreCard(context, report),
          const SizedBox(height: 12),
          Expanded(
            child: report.issues.isEmpty
                ? Center(
                    child: Text('没有发现问题',
                        style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
                  )
                : ListView.separated(
                    itemCount: report.issues.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (context, index) => _issueCard(context, report.issues[index]),
                  ),
          ),
        ],
      ],
    );
  }

  Widget _scoreCard(BuildContext context, HealthReport report) {
    final scheme = Theme.of(context).colorScheme;
    final color = report.score >= 90
        ? Colors.green
        : report.score >= 70
            ? Colors.orange
            : scheme.error;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: <Widget>[
            SizedBox(
              width: 64,
              height: 64,
              child: Stack(
                alignment: Alignment.center,
                children: <Widget>[
                  SizedBox(
                    width: 64,
                    height: 64,
                    child: CircularProgressIndicator(
                      value: report.score / 100,
                      strokeWidth: 6,
                      backgroundColor: scheme.surfaceContainerHighest,
                      color: color,
                    ),
                  ),
                  Text('${report.score}', style: const TextStyle(fontWeight: FontWeight.bold)),
                ],
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('${report.grade} · ${report.packs} 个包', style: const TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text('错误 ${report.errors} · 警告 ${report.warnings} · 提示 ${report.infos}',
                      style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _issueCard(BuildContext context, HealthIssue issue) {
    final scheme = Theme.of(context).colorScheme;
    final (Color color, IconData icon) = switch (issue.severity) {
      Severity.error => (scheme.error, Icons.error_outline),
      Severity.warning => (Colors.orange, Icons.warning_amber_outlined),
      Severity.info => (scheme.primary, Icons.info_outline),
    };
    return Card(
      child: ListTile(
        leading: Icon(icon, color: color, size: 20),
        title: Text(issue.title, style: const TextStyle(fontSize: 13.5)),
        subtitle: Text(issue.detail,
            maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11.5)),
        dense: true,
      ),
    );
  }
}
