import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../core/config.dart';
import '../core/env.dart';
import '../core/imaging.dart';
import '../core/languages.dart';
import '../core/llm.dart';
import 'widgets.dart';

const Set<String> imageExtensions = {'.png', '.jpg', '.jpeg', '.webp', '.bmp'};

class ImagePage extends StatefulWidget {
  const ImagePage({super.key, required this.config});

  final HubConfig config;

  @override
  State<ImagePage> createState() => _ImagePageState();
}

class _ImagePageState extends State<ImagePage> {
  final LogControl _log = LogControl();
  final Set<String> _selected = <String>{};
  List<String> _folders = <String>[];
  String? _current;
  List<File> _images = <File>[];
  double? _progress;
  String _progressLabel = '';
  bool _busy = false;

  String get _code => widget.config.str('target_language');
  String get _lang => labelOf(_code);
  String get _method => widget.config.str('image_localize_method') == 'ocr' ? 'ocr' : 'llm';

  List<(String, String)> get _packs => <(String, String)>[
    if (Env.resolvePackDir(widget.config.str('resource_pack_path')) != null)
      ('资源包', Env.resolvePackDir(widget.config.str('resource_pack_path'))!),
    if (Env.resolvePackDir(widget.config.str('behavior_pack_path')) != null)
      ('行为包', Env.resolvePackDir(widget.config.str('behavior_pack_path'))!),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  String _rel(String path) {
    for (final pack in _packs) {
      if (p.isWithin(pack.$2, path)) {
        return '${p.basename(pack.$2)} / ${p.relative(path, from: pack.$2)}';
      }
    }
    return path;
  }

  bool _likelyGuidebook(String folder) {
    final lower = folder.toLowerCase().replaceAll('\\', '/');
    if (lower.contains('book') || lower.contains('guide')) return true;
    try {
      return Directory(folder)
          .listSync()
          .whereType<File>()
          .any((f) => imageExtensions.contains(p.extension(f.path).toLowerCase()) &&
              p.basename(f.path).toLowerCase().contains('page'));
    } catch (_) {
      return false;
    }
  }

  void _refresh() {
    final found = <String, int>{};
    for (final pack in _packs) {
      try {
        for (final entity in Directory(pack.$2).listSync(recursive: true)) {
          if (entity is! File) continue;
          if (!imageExtensions.contains(p.extension(entity.path).toLowerCase())) continue;
          if (entity.path.replaceAll('\\', '/').contains('_backup')) continue;
          final dir = p.dirname(entity.path);
          found[dir] = (found[dir] ?? 0) + 1;
        }
      } catch (_) {}
    }
    final dirs = found.keys.toList()
      ..sort((a, b) {
        final ga = _likelyGuidebook(a) ? 0 : 1;
        final gb = _likelyGuidebook(b) ? 0 : 1;
        if (ga != gb) return ga.compareTo(gb);
        return a.toLowerCase().compareTo(b.toLowerCase());
      });
    setState(() {
      _folders = dirs.take(120).toList();
      if (_current != null && !_folders.contains(_current)) {
        _current = null;
        _images = <File>[];
        _selected.clear();
      }
    });
  }

  void _open(String folder) {
    final files = <File>[];
    try {
      for (final f in Directory(folder).listSync().whereType<File>()) {
        if (imageExtensions.contains(p.extension(f.path).toLowerCase())) files.add(f);
      }
    } catch (e) {
      _log.add('打开目录失败: $e');
    }
    files.sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));
    setState(() {
      _current = folder;
      _images = files;
      _selected
        ..clear()
        ..addAll(files.map((f) => f.path));
    });
    _log.add('预览目录：${_rel(folder)}（${files.length} 张）');
  }

  Future<void> _run() async {
    if (_busy) return;
    final images = _images.where((f) => _selected.contains(f.path)).map((f) => f.path).toList();
    if (images.isEmpty) {
      showError(context, '请先勾选要本地化的图片');
      return;
    }
    final textLlm = LlmConfig.from(widget.config.raw['text_llm'] as Map<String, dynamic>?);
    final imageLlm = LlmConfig.from(widget.config.raw['image_llm'] as Map<String, dynamic>?);
    if (_method == 'ocr' && !textLlm.configured) {
      showError(context, 'OCR 方案需先在设置中填写文本翻译 API Key');
      return;
    }
    if (_method == 'llm' && !imageLlm.configured) {
      showError(context, '请先在设置中填写图片翻译 API Key');
      return;
    }
    final ok = await confirmDialog(
      context,
      title: '确认图片本地化',
      message: _method == 'ocr'
          ? '将用 OCR 擦写方案本地化选中的 ${images.length} 张图片（文本 LLM 翻译）。原图备份到 _backup/。'
          : '将用视觉大模型本地化选中的 ${images.length} 张图片，并保持各自原分辨率。原图备份到 _backup/。',
    );
    if (!ok) return;

    setState(() {
      _busy = true;
      _progress = 0;
      _progressLabel = '0/${images.length}';
    });
    _log.add('=' * 50);
    _log.add('图片本地化（${_method == 'ocr' ? 'OCR 擦写' : '视觉大模型'} → $_lang）：${images.length} 张');
    var success = 0;
    try {
      if (_method == 'ocr') {
        final engine = OcrEngine.fromEndpoint(widget.config.str('ocr_endpoint'));
        final (done, total) = await OcrLocalizer.batch(
          images,
          textLlm,
          langLabel: _lang,
          engine: engine,
          log: _log.add,
          onProgress: (d, t) {
            if (!mounted) return;
            setState(() {
              _progress = t == 0 ? 0 : d / t;
              _progressLabel = '$d/$t';
            });
          },
        );
        success = done;
        if (total > 0 && success == 0) {
          _log.add('  · 未识别到文字（OCR 服务未配置或返回空结果）');
        }
      } else {
        final client = LlmClient(imageLlm);
        for (var i = 0; i < images.length; i++) {
          final path = images[i];
          _log.add('[${i + 1}/${images.length}] ${p.basename(path)}');
          final decoded = await _prepare(path);
          if (decoded == null) continue;
          final bytes = await client.editImage(path, _visionPrompt(decoded.$1, decoded.$2), log: _log.add);
          if (bytes == null) continue;
          Watermark.backup(path);
          File(path).writeAsBytesSync(bytes, flush: true);
          success++;
          if (!mounted) break;
          setState(() {
            _progress = (i + 1) / images.length;
            _progressLabel = '${i + 1}/${images.length}';
          });
        }
      }
    } catch (e) {
      _log.add('✗ 本地化失败: $e');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
    _log.add('图片本地化结束：成功 $success/${images.length}');
    if (!mounted) return;
    showToast(context, '图片本地化完成：成功 $success/${images.length}');
    if (_current != null) _open(_current!);
  }

  Future<(int, int)?> _prepare(String path) async {
    try {
      final bytes = File(path).readAsBytesSync();
      final decoded = await decodeImageSize(bytes);
      return decoded;
    } catch (_) {
      return null;
    }
  }

  String _visionPrompt(int width, int height) =>
      '把图片中的文字翻译成$_lang，其他画面内容与风格保持不变。'
      '输入图分辨率是 $width×$height 像素；输出也必须是 $width×$height 像素。'
      '只输出修改后的图片。';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selectedCount = _selected.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          '左侧选目录，右侧勾选要本地化的图片。写回强制保持原分辨率；原图备份到同目录 _backup/。',
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        Row(
          children: <Widget>[
            SizedBox(
              width: 220,
              child: DropdownButtonFormField<String>(
                initialValue: _method,
                decoration: const InputDecoration(labelText: '本地化方案'),
                items: const <DropdownMenuItem<String>>[
                  DropdownMenuItem(value: 'llm', child: Text('视觉大模型（改画）')),
                  DropdownMenuItem(value: 'ocr', child: Text('OCR 擦写（省 token）')),
                ],
                onChanged: (value) async {
                  widget.config.set(value ?? 'llm', 'image_localize_method');
                  await widget.config.save();
                  if (mounted) setState(() {});
                },
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                _method == 'ocr'
                    ? 'OCR 方案：本地识别文字 → 擦除 → 文本 LLM 翻译 → 写回。适合底色干净的贴图。'
                    : '视觉大模型方案：整图发送图片 LLM 改画，效果更自然，但消耗更多 token。',
                style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              SizedBox(
                width: 300,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        const Expanded(child: Text('图片目录', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13))),
                        IconButton(
                          tooltip: '刷新目录',
                          onPressed: _refresh,
                          icon: const Icon(Icons.refresh, size: 18),
                        ),
                      ],
                    ),
                    Text('共 ${_folders.length} 个目录',
                        style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                    const SizedBox(height: 6),
                    Expanded(
                      child: Container(
                        decoration: BoxDecoration(
                          border: Border.all(color: theme.colorScheme.outlineVariant),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: ListView.builder(
                          itemCount: _folders.length,
                          itemBuilder: (context, index) {
                            final dir = _folders[index];
                            final likely = _likelyGuidebook(dir);
                            final count = _countImages(dir);
                            return ListTile(
                              dense: true,
                              leading: Icon(likely ? Icons.menu_book : Icons.folder_outlined,
                                  size: 20, color: likely ? theme.colorScheme.primary : null),
                              title: Text(_rel(dir),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: likely ? theme.colorScheme.primary : null,
                                    fontWeight: likely ? FontWeight.w600 : null,
                                  )),
                              subtitle: Text(likely ? '建议本地化 · $count 张' : '$count 张',
                                  style: const TextStyle(fontSize: 11)),
                              onTap: () => _open(dir),
                              selected: dir == _current,
                            );
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            _current == null ? '请选择左侧目录' : '${_rel(_current!)}  ·  ${_images.length} 张',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                        TextButton(onPressed: () => setState(() {
                          _selected
                            ..clear()
                            ..addAll(_images.map((e) => e.path));
                        }), child: const Text('全选')),
                        TextButton(onPressed: () => setState(_selected.clear), child: const Text('全不选')),
                        FilledButton.icon(
                          onPressed: _busy || selectedCount == 0 ? null : _run,
                          icon: const Icon(Icons.translate, size: 18),
                          label: Text('本地化选中图片（$selectedCount）'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: Container(
                        decoration: BoxDecoration(
                          border: Border.all(color: theme.colorScheme.outlineVariant),
                          borderRadius: BorderRadius.circular(8),
                          color: theme.colorScheme.surfaceContainerLowest,
                        ),
                        child: _images.isEmpty
                            ? Center(
                                child: Text('请选择左侧目录以预览图片',
                                    style: TextStyle(color: theme.colorScheme.onSurfaceVariant)))
                            : ListView.builder(
                                itemCount: _images.length,
                                itemBuilder: (context, index) {
                                  final file = _images[index];
                                  return CheckboxListTile(
                                    dense: true,
                                    controlAffinity: ListTileControlAffinity.trailing,
                                    value: _selected.contains(file.path),
                                    onChanged: (value) => setState(() {
                                      if (value == true) {
                                        _selected.add(file.path);
                                      } else {
                                        _selected.remove(file.path);
                                      }
                                    }),
                                    secondary: SizedBox(
                                      width: 44,
                                      height: 44,
                                      child: Image.file(file, fit: BoxFit.contain,
                                          errorBuilder: (_, __, ___) => const Icon(Icons.broken_image_outlined)),
                                    ),
                                    title: Text(p.basename(file.path),
                                        maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
                                    subtitle: Text(_sizeLabel(file), style: const TextStyle(fontSize: 11)),
                                  );
                                },
                              ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    ProgressRow(value: _progress, label: _progressLabel),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        LogPanel(control: _log, height: 150),
      ],
    );
  }

  int _countImages(String dir) {
    try {
      return Directory(dir)
          .listSync()
          .whereType<File>()
          .where((f) => imageExtensions.contains(p.extension(f.path).toLowerCase()))
          .length;
    } catch (_) {
      return 0;
    }
  }

  String _sizeLabel(File file) {
    try {
      final bytes = file.readAsBytesSync();
      final size = decodeImageSizeSync(bytes);
      if (size == null) return '?';
      return '${size.$1}×${size.$2}';
    } catch (_) {
      return '?';
    }
  }
}
