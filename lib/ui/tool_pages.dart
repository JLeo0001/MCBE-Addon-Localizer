import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../core/config.dart';
import '../core/entity.dart';
import '../core/env.dart';
import '../core/fsx.dart';
import '../core/manifest.dart';
import 'widgets.dart';

/// ③ 灵动视效：toggles the `pbr` capability on the resource pack.
class PbrPage extends StatefulWidget {
  const PbrPage({super.key, required this.config});
  final HubConfig config;

  @override
  State<PbrPage> createState() => _PbrPageState();
}

class _PbrPageState extends State<PbrPage> {
  final LogControl _log = LogControl();
  String _status = '';

  String? get _rp => Env.resolvePackDir(widget.config.str('resource_pack_path'));

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  bool? get _enabled {
    final rp = _rp;
    if (rp == null) return null;
    final data = ManifestService.read(rp);
    if (data == null) return null;
    final caps = data['capabilities'];
    return caps is List ? caps.contains('pbr') : false;
  }

  void _refresh() {
    final rp = _rp;
    final lines = <String>[];
    if (rp == null) {
      lines.add('✗ 当前模组没有资源包，无法添加灵动视效');
    } else {
      lines.add('资源包: $rp');
      final data = ManifestService.read(rp);
      if (data == null) {
        lines.add('✗ 无法解析 manifest.json');
      } else {
        final header = data['header'];
        if (header is Map) {
          lines.add('  名称: ${header['name'] ?? '?'}  版本: ${header['version'] ?? '?'}');
        }
        lines.add('  capabilities: ${data['capabilities']}');
        lines.add('  PBR 状态: ${_enabled == true ? '✓ 已启用' : '✗ 未启用'}');
      }
    }
    setState(() => _status = lines.join('\n'));
  }

  @override
  Widget build(BuildContext context) {
    final rp = _rp;
    final enabled = _enabled;
    return _toolScaffold(
      context,
      intro: '使用首屏选中模组的资源包。若该模组没有资源包，本功能不可用。',
      status: _status,
      log: _log,
      actions: <Widget>[
        if (enabled == false)
          FilledButton.icon(
            onPressed: rp == null ? null : () {
              ManifestService.applyPbrCapability(rp, _log.add);
              _refresh();
            },
            icon: const Icon(Icons.visibility),
            label: const Text('添加灵动视效支持'),
          ),
        if (enabled == true)
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: rp == null
                ? null
                : () async {
                    final ok = await confirmDialog(context, title: '确认', message: '确定移除 pbr capability 吗？');
                    if (!ok) return;
                    final data = ManifestService.read(rp);
                    if (data == null) return;
                    final caps = data['capabilities'];
                    if (caps is List && caps.remove('pbr')) {
                      Fsx.writeJson(p.join(rp, 'manifest.json'), data);
                      _log.add('已移除 pbr capability');
                    } else {
                      _log.add('manifest.json 中没有 pbr 条目');
                    }
                    _refresh();
                  },
            icon: const Icon(Icons.visibility_off),
            label: const Text('移除灵动视效支持'),
          ),
        OutlinedButton.icon(
          onPressed: _refresh,
          icon: const Icon(Icons.refresh),
          label: const Text('刷新'),
        ),
      ],
    );
  }
}

/// ④ 成就兼容：writes `metadata.product_type = "addon"`.
class AchievementPage extends StatefulWidget {
  const AchievementPage({super.key, required this.config});
  final HubConfig config;

  @override
  State<AchievementPage> createState() => _AchievementPageState();
}

class _AchievementPageState extends State<AchievementPage> {
  final LogControl _log = LogControl();
  String _status = '';

  List<(String, String)> get _packs => <(String, String)>[
    if (Env.resolvePackDir(widget.config.str('resource_pack_path')) != null)
      ('资源包', Env.resolvePackDir(widget.config.str('resource_pack_path'))!),
    if (Env.resolvePackDir(widget.config.str('behavior_pack_path')) != null)
      ('行为包', Env.resolvePackDir(widget.config.str('behavior_pack_path'))!),
  ];

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _refresh() {
    final lines = <String>[];
    for (final pack in _packs) {
      final data = ManifestService.read(pack.$2);
      lines.add('—— ${pack.$1}: ${p.basename(pack.$2)} ——');
      lines.add('  路径: ${pack.$2}');
      if (data == null) {
        lines.add('  ✗ 无法解析 manifest.json');
        continue;
      }
      final header = data['header'];
      if (header is Map) {
        lines.add('  名称: ${header['name'] ?? '?'}  版本: ${header['version'] ?? '?'}');
      }
      lines.add('  metadata: ${data['metadata']}');
      lines.add(ManifestService.hasAddonProductType(data)
          ? '  成就兼容: ✓ 已启用（product_type = "addon"）'
          : '  成就兼容: ✗ 未启用');
    }
    if (_packs.isEmpty) lines.add('✗ 当前模组没有资源包或行为包，无法设置成就兼容');
    setState(() => _status = lines.join('\n'));
  }

