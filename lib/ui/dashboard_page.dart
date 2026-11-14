import 'package:flutter/material.dart';

import '../core/config.dart';
import '../core/env.dart';
import '../core/log_control.dart';
import '../core/projects.dart';
import '../core/task_center.dart';
import 'widgets.dart';

/// Landing screen of the toolbox: what is selected, what is running, and the
/// shortest path to the next action.
class DashboardPage extends StatefulWidget {
  const DashboardPage({
    super.key,
    required this.config,
    required this.onNavigate,
    this.onChanged,
  });

  final HubConfig config;

  /// Switches the toolbox tab (0 = dashboard, 1 = localize, 2 = image,
  /// 3 = tools, 4 = export).
  final ValueChanged<int> onNavigate;

  final VoidCallback? onChanged;

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  HubConfig get _config => widget.config;
  LogControl get _log => TaskCenter.instance.log;
  List<RecentProject> _recent = <RecentProject>[];

  String? get _rp => Env.resolvePackDir(_config.str('resource_pack_path'));
  String? get _bp => Env.resolvePackDir(_config.str('behavior_pack_path'));

  @override
  void initState() {
    super.initState();
    _loadRecent();
  }

  Future<void> _loadRecent() async {
    final store = await RecentProjects.load();
    if (!mounted) return;
    setState(() => _recent = store.items.where((e) => e.exists).take(4).toList());
  }

  Future<void> _open(RecentProject project) async {
    _config.set(project.resourcePack ?? '', 'resource_pack_path');
    _config.set(project.behaviorPack ?? '', 'behavior_pack_path');
    _config.set(project.name, 'current_mod_name');
    await _config.save();
    widget.onChanged?.call();
    if (!mounted) return;
    widget.onNavigate(1);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final name = _config.str('current_mod_name').trim();
    final hasMod = name.isNotEmpty || _rp != null || _bp != null;

    return AnimatedBuilder(
      animation: TaskCenter.instance,
      builder: (context, _) {
        final task = TaskCenter.instance;
        return ListView(
          padding: const EdgeInsets.only(bottom: 24),
          children: <Widget>[
            _header(context, hasMod, name),
            const SizedBox(height: 16),
            if (task.running) _runningCard(context, task),
            if (task.running) const SizedBox(height: 12),
            Text('快捷操作', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            _actions(context),
            if (_recent.isNotEmpty) ...<Widget>[
              const SizedBox(height: 16),
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text('最近打开',
                        style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
                  ),
                  IconButton(
                    tooltip: '刷新',
                    onPressed: _loadRecent,
                    icon: const Icon(Icons.refresh, size: 18),
                  ),
                ],
              ),
              Card(
                child: Column(
                  children: <Widget>[
                    for (var i = 0; i < _recent.length; i++) ...<Widget>[
                      if (i > 0) const Divider(height: 1),
                      ListTile(
                        dense: true,
                        leading: const Icon(Icons.history, size: 18),
                        title: Text(_recent[i].name, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(_ago(_recent[i].openedAt), style: const TextStyle(fontSize: 11)),
                        trailing: const Icon(Icons.chevron_right, size: 16),
                        onTap: () => _open(_recent[i]),
                      ),
                    ],
                  ],
                ),
              ),
            ],
            const SizedBox(height: 16),
            Text('当前模组', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(hasMod ? name : '尚未选择模组',
                        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 10),
                    _pathRow('资源包', _rp),
                    const SizedBox(height: 6),
                    _pathRow('行为包', _bp),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: <Widget>[
                Expanded(
                  child: Text('最近日志',
                      style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
                ),
                TextButton(
                  onPressed: () => widget.onNavigate(1),
                  child: const Text('去本地化'),
                ),
              ],
            ),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    if (_log.lines.isEmpty)
                      Text('暂无日志',
                          style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant))
                    else
                      ..._log.lines.reversed.take(6).toList().reversed.map(
                            (line) => Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: Text(
                                line,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5),
                              ),
                            ),
                          ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  String _ago(DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inHours < 1) return '${diff.inMinutes} 分钟前';
    if (diff.inDays < 1) return '${diff.inHours} 小时前';
    return '${diff.inDays} 天前';
  }

  Widget _header(BuildContext context, bool hasMod, String name) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            hasMod ? name : '选择一个模组开始',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: scheme.onPrimaryContainer),
          ),
          const SizedBox(height: 4),
          Text(
            hasMod ? '${_rp == null ? '无资源包' : '有资源包'} · ${_bp == null ? '无行为包' : '有行为包'}'
                : '在首屏选择模组后进入工具箱',
            style: TextStyle(fontSize: 12, color: scheme.onPrimaryContainer.withValues(alpha: 0.8)),
          ),
        ],
      ),
    );
  }

  Widget _runningCard(BuildContext context, TaskCenter task) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: scheme.primary),
                ),
                const SizedBox(width: 10),
                Expanded(child: Text('正在执行：${task.stage}', style: const TextStyle(fontSize: 13))),
                TextButton(
                  onPressed: task.requestCancel,
                  child: const Text('停止'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: task.progress, minHeight: 6, borderRadius: BorderRadius.circular(3)),
            if (task.progressLabel.isNotEmpty) ...<Widget>[
              const SizedBox(height: 6),
              Text(task.progressLabel, style: Theme.of(context).textTheme.labelSmall),
            ],
          ],
        ),
      ),
    );
  }

  Widget _actions(BuildContext context) {
    final items = <(String, IconData, int)>[
      ('本地化', Icons.translate, 1),
      ('图片', Icons.image_outlined, 2),
      ('工具', Icons.build_outlined, 3),
      ('导出', Icons.archive_outlined, 4),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth > 560;
        final width = wide ? (constraints.maxWidth - 36) / 4 : (constraints.maxWidth - 12) / 2;
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: items.map((item) {
            return SizedBox(
              width: width,
              child: Card(
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => widget.onNavigate(item.$3),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Column(
                      children: <Widget>[
                        Icon(item.$2, size: 22),
                        const SizedBox(height: 8),
                        Text(item.$1, style: const TextStyle(fontSize: 12.5)),
                      ],
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        );
      },
    );
  }

  Widget _pathRow(String label, String? path) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: <Widget>[
        SizedBox(
          width: 56,
          child: Text(label, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
        ),
        Expanded(
          child: Text(
            path ?? '未设置',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
          ),
        ),
      ],
    );
  }
}
