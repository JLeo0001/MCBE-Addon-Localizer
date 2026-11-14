import 'dart:io';

import 'package:path/path.dart' as p;

import 'config.dart';
import 'display_name.dart';
import 'env.dart';
import 'export_service.dart';
import 'glossary.dart';
import 'lang_files.dart';
import 'languages.dart';
import 'llm.dart';
import 'manifest.dart';
import 'models.dart';
import 'pack_ops.dart';
import 'pack_rename.dart';
import 'report.dart';
import 'script_localize.dart';
import 'task_center.dart';
import 'translator.dart';
import 'types.dart';

/// The four localization steps, independent of any widget.
///
/// Both the page and the batch runner drive this, so behaviour cannot drift.
class LocalizationPipeline {
  LocalizationPipeline(this.config, this.log, {this.onPathsChanged});

  final HubConfig config;
  final LogFn log;
  final void Function(String entry, String path)? onPathsChanged;

  TaskCenter get _task => TaskCenter.instance;
  String get code => config.str('target_language');
  String get lang => labelOf(code);
  String get credit {
    final c = config.str('translator_credit').trim();
    return c.isEmpty ? 'Local' : c;
  }

  String? get rp => Env.resolvePackDir(config.str('resource_pack_path'));
  String? get bp => Env.resolvePackDir(config.str('behavior_pack_path'));

  List<(String, String)> get packs => <(String, String)>[
        if (rp != null) ('资源包', rp!),
        if (bp != null) ('行为包', bp!),
      ];

  bool get configured {
    final llm = LlmConfig.from(config.raw['text_llm'] as Map<String, dynamic>?);
    return llm.configured;
  }

  Future<void> displayNames() async {
    var found = 0, standardized = 0, fallback = 0;
    for (final pack in packs) {
      if (_task.cancelRequested) break;
      final (f, s, fb) = DisplayNameService.standardizeInPack(pack.$2, code, log: log);
      found += f;
      standardized += s;
      fallback += fb;
    }
    log('Display Name 结束：找到 $found，标准化 $standardized，回退直译 $fallback');
  }

  Future<void> translateLanguages() async {
    final llmCfg = LlmConfig.from(config.raw['text_llm'] as Map<String, dynamic>?);
    if (!llmCfg.configured) {
      log('✗ 未配置文本翻译 API Key');
      return;
    }
    final cache = await TranslationCache.load();
    final translator = BatchTranslator(LlmClient(llmCfg), cache);
    final glossary = await Glossary.load();

    final targets = <(String, List<LangLine>, List<MapEntry<String, String>>)>[];
    for (final pack in packs) {
      log('—— ${pack.$1}: ${p.basename(pack.$2)} ——');
      ManifestService.normalizeHeaderKeys(
        pack.$2,
        log,
        code: code,
        upsert: (path, entries) {
          final texts = p.join(path, 'texts');
          if (!Directory(texts).existsSync()) return;
          LangFiles.upsert(p.join(texts, 'en_US.lang'), entries);
          final target = p.join(texts, '$code.lang');
          if (File(target).existsSync()) LangFiles.upsert(target, entries);
        },
      );
      final texts = Directory(p.join(pack.$2, 'texts'));
      if (!texts.existsSync()) {
        log('  无 texts/，跳过语言文件');
        continue;
      }
      LangFiles.ensureLanguageInLanguages(texts.path, code);
      final target = LangFiles.copyLangToTarget(texts.path, code, log);
      if (target == null) continue;
      LangFiles.syncMissingFromEnUs(texts.path, code, log);
      targets.add(_pendingFor(target, texts.path));
    }

    final allTexts = <String>[];
    for (final t in targets) {
      for (final e in t.$3) {
        if (!allTexts.contains(e.value)) allTexts.add(e.value);
      }
    }
    log('待翻译条目 ${targets.fold<int>(0, (s, t) => s + t.$3.length)} 条，去重后 ${allTexts.length} 条');
    _task.setStage('语言翻译');

    final translated = await translator.translate(
      allTexts,
      lang,
      langCode: code,
      log: log,
      glossary: glossary.map(code),
      onProgress: (done, total) => _task.setProgress(done, total),
      cancelled: () => _task.cancelRequested,
    );

    for (final t in targets) {
      final original = File(t.$1).readAsStringSync();
      final mapping = <String, String>{};
      for (final e in t.$3) {
        final value = translated[e.value];
        if (value != null && value.trim().isNotEmpty) mapping[e.key] = value;
      }
      if (mapping.isEmpty) continue;
      File(t.$1).writeAsStringSync(LangFiles.rebuild(original, t.$2, mapping), flush: true);
      TranslationReport.instance.record(t.$1, t.$2, mapping);
      log('已写入 ${p.basename(t.$1)}（${mapping.length} 条）');
    }

    await moveToDevelopment();
    await syncFolderNames();
    await postFormat();
    log('语言文件翻译结束');
  }