  @override
  Widget build(BuildContext context) {
    final anyEnabled = _packs.any((pack) => ManifestService.hasAddonProductType(ManifestService.read(pack.$2)));
    return _toolScaffold(
      context,
      intro: '在 manifest.json 写入 metadata.product_type = "addon"，使模组以附加包方式加载并保持成就可用。',
      status: _status,
      log: _log,
      actions: <Widget>[
        if (!anyEnabled)
          FilledButton.icon(
            onPressed: () {
              _log.add('添加成就兼容（metadata.product_type = addon）…');
              var ok = 0;
              for (final pack in _packs) {
                if (ManifestService.applyAddonProductType(pack.$2, _log.add)) ok++;
              }
              _log.add('完成：$ok/${_packs.length} 个包已就绪');
              _refresh();
            },
            icon: const Icon(Icons.emoji_events),
            label: const Text('添加成就兼容'),
          ),
        if (anyEnabled)
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () async {
              final ok = await confirmDialog(context,
                  title: '确认', message: '确定从当前模组各包的 manifest 中移除 product_type = "addon" 吗？');
              if (!ok) return;
              for (final pack in _packs) {
                ManifestService.removeAddonProductType(pack.$2, _log.add);
              }
              _refresh();
            },
            icon: const Icon(Icons.event_busy),
            label: const Text('移除成就兼容'),
          ),
        OutlinedButton.icon(onPressed: _refresh, icon: const Icon(Icons.refresh), label: const Text('刷新')),
      ],
    );
  }
}

/// ⑤ 实体工具：monster health scan + family tagging.
class EntityPage extends StatefulWidget {
  const EntityPage({super.key, required this.config});
  final HubConfig config;

  @override
  State<EntityPage> createState() => _EntityPageState();
}

class _EntityPageState extends State<EntityPage> {
  final LogControl _log = LogControl();
  final TextEditingController _result = TextEditingController();
  bool _busy = false;

  String? get _bp => Env.resolvePackDir(widget.config.str('behavior_pack_path'));

  @override
  void dispose() {
    _result.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    final bp = _bp;
    if (bp == null) {
      showError(context, '当前模组没有行为包');
      return;
    }
    setState(() => _busy = true);
    _log.add('=' * 50);
    _log.add('扫描怪物名称 & 血量 …');
    try {
      final packs = EntityService.packDirs(bp);
      final rows = EntityService.scanMonsters(packs, _log.add);
      _result.text = rows.map((r) => '${r.$1}=${r.$2}').join('\n');
      _log.add('完成：${rows.length} 个怪物（结果已填入上方文本框，可直接复制）');
    } catch (e) {
      _log.add('✗ 扫描失败: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _tag() async {
    final bp = _bp;
    if (bp == null) {
      showError(context, '当前模组没有行为包');
      return;
    }
    setState(() => _busy = true);
    _log.add('=' * 50);
    _log.add('扫描需要添加 monster 标签的实体 …');
    try {
      final packs = EntityService.packDirs(bp);
      final count = EntityService.addMonsterTags(packs, _log.add);
      _log.add('完成：共为 $count 个实体添加 monster 标签');
    } catch (e) {
      _log.add('✗ 处理失败: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bp = _bp;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text('使用首屏选中模组的行为包。若该模组没有行为包，本功能不可用。',
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                const SizedBox(height: 6),
                Text(bp == null ? '✗ 当前模组没有行为包' : '行为包: $bp',
                    style: TextStyle(color: bp == null ? theme.colorScheme.error : null)),
                const SizedBox(height: 12),
                SectionCard(
                  title: '功能',
                  children: <Widget>[
                    Wrap(
                      spacing: 10,
                      runSpacing: 8,
                      children: <Widget>[
                        FilledButton.icon(
                          onPressed: _busy ? null : _scan,
                          icon: const Icon(Icons.monitor_heart),
                          label: const Text('扫描怪物名称 & 血量'),
                        ),
                        FilledButton.tonalIcon(
                          onPressed: _busy ? null : _tag,
                          icon: const Icon(Icons.pets),
                          label: const Text('为攻击玩家的实体添加 monster 标签'),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _result,
                  readOnly: true,
                  minLines: 8,
                  maxLines: 16,
                  style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                  decoration: const InputDecoration(labelText: '扫描结果（可全选复制）', alignLabelWithHint: true),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        LogPanel(control: _log, height: 150),
      ],
    );
  }
}

Widget _toolScaffold(
  BuildContext context, {
  required String intro,
  required String status,
  required LogControl log,
  required List<Widget> actions,
}) {
  final theme = Theme.of(context);
  return Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      Expanded(
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(intro,
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              const SizedBox(height: 12),
              SectionCard(
                title: '当前状态',
                children: <Widget>[
                  SelectableText(status, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(spacing: 10, runSpacing: 8, children: actions),
            ],
          ),
        ),
      ),
      const SizedBox(height: 12),
      LogPanel(control: log, height: 150),
    ],
  );
}
