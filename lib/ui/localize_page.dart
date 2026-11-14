import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../core/config.dart';
import '../core/env.dart';
import '../core/lang_files.dart';
import '../core/languages.dart';
import '../core/log_control.dart';
import '../core/pack_ops.dart';
import '../core/pipeline.dart';
import '../core/task_center.dart';
import 'widgets.dart';

/// ① Display Name → ② languages → ③ scripts → ④ credit.
///
/// Work runs in [TaskCenter]; this page only renders shared state, so switching
/// tabs never cancels a run.
class LocalizePage extends StatefulWidget {
  const LocalizePage({super.key, required this.config, this.onPathsChanged});

  final HubConfig config;
  final VoidCallback? onPathsChanged;

  @override
  State<LocalizePage> createState() => _LocalizePageState();
}

class _LocalizePageState extends State<LocalizePage> {
  String _formatLabel = '格式化: 等待中…';
  bool _formatReady = false;

  TaskCenter get _task => TaskCenter.instance;
  LogControl get _log => _task.log;

  String get _code => widget.config.str('target_language');
  String get _lang => labelOf(_code);

  LocalizationPipeline get _pipeline => LocalizationPipeline(
        widget.config,
        _log.add,
        onPathsChanged: (_, __) => widget.onPathsChanged?.call(),
      );

  String? get _rp => Env.resolvePackDir(widget.config.str('resource_pack_path'));
  String? get _bp => Env.resolvePackDir(widget.config.str('behavior_pack_path'));

  String get _credit {
    final c = widget.config.str('translator_credit').trim();
    return c.isEmpty ? 'Local' : c;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _autoFormat());
  }

  Future<void> _autoFormat() async {
    final pipeline = _pipeline;
    final packs = pipeline.packs;
    if (packs.isEmpty) {
      setState(() {
        _formatLabel = '格式化: 无可用包';
        _formatReady = true;
      });
      return;
    }
    _log.add('=' * 50);
    _log.add('自动规范化 JSON / JS / lang …');
    var ok = 0, fail = 0, skip = 0, langs = 0;
    for (final pack in packs) {
      final (jsonFiles, jsFiles) = FormatService.collectTargets(pack.$2);
      final (jOk, jFail, jSkip) = FormatService.formatJsonFiles(jsonFiles, log: _log.add);
      final (sOk, sFail, sSkip) = FormatService.formatJsFiles(jsFiles, log: _log.add);
      ok += jOk + sOk;
      fail += jFail + sFail;
      skip += jSkip + sSkip;
      final texts = Directory(p.join(pack.$2, 'texts'));
      if (texts.existsSync()) {
        for (final file in texts.listSync().whereType<File>()) {
          if (!file.path.toLowerCase().endsWith('.lang')) continue;
          if (LangFiles.normalizeLayout(file.path)) langs++;
        }
      }
    }
    if (!mounted) return;
    setState(() {
      _formatReady = true;
      _formatLabel = '格式化完成：成功 $ok，失败 $fail，跳过 $skip，lang 整理 $langs';
    });
    _log.add(_formatLabel);
  }

  Future<void> _waitFormat() async {
    if (_formatReady) return;
    _log.add('等待 JSON/JS 规范化完成…');
    while (!_formatReady) {
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
  }

  Future<void> _run(String label, Future<void> Function(LocalizationPipeline p) task) async {
    if (_pipeline.packs.isEmpty) {
      showError(context, '当前模组没有可用包');
      return;
    }
    final started = await _task.start(label, () async {
      await _waitFormat();
      _log.add('=' * 50);
      _log.add('$label …');
      await task(_pipeline);
    });
    if (!started && mounted) showError(context, '已有任务在运行');
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _task,
      builder: (context, _) {
        final theme = Theme.of(context);
        final busy = _task.running;
        final suffix = creditSuffix(_code, _credit);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Text(
                      '任务在后台运行，切换页面不会中断。当前目标语言：$_lang（$_code）。',
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 8),
                    Text(_formatLabel, style: theme.textTheme.bodySmall),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: <Widget>[
                        OutlinedButton.icon(
                          onPressed: _openModFolder,
                          icon: const Icon(Icons.folder_open),
                          label: const Text('打开文件夹'),
                        ),
                        if (busy)
                          OutlinedButton.icon(
                            onPressed: _task.requestCancel,
                            icon: const Icon(Icons.stop_circle_outlined),
                            label: const Text('停止'),
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    SectionCard(
                      title: '本地化步骤（→ $_lang）',
                      children: <Widget>[
                        _stepButton('① Display Name 标准化', Icons.label,
                            () => _run('Display Name 标准化', (p) => p.displayNames())),
                        _stepButton('② 语言文件翻译', Icons.translate,
                            () => _run('语言文件翻译', (p) => p.translateLanguages()), primary: true),
                        _stepButton('③ 脚本提示本地化', Icons.code,
                            () => _run('脚本提示本地化', (p) => p.scripts())),
                        _stepButton('④ 本地化者署名（$suffix）', Icons.badge,
                            () => _run('应用署名', (p) => p.applyCredit()), tonal: true),
                        _stepButton('⚡ 一键本地化', Icons.bolt,
                            () => _run('一键本地化', (p) => p.oneClick()), primary: true, last: true),
                      ],
                    ),
                    const SizedBox(height: 12),
                    ProgressRow(value: _task.progress, label: _task.progressLabel),
                    if (busy) ...<Widget>[
                      const SizedBox(height: 4),
                      Text('正在执行：${_task.stage}',
                          style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.primary)),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            LogPanel(control: _log, height: 190),
          ],
        );
      },
    );
  }

  Widget _stepButton(String label, IconData icon, VoidCallback onPressed,
      {bool primary = false, bool tonal = false, bool last = false}) {
    final busy = _task.running;
    final child = Row(
      children: <Widget>[
        Icon(icon, size: 18),
        const SizedBox(width: 10),
        Expanded(
          child: Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500)),
        ),
        const Icon(Icons.chevron_right, size: 16),
      ],
    );
    final style = ButtonStyle(
      minimumSize: const WidgetStatePropertyAll<Size>(Size.fromHeight(48)),
      maximumSize: const WidgetStatePropertyAll<Size>(Size(double.infinity, 48)),
      alignment: Alignment.centerLeft,
      padding: const WidgetStatePropertyAll<EdgeInsets>(EdgeInsets.symmetric(horizontal: 14)),
      shape: WidgetStatePropertyAll<RoundedRectangleBorder>(
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
    final button = primary
        ? FilledButton(style: style, onPressed: busy ? null : onPressed, child: child)
        : tonal
            ? FilledButton.tonal(style: style, onPressed: busy ? null : onPressed, child: child)
            : OutlinedButton(style: style, onPressed: busy ? null : onPressed, child: child);
    return Padding(
      padding: EdgeInsets.only(bottom: last ? 0 : 8),
      child: SizedBox(width: double.infinity, child: button),
    );
  }

  Future<void> _openModFolder() async {
    final rp = _rp;
    final bp = _bp;
    String? target;
    if (rp != null && bp != null) {
      target = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('打开模组文件夹'),
          content: Text('「${widget.config.str('current_mod_name')}」同时包含资源包与行为包，请选择要打开的目录：'),
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
}
