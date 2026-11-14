import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/archive_probe.dart';
import '../core/config.dart';
import '../core/env.dart';
import '../core/export_service.dart';
import '../core/fsx.dart';
import '../core/mod_catalog.dart';
import '../core/models.dart';
import '../core/pack_rename.dart';
import '../core/pipeline.dart';
import '../core/task_center.dart';
import '../core/projects.dart';
import 'widgets.dart';

class WelcomePage extends StatefulWidget {
  const WelcomePage({
    super.key,
    required this.config,
    required this.onEnter,
    required this.onModsChanged,
  });

  final HubConfig config;
  final void Function(ModEntry mod) onEnter;
  final VoidCallback onModsChanged;

  @override
  State<WelcomePage> createState() => _WelcomePageState();
}

class _WelcomePageState extends State<WelcomePage> {
  final LogControl _log = LogControl();
  List<ModEntry> _mods = <ModEntry>[];
  bool _loading = false;
  String? _error;
  String _query = '';
  String _filter = 'all';
  bool _selectMode = false;
  final Set<String> _selected = <String>{};

  String _keyOf(ModEntry mod) => '${mod.name}|${mod.resourcePack ?? ''}|${mod.behaviorPack ?? ''}|${mod.archive ?? ''}';

  Widget _batchBar(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final count = _selected.length;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: <Widget>[
          Text('已选 $count', style: TextStyle(color: scheme.onSecondaryContainer, fontSize: 13)),
          const Spacer(),
          TextButton(
            onPressed: () => setState(() {
              final visible = _visible;
              if (_selected.length == visible.length) {
                _selected.clear();
              } else {
                _selected
                  ..clear()
                  ..addAll(visible.map(_keyOf));
              }
            }),
            child: Text(_selected.length == _visible.length ? '全不选' : '全选'),
          ),
          const SizedBox(width: 4),
          FilledButton.icon(
            onPressed: count == 0 || TaskCenter.instance.running ? null : _runBatch,
            icon: const Icon(Icons.play_arrow, size: 18),
            label: Text('开始（$count）'),
          ),
        ],
      ),
    );
  }

  Future<void> _runBatch() async {
    final mods = _mods.where((m) => _selected.contains(_keyOf(m))).toList();
    if (mods.isEmpty) return;
    final task = TaskCenter.instance;
    await task.start('批量本地化', () async {
      task.addLog('批量任务：${mods.length} 个模组');
      for (var i = 0; i < mods.length; i++) {
        if (task.cancelRequested) {
          task.addLog('已停止批量任务');
          break;
        }
        final mod = mods[i];
        task.setStage('批量 ${i + 1}/${mods.length}：${mod.name}');
        task.setProgress(i, mods.length);
        task.addLog('—— [${i + 1}/${mods.length}] ${mod.name} ——');
        final ok = await _prepareMod(mod);
        if (!ok) {
          task.addLog('  ✗ 无法准备该模组，跳过');
          continue;
        }
        await widget.config.save();
        final pipeline = LocalizationPipeline(widget.config, task.addLog);
        await pipeline.oneClick();
      }
      task.setProgress(mods.length, mods.length);
    });
    if (!mounted) return;
    widget.onModsChanged();
    await _reload();
  }

  /// Points the config at [mod], unpacking archives into the work directory.
  Future<bool> _prepareMod(ModEntry mod) async {
    if (mod.isArchive) {
      final support = await getApplicationSupportDirectory();
      final slug = Fsx.sanitizeName(mod.name, maxLen: 60, fallback: 'mod');
      final dest = p.join(support.path, 'work', '$slug-${mod.archive!.hashCode.toRadixString(16)}');
      final dir = Directory(dest);
      if (dir.existsSync()) dir.deleteSync(recursive: true);
      ArchiveProbe.extract(mod.archive!, dest);
      final packs = ModCatalog.scanPacks(dest);
      if (packs.isEmpty) return false;
      String? rp;
      String? bp;
      for (final pack in packs) {
        if (pack.kind == 'RP' && rp == null) rp = pack.path;
        if (pack.kind == 'BP' && bp == null) bp = pack.path;
      }
      widget.config.set(rp ?? '', 'resource_pack_path');
      widget.config.set(bp ?? '', 'behavior_pack_path');
    } else {
      widget.config.set(mod.resourcePack ?? '', 'resource_pack_path');
      widget.config.set(mod.behaviorPack ?? '', 'behavior_pack_path');
    }
    widget.config.set(mod.name, 'current_mod_name');
    final store = await RecentProjects.load();
    await store.remember(RecentProject(
      name: mod.name,
      resourcePack: mod.resourcePack,
      behaviorPack: mod.behaviorPack,
      openedAt: DateTime.now(),
    ));
    return true;
  }

  List<ModEntry> get _visible {
    Iterable<ModEntry> list = _mods;
    switch (_filter) {
      case 'rp':
        list = list.where((m) => m.hasRp);
      case 'bp':
        list = list.where((m) => m.hasBp);
      case 'archive':
        list = list.where((m) => m.isArchive);
    }
    final q = _query.trim().toLowerCase();
    if (q.isNotEmpty) {
      list = list.where((m) => m.name.toLowerCase().contains(q));
    }
    return list.toList();
  }

  String get _base => Env.resolveModsBase(widget.config.str('mods_base_dir'));
  String get _targetCode => widget.config.str('target_language');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
  }

  Future<void> _diagnose() async {
    final report = ModCatalog.diagnose(_base);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('扫描诊断'),
        content: SizedBox(
          width: 620,
          height: 420,
          child: SingleChildScrollView(
            child: SelectableText(
              report,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: report));
            },
            child: const Text('复制报告'),
          ),
          FilledButton(onPressed: () => Navigator.pop(context), child: const Text('关闭')),
        ],
      ),
    );
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final found = await Future<List<ModEntry>>.microtask(
        () => ModCatalog.listMods(_base, targetCode: _targetCode),
      );
      if (!mounted) return;
      setState(() {
        _mods = found;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '扫描失败: $e';
        _loading = false;
      });
    }
  }

  Future<void> _organize() async {
    if (!Directory(_base).existsSync()) {
      showError(context, '未找到模组目\n$_base');
      return;
    }
    final plans = PackRename.planRenames(_base, _targetCode);
    final changes = plans.where((e) => e.changed).toList();
    final skipped = plans.where((e) => e.skipped).length;
    if (changes.isEmpty) {
      showToast(context, '没有需要重命名的模组文件夹（跳$skipped 个）');
      return;
    }
    final preview = changes
        .map((e) => '[${e.suffix}] ${p.basename(e.src)}\n  ${p.basename(e.dest)}')
        .join('\n');
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('预览：自动整理模组名称（${changes.length} 个）'),
        content: SizedBox(
          width: 560,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('优先使用目标语言包名；行为包BP，资源包RP。跳$skipped 个'),
              const SizedBox(height: 8),
              Container(
                height: 260,
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(preview, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
                ),
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('确认重命')),
        ],
      ),
    );
    if (ok != true) return;
    final (count, errors) = PackRename.applyRenames(changes, log: _log.add);
    if (errors.isEmpty) {
      showToast(context, '已重命名 $count 个文件夹');
    } else {
      showError(context, '重命名 $count 个，失败 ${errors.length} 个:\n${errors.take(6).join('\n')}');
    }
    widget.onModsChanged();
    await _reload();
  }

  Future<void> _delete(ModEntry mod) async {
    final paths = mod.packPaths();
    if (mod.isArchive) {
      final ok = await confirmDialog(
        context,
        title: '删除压缩包：${mod.name}',
        message: '将从磁盘永久删除：\n${mod.archive}',
        yesText: '永久删除',
      );
      if (!ok) return;
      try {
        File(mod.archive!).deleteSync();
        showToast(context, '已删除 ${p.basename(mod.archive!)}');
      } catch (e) {
        if (mounted) showError(context, '删除失败: $e');
      }
      await _reload();
      return;
    }
    if (paths.isEmpty) {
      showError(context, '该模组没有可删除的包目录');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除模组{mod.name}'),
        content: SizedBox(
          width: 540,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('将从磁盘永久删除以下文件夹（不可恢复，删除前请确认游戏已关闭）：',
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SelectableText(
                  paths.map((e) => '$e').join('\n'),
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('永久删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final (count, errors) = PackManage.deleteDirs(paths);
    if (count > 0) {
      widget.config.set('', 'resource_pack_path');
      widget.config.set('', 'behavior_pack_path');
      widget.config.set('', 'current_mod_name');
      await widget.config.save();
      widget.onModsChanged();
    }
    if (!mounted) return;
    if (errors.isNotEmpty) {
      showError(context, '已删$count 个，失败 ${errors.length} 个（可能被游戏占用）');
    } else {
      showToast(context, '已删除模组「${mod.name}」的 $count 个文件夹');
    }
    await _reload();
  }

  Future<void> _openFolder(ModEntry mod) async {
    if (mod.isArchive) {
      try {
        await Env.openFolder(p.dirname(mod.archive!));
      } catch (e) {
        if (mounted) showError(context, '打开文件夹失败: $e');
      }
      return;
    }
    final rp = mod.resourcePack;
    final bp = mod.behaviorPack;
    String? target;
    if (rp != null && bp != null) {
      target = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('打开模组文件夹：${mod.name}'),
          content: const Text('该模组同时包含资源包与行为包，请选择要打开的目录：'),
          actions: <Widget>[
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
            FilledButton.tonal(onPressed: () => Navigator.pop(context, rp), child: const Text('资源包（RP）')),
            FilledButton.tonal(onPressed: () => Navigator.pop(context, bp), child: const Text('行为包（BP）')),
          ],
        ),
      );
    } else {
      target = rp ?? bp;
    }
    if (target == null) return;
    try {
      await Env.openFolder(target);
    } catch (e) {
      if (mounted) showError(context, '打开文件夹失败: $e');
    }
  }

  Future<void> _enter(ModEntry mod) async {
    if (mod.isArchive) {
      await _enterArchive(mod);
      return;
    }
    widget.config.set(mod.resourcePack ?? '', 'resource_pack_path');
    widget.config.set(mod.behaviorPack ?? '', 'behavior_pack_path');
    widget.config.set(mod.name, 'current_mod_name');
    await widget.config.save();
    await RecentProjects.load().then((store) => store.remember(RecentProject(
          name: mod.name,
          resourcePack: mod.resourcePack,
          behaviorPack: mod.behaviorPack,
          openedAt: DateTime.now(),
        )));
    widget.onModsChanged();
    widget.onEnter(mod);
  }

  /// Unpacks an archive into the app support directory, then enters the mod.
  Future<void> _enterArchive(ModEntry mod) async {
    final support = await getApplicationSupportDirectory();
    final slug = Fsx.sanitizeName(mod.name, maxLen: 60, fallback: 'mod');
    final hash = mod.archive!.hashCode.toRadixString(16);
    final dest = p.join(support.path, 'work', '$slug-$hash');

    if (!mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => const AlertDialog(
        content: Row(
          children: <Widget>[
            SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
            SizedBox(width: 16),
            Text('正在解压…'),
          ],
        ),
      ),
    );

    try {
      final dir = Directory(dest);
      if (dir.existsSync()) dir.deleteSync(recursive: true);
      ArchiveProbe.extract(mod.archive!, dest);
      final packs = ModCatalog.scanPacks(dest);
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();

      if (packs.isEmpty) {
        showError(context, '压缩包里没有找到可用的 manifest.json');
        return;
      }
      String? rp;
      String? bp;
      for (final pack in packs) {
        if (pack.kind == 'RP' && rp == null) rp = pack.path;
        if (pack.kind == 'BP' && bp == null) bp = pack.path;
      }
      widget.config.set(rp ?? '', 'resource_pack_path');
      widget.config.set(bp ?? '', 'behavior_pack_path');
      widget.config.set(mod.name, 'current_mod_name');
      await widget.config.save();
      widget.onModsChanged();
      if (!mounted) return;
      showToast(context, '已解压到 ${p.basename(dest)}（${packs.length} 个包）');
      widget.onEnter(mod);
    } catch (e) {
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        showError(context, '解压失败: $e');
      }
    }
  }

  String _iconFor(ModEntry mod) {
    for (final pack in mod.packPaths()) {
      final icon = File(p.join(pack, 'pack_icon.png'));
      if (icon.existsSync()) return icon.path;
    }
    return '';
  }

  /// Archive mods carry their icon bytes; folder mods read `pack_icon.png`.
  Widget _iconWidget(ModEntry mod, ColorScheme scheme) {
    final bytes = mod.iconBytes;
    if (bytes != null && bytes.isNotEmpty) {
      return Image.memory(
        bytes,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) => _fallbackIcon(scheme),
      );
    }
    final path = _iconFor(mod);
    if (path.isEmpty) return _fallbackIcon(scheme);
    return Image.file(File(path), fit: BoxFit.cover, errorBuilder: (_, __, ___) => _fallbackIcon(scheme));
  }

  Widget _fallbackIcon(ColorScheme scheme) => Container(
        color: scheme.primaryContainer,
        child: Icon(Icons.extension, color: scheme.onPrimaryContainer),
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('模组库', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                  Text(
                    '${_mods.length} 个模组 · 点击卡片进入工具箱',
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            if (_loading)
              const Padding(
                padding: EdgeInsets.only(right: 8),
                child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
              ),
            IconButton(tooltip: '刷新', onPressed: _loading ? null : _reload, icon: const Icon(Icons.refresh)),
            IconButton(
                tooltip: '自动整理名称',
                onPressed: _organize,
                icon: const Icon(Icons.drive_file_rename_outline)),
            IconButton(tooltip: '扫描诊断', onPressed: _diagnose, icon: const Icon(Icons.troubleshoot)),
            IconButton(
              tooltip: _selectMode ? '退出批量' : '批量处理',
              onPressed: () => setState(() {
                _selectMode = !_selectMode;
                if (!_selectMode) _selected.clear();
              }),
              icon: Icon(_selectMode ? Icons.close : Icons.checklist),
            ),
          ],
        ),
        if (_selectMode) ...<Widget>[
          const SizedBox(height: 8),
          _batchBar(context),
        ],
        const SizedBox(height: 10),
        TextField(
          decoration: InputDecoration(
            hintText: '搜索模组名',
            prefixIcon: const Icon(Icons.search, size: 20),
            isDense: true,
            suffixIcon: _query.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.clear, size: 18),
                    onPressed: () => setState(() => _query = ''),
                  ),
          ),
          onChanged: (value) => setState(() => _query = value),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          children: <Widget>[
            ChoiceChip(
              label: const Text('全部'),
              selected: _filter == 'all',
              onSelected: (_) => setState(() => _filter = 'all'),
            ),
            ChoiceChip(
              label: const Text('含资源包'),
              selected: _filter == 'rp',
              onSelected: (_) => setState(() => _filter = 'rp'),
            ),
            ChoiceChip(
              label: const Text('含行为包'),
              selected: _filter == 'bp',
              onSelected: (_) => setState(() => _filter = 'bp'),
            ),
            ChoiceChip(
              label: const Text('压缩包'),
              selected: _filter == 'archive',
              onSelected: (_) => setState(() => _filter = 'archive'),
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
          ),
        Expanded(
          child: _mods.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        _loading ? '正在扫描…' : '未扫描到模组包',
                        style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                      ),
                      const SizedBox(height: 8),
                      SelectableText(
                        '扫描目录：$_base\n'
                        '递归查找任意层级的 manifest.json 与 .mcaddon / .mcpack / .zip。',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: _diagnose,
                        icon: const Icon(Icons.troubleshoot, size: 18),
                        label: const Text('看看为什么扫不到'),
                      ),
                    ],
                  ),
                )
              : _visible.isEmpty
                  ? Center(
                      child: Text('没有符合筛选条件的模组',
                          style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
                    )
                  : ListView.separated(
                      itemCount: _visible.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (context, index) => TweenAnimationBuilder<double>(
                        tween: Tween<double>(begin: 0, end: 1),
                        duration: Duration(milliseconds: 220 + (index.clamp(0, 8) * 45)),
                        curve: Curves.easeOutCubic,
                        builder: (context, value, child) => Opacity(
                          opacity: value,
                          child: Transform.translate(
                            offset: Offset(0, 12 * (1 - value)),
                            child: child,
                          ),
                        ),
                        child: _card(_visible[index]),
                      ),
                    ),
        ),
        const SizedBox(height: 8),
        Text(
          '右上角「设置」可配置 AI 接口；进入工具箱后可返回重新选模组',
          style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }

  Widget _card(ModEntry mod) {
    final scheme = Theme.of(context).colorScheme;
    final detail = mod.isArchive
        ? '压缩包: ${p.basename(mod.archive!)}'
        : <String>[
            if (mod.hasRp) 'RP: ${p.basename(mod.resourcePack!)}',
            if (mod.hasBp) 'BP: ${p.basename(mod.behaviorPack!)}',
          ].join('  |  ');
    final description = mod.description.trim();
    return Card(
      child: InkWell(
        onTap: () {
          if (_selectMode) {
            setState(() {
              final key = _keyOf(mod);
              if (!_selected.remove(key)) _selected.add(key);
            });
          } else {
            _enter(mod);
          }
        },
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
          child: Row(
            children: <Widget>[
              if (_selectMode)
                Checkbox(
                  value: _selected.contains(_keyOf(mod)),
                  onChanged: (_) => setState(() {
                    final key = _keyOf(mod);
                    if (!_selected.remove(key)) _selected.add(key);
                  }),
                ),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 48,
                  height: 48,
                  child: _iconWidget(mod, scheme),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        if (mod.isArchive) _badge('压缩包', scheme.tertiary),
                        if (mod.isArchive && (mod.hasRp || mod.hasBp)) const SizedBox(width: 6),
                        if (mod.hasRp) _badge('RP', scheme.primary),
                        if (mod.hasRp && mod.hasBp) const SizedBox(width: 6),
                        if (mod.hasBp) _badge('BP', scheme.secondary),
                        if (mod.hasRp || mod.hasBp) const SizedBox(width: 8),
                        Expanded(
                          child: Text(mod.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(detail,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                    if (description.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 2),
                      Text(
                        description,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant.withValues(alpha: 0.85)),
                      ),
                    ],
                  ],
                ),
              ),
              IconButton(
                tooltip: '打开模组所在文件夹',
                onPressed: () => _openFolder(mod),
                icon: const Icon(Icons.folder_open, size: 20),
              ),
              IconButton(
                tooltip: '删除此模组',
                onPressed: () => _delete(mod),
                icon: Icon(Icons.delete_outline, size: 20, color: scheme.error),
              ),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }

  Widget _badge(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(6)),
        child: Text(text,
            style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
      );
}

