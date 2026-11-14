import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../core/cloud.dart';
import '../core/config.dart';
import '../core/env.dart';
import '../core/export_service.dart';
import '../core/languages.dart';
import 'widgets.dart';

class ExportPage extends StatefulWidget {
  const ExportPage({super.key, required this.config});

  final HubConfig config;

  @override
  State<ExportPage> createState() => _ExportPageState();
}

class _ExportPageState extends State<ExportPage> {
  final LogControl _log = LogControl();
  late final TextEditingController _out;
  late final List<CloudDrive> _drives;
  final Map<String, bool> _enabled = <String, bool>{};
  String _preview = '';
  bool _busy = false;

  String get _code => widget.config.str('target_language');
  String get _credit {
    final c = widget.config.str('translator_credit').trim();
    return c.isEmpty ? 'Local' : c;
  }

  String? get _rp => Env.resolvePackDir(widget.config.str('resource_pack_path'));
  String? get _bp => Env.resolvePackDir(widget.config.str('behavior_pack_path'));

  String get _modName {
    final name = widget.config.str('current_mod_name').trim();
    if (name.isNotEmpty) return name;
    final bp = _bp;
    if (bp != null) return p.basename(bp);
    final rp = _rp;
    if (rp != null) return p.basename(rp);
    return 'unnamed_mod';
  }

  @override
  void initState() {
    super.initState();
    final out = widget.config.str('export_dir').trim();
    _out = TextEditingController(text: out.isEmpty ? Env.defaultExportDir() : out);
    _drives = CloudDrives.from(widget.config.raw);
    for (final drive in _drives) {
      _enabled[drive.id] = drive.enabled;
    }
    _refreshPreview();
  }

  @override
  void dispose() {
    _out.dispose();
    super.dispose();
  }

  void _refreshPreview() {
    final rp = _rp;
    final bp = _bp;
    final mod = FsxSafe.sanitize(ExportService.baseModName(_modName));
    final both = rp != null && bp != null;
    final (version, source) = ExportService.versionToAppend(mod, bp, rp);
    final fileName = ExportService.buildFileName(mod, _credit, both, _code, version);
    final lines = <String>[
      '模组: $mod',
      if (source == 'name')
        '版本: ${ExportService.versionInName(mod) ?? version}（模组名）'
      else if (version != null)
        '版本: $version（${source == 'bp' ? '行为包' : '资源包'}）'
      else
        '版本: （未找到）',
      '署名: ${creditSuffix(_code, _credit)}',
      '资源包: ${rp == null ? '（无）' : p.basename(rp)}',
      '行为包: ${bp == null ? '（无）' : p.basename(bp)}',
      '输出文件: $fileName',
      if (both) ...<String>[
        '结构: $fileName',
        '         ├─ ${mod}BP/',
        '         └─ ${mod}RP/',
      ] else
        '结构: 包内容直接位于压缩包根目录（含 manifest.json）',
    ];
    setState(() => _preview = lines.join('\n'));
  }

  Future<void> _pickDir() async {
    final dir = await pickDirectory();
    if (dir != null) {
      _out.text = dir;
      widget.config.set(dir, 'export_dir');
      await widget.config.save();
      _refreshPreview();
    }
  }

  Future<void> _export() async {
    if (_busy) return;
    if (_rp == null && _bp == null) {
      showError(context, '当前模组没有可用包');
      return;
    }
    final out = Directory(_out.text.trim());
    if (!out.existsSync()) {
      try {
        out.createSync(recursive: true);
      } catch (e) {
        showError(context, '无法创建导出目录: $e');
        return;
      }
    }
    widget.config.set(out.path, 'export_dir');
    for (final drive in _drives) {
      drive.enabled = _enabled[drive.id] ?? false;
    }
    await widget.config.save();
    if (!mounted) return;
    setState(() => _busy = true);
    _log.add('=' * 50);
    _log.add('开始导出本地化包 …');
    try {
      final dest = await Future<String>.microtask(() => ExportService.export(
            outDir: out.path,
            modName: _modName,
            credit: _credit,
            rp: _rp,
            bp: _bp,
            code: _code,
            log: _log.add,
          ));
      _log.add('完成: $dest');
      for (final drive in _drives.where((d) => d.enabled)) {
        if (!drive.isAuthorized()) {
          _log.add('${drive.displayName}未登录，已跳过。');
          continue;
        }
        _log.add('开始发布到${drive.displayName} …');
        final result = await drive.publish(dest, log: _log.add);
        _log.add(result.summary());
        if (result.share != null && result.share!.url.isNotEmpty) {
          _log.add('  分享链接: ${result.share!.url}');
        }
      }
      if (!mounted) return;
      showToast(context, '已导出: ${p.basename(dest)}');
    } catch (e) {
      _log.add('导出失败: $e');
      if (mounted) showError(context, '导出失败: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  '将当前模组导出为可双击导入的压缩包：\n'
                  '· 同时有资源包与行为包 → .mcaddon\n'
                  '· 仅有一侧 → .mcpack\n'
                  '二者本质都是 ZIP，仅后缀不同。文件名带版本号；勾选下方网盘开关可在导出后自动上传。',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 12),
                SectionCard(
                  title: '导出预览',
                  trailing: OutlinedButton.icon(
                    onPressed: _refreshPreview,
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text('刷新预览'),
                  ),
                  children: <Widget>[
                    SelectableText(_preview, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: TextField(
                        controller: _out,
                        decoration: const InputDecoration(labelText: '导出目录'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed: _pickDir,
                      icon: const Icon(Icons.folder_open),
                      label: const Text('浏览…'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                for (final drive in _drives)
                  SwitchListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text('上传到${drive.displayName}${drive.supportsShare ? '并分享' : ''}'),
                    value: _enabled[drive.id] ?? false,
                    onChanged: (value) => setState(() => _enabled[drive.id] = value),
                  ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.icon(
                    onPressed: _busy ? null : _export,
                    icon: const Icon(Icons.archive),
                    label: const Text('导出本地化包'),
                  ),
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

/// Thin wrapper so the preview stays independent of Fsx internals.
class FsxSafe {
  static String sanitize(String name) {
    var s = name.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '');
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return s.isEmpty ? 'unnamed_mod' : s;
  }
}

Future<String?> pickDirectory() async {
  final dir = await FilePicker.platform.getDirectoryPath(dialogTitle: '选择导出目录');
  return dir;
}