  (String, List<LangLine>, List<MapEntry<String, String>>) _pendingFor(String target, String textsDir) {
    final original = File(target).readAsStringSync();
    final parsed = LangFiles.parse(original);
    final enMap = LangFiles.readMap(p.join(textsDir, 'en_US.lang'));
    final language = languageOf(code);
    final pending = <MapEntry<String, String>>[];
    for (final line in parsed) {
      if (line.kind != LangLineKind.entry) continue;
      final key = line.key;
      final value = line.value;
      if (key == null || value == null) continue;
      final en = enMap[key];
      if (en != null && value == en) {
        if (!code.startsWith('en')) pending.add(MapEntry(key, value));
      } else if (_needsTranslation(value, language)) {
        pending.add(MapEntry(key, value));
      }
    }
    log('  ${p.basename(target)} 待译 ${pending.length} 条');
    return (target, parsed, pending);
  }

  bool _needsTranslation(String value, Language language) {
    if (value.trim().isEmpty) return false;
    if (language.script == 'latin') return RegExp(r'[A-Za-z]{3,}').hasMatch(value);
    final latin = RegExp(r'[A-Za-z]').allMatches(value).length;
    if (latin == 0) return false;
    final cjk = RegExp(r'[\u4e00-\u9fff]').allMatches(value).length;
    return cjk / latin < 0.2;
  }

  Future<void> scripts() async {
    final behavior = bp;
    if (behavior == null) {
      log('✗ 当前模组没有行为包');
      return;
    }
    final llmCfg = LlmConfig.from(config.raw['text_llm'] as Map<String, dynamic>?);
    if (!llmCfg.configured) {
      log('✗ 未配置文本翻译 API Key');
      return;
    }
    _task.setStage('脚本本地化');
    final (files, hits, written, rolled) = await ScriptLocalizer.localize(
      behavior,
      llmCfg,
      langLabel: lang,
      log: log,
      cancelled: () => _task.cancelRequested,
    );
    log('脚本本地化结束：文件 $files，命中 $hits，写入 $written，回退 $rolled');
  }

  Future<void> applyCredit() async {
    for (final pack in packs) {
      CreditService.applyToPack(pack.$2, credit, code, log);
    }
    await moveToDevelopment();
    await syncFolderNames();
    await postFormat();
    log('署名完成：${creditSuffix(code, credit)}');
  }

  Future<void> moveToDevelopment() async {
    var moved = false;
    for (final pack in packs) {
      final dest = PackManage.moveToDevelopment(pack.$2);
      if (dest != null) {
        moved = true;
        log('  已移入开发目录: ${p.basename(dest)}');
      }
    }
    if (moved) _notify();
  }

  Future<void> syncFolderNames() async {
    var changed = false;
    for (final entry in <String>['resource_pack_path', 'behavior_pack_path']) {
      final current = config.str(entry);
      if (current.trim().isEmpty) continue;
      final plan = PackRename.planForPack(current, code);
      if (!plan.changed) continue;
      final (count, errors) = PackRename.applyRenames(<RenamePlan>[plan], log: log);
      if (count > 0) {
        config.set(plan.dest, entry);
        changed = true;
      }
      if (errors.isNotEmpty) log('  ✗ 重命名失败: ${errors.first}');
    }
    if (changed) {
      await config.save();
      _notify();
      log('已按本地化包名同步文件夹');
    }
  }

  Future<void> postFormat() async {
    var langs = 0, jsons = 0;
    for (final pack in packs) {
      final texts = Directory(p.join(pack.$2, 'texts'));
      if (texts.existsSync()) {
        for (final file in texts.listSync().whereType<File>()) {
          if (!file.path.toLowerCase().endsWith('.lang')) continue;
          if (LangFiles.normalizeLayout(file.path)) langs++;
        }
      }
      final (jsonFiles, _) = FormatService.collectTargets(pack.$2);
      final (ok, _, _) = FormatService.formatJsonFiles(jsonFiles, log: log);
      jsons += ok;
    }
    if (langs > 0 || jsons > 0) log('  已整理格式：lang $langs 个，JSON $jsons 个');
  }

  /// ① → ② → ③ → ④, stopping early when the user asks to cancel.
  Future<void> oneClick() async {
    if (!configured) {
      log('✗ 未配置文本翻译 API Key');
      return;
    }
    await displayNames();
    if (_task.cancelRequested) return;
    await translateLanguages();
    if (_task.cancelRequested) return;
    await scripts();
    if (_task.cancelRequested) return;
    await applyCredit();
  }

  void _notify() {
    onPathsChanged?.call('resource_pack_path', config.str('resource_pack_path'));
    onPathsChanged?.call('behavior_pack_path', config.str('behavior_pack_path'));
  }
}
