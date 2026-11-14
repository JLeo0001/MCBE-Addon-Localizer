import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../core/cloud.dart';
import '../core/config.dart';
import '../core/env.dart';
import '../core/languages.dart';
import '../core/llm.dart';
import '../core/net.dart';
import 'library_pages.dart';
import 'widgets.dart';

/// One entry in the settings hub.
class SettingsCategory {
  const SettingsCategory(this.key, this.title, this.subtitle, this.icon);

  final String key;
  final String title;
  final String subtitle;
  final IconData icon;
}

const List<SettingsCategory> settingsCategories = <SettingsCategory>[
  SettingsCategory('mods', '模组目录', '扫描根目录与默认位置', Icons.folder_special),
  SettingsCategory('language', '目标语言', '翻译输出的语言', Icons.translate),
  SettingsCategory('credit', '本地化署名', '写入包名的译者名称', Icons.badge),
  SettingsCategory('text', '文本 LLM', '语言文件、脚本、名称翻译', Icons.chat_bubble_outline),
  SettingsCategory('image', '图片 LLM / OCR', '改画方案与 OCR 服务', Icons.image_outlined),
  SettingsCategory('profiles', '配置档', '语言 + 署名 + LLM 组合', Icons.tune),
  SettingsCategory('glossary', '术语表', '固定译法，翻译时强制命中', Icons.menu_book_outlined),
  SettingsCategory('quark', '夸克网盘', '导出后上传与分享', Icons.cloud_upload_outlined),
  SettingsCategory('baidu', '百度网盘', '导出后上传', Icons.cloud_outlined),
];

/// Settings hub: category cards, each opening a dedicated detail screen.
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.config, this.onSaved});

  final HubConfig config;
  final VoidCallback? onSaved;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth > 760 ? 3 : (constraints.maxWidth > 520 ? 2 : 1);
        return GridView.builder(
          padding: const EdgeInsets.only(bottom: 16),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            mainAxisExtent: 108,
          ),
          itemCount: settingsCategories.length,
          itemBuilder: (context, index) => _CategoryCard(
            category: settingsCategories[index],
            config: config,
            onChanged: onSaved,
          ),
        );
      },
    );
  }
}

class _CategoryCard extends StatelessWidget {
  const _CategoryCard({required this.category, required this.config, this.onChanged});

  final SettingsCategory category;
  final HubConfig config;
  final VoidCallback? onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => SettingsDetailPage(
              config: config,
              category: category,
              onChanged: onChanged,
            ),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: <Widget>[
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: scheme.primaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(category.icon, color: scheme.onPrimaryContainer),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    Text(category.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                    const SizedBox(height: 2),
                    Text(_summary(),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, size: 18),
            ],
          ),
        ),
      ),
    );
  }

  String _summary() {
    switch (category.key) {
      case 'mods':
        final custom = config.str('mods_base_dir').trim();
        return custom.isEmpty ? '默认：com.mojang' : custom;
      case 'language':
        return labelOf(config.str('target_language'));
      case 'credit':
        return config.str('translator_credit');
      case 'text':
        return _modelSummary('text_llm');
      case 'image':
        final ocr = config.str('ocr_endpoint').trim();
        return '${_modelSummary('image_llm')}${ocr.isEmpty ? '' : ' · OCR 已配置'}';
      case 'quark':
        return config.str('cloud_drives', 'quark') == '' ? '未配置' : '点击配置 Cookie';
      case 'baidu':
        return '点击配置开放平台应用';
      default:
        return category.subtitle;
    }
  }

  String _modelSummary(String section) {
    final model = config.str(section, 'model').trim();
    final key = config.str(section, 'api_key').trim();
    if (model.isEmpty) return '未配置';
    return key.isEmpty ? '$model（缺 API Key）' : model;
  }
}

/// Detail screen for a single settings category.
///
/// Text controllers are created once in [initState]; editing only mutates the
/// config and schedules a debounced write, so the field never rebuilds under
/// the caret.
class SettingsDetailPage extends StatefulWidget {
  const SettingsDetailPage({
    super.key,
    required this.config,
    required this.category,
    this.onChanged,
  });

  final HubConfig config;
  final SettingsCategory category;
  final VoidCallback? onChanged;

  @override
  State<SettingsDetailPage> createState() => _SettingsDetailPageState();
}

class _SettingsDetailPageState extends State<SettingsDetailPage> {
  final Map<String, TextEditingController> _fields = <String, TextEditingController>{};
  final LogControl _log = LogControl();
  late final CloudDrive? _drive;

  HubConfig get _config => widget.config;

  @override
  void initState() {
    super.initState();
    final key = widget.category.key;
    if (key == 'mods') {
      _text('mods_base_dir', _config.str('mods_base_dir'));
    } else if (key == 'credit') {
      _text('translator_credit', _config.str('translator_credit'));
    } else if (key == 'text' || key == 'image') {
      final section = key == 'text' ? 'text_llm' : 'image_llm';
      _text('${section}_base_url', _config.str(section, 'base_url'));
      _text('${section}_api_key', _config.str(section, 'api_key'));
      _text('${section}_model', _config.str(section, 'model'));
      _text('${section}_proxy', _config.str(section, 'proxy'));
      if (key == 'image') _text('ocr_endpoint', _config.str('ocr_endpoint'));
    } else if (key == 'quark' || key == 'baidu') {
      final drive = CloudDrives.from(_config.raw).firstWhere((d) => d.id == key);
      _drive = drive;
      for (final spec in drive.configFields()) {
        _text(spec.key, '${drive.cfg[spec.key] ?? ''}');
      }
    }
  }

  TextEditingController _text(String key, String value) =>
      _fields.putIfAbsent(key, () => TextEditingController(text: value));

  @override
  void dispose() {
    for (final c in _fields.values) {
      c.dispose();
    }
    _config.flush();
    super.dispose();
  }

  void _touch() {
    _config.scheduleSave();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.category.title)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: _body(context),
      ),
    );
  }

  List<Widget> _body(BuildContext context) {
    switch (widget.category.key) {
      case 'mods':
        return _modsBody();
      case 'language':
        return _languageBody();
      case 'credit':
        return _creditBody();
      case 'text':
        return _llmBody('text_llm', withOcr: false);
      case 'image':
        return _llmBody('image_llm', withOcr: true);
      case 'profiles':
        return <Widget>[
          SizedBox(
            height: 520,
            child: ProfilesView(config: _config, onApplied: () => setState(() {})),
          ),
        ];
      case 'glossary':
        return <Widget>[
          SizedBox(height: 520, child: GlossaryView(config: _config)),
        ];
      case 'quark':
      case 'baidu':
        return _driveBody();
      default:
        return <Widget>[Text(widget.category.subtitle)];
    }
  }

  List<Widget> _modsBody() {
    final controller = _fields['mods_base_dir']!;
    return <Widget>[
      Text('留空则使用默认位置：${Env.minecraftBaseDir()}',
          style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: 12),
      TextField(
        controller: controller,
        decoration: const InputDecoration(labelText: '扫描根目录', hintText: '选择包含附加包的任意目录'),
        onChanged: (value) {
          _config.set(value.trim(), 'mods_base_dir');
          _touch();
        },
      ),
      const SizedBox(height: 12),
      Wrap(
        spacing: 10,
        runSpacing: 8,
        children: <Widget>[
          OutlinedButton.icon(
            onPressed: () async {
              final dir = await FilePicker.platform.getDirectoryPath(
                dialogTitle: '选择模组根目录',
                initialDirectory: controller.text.trim().isEmpty
                    ? Env.minecraftBaseDir()
                    : controller.text.trim(),
              );
              if (dir == null) return;
              controller.text = dir;
              _config.set(dir, 'mods_base_dir');
              _touch();
            },
            icon: const Icon(Icons.folder_open),
            label: const Text('浏览…'),
          ),
          TextButton(
            onPressed: () {
              controller.text = '';
              _config.set('', 'mods_base_dir');
              _touch();
            },
            child: const Text('恢复默认'),
          ),
        ],
      ),
      const SizedBox(height: 16),
      Text(
        '扫描规则：递归查找任意层级的 manifest.json 与 .mcaddon / .mcpack / .zip，'
        '按 UUID 依赖自动配对资源包与行为包。',
        style: Theme.of(context).textTheme.bodySmall,
      ),
    ];
  }

  List<Widget> _languageBody() {
    final current = _config.str('target_language');
    return <Widget>[
      DropdownButtonFormField<String>(
        initialValue: languages.any((l) => l.code == current) ? current : defaultCode,
        isExpanded: true,
        decoration: const InputDecoration(labelText: '目标语言'),
        items: languages
            .map((l) => DropdownMenuItem<String>(value: l.code, child: Text('${l.label}（${l.code}）')))
            .toList(),
        onChanged: (value) {
          if (value == null) return;
          _config.set(value, 'target_language');
          _touch();
          setState(() {});
        },
      ),
      const SizedBox(height: 12),
      Text('语言文件会写成 texts/<代码>.lang，署名后缀也会随语言变化。',
          style: Theme.of(context).textTheme.bodySmall),
    ];
  }

  List<Widget> _creditBody() {
    final controller = _fields['translator_credit']!;
    return <Widget>[
      TextField(
        controller: controller,
        decoration: const InputDecoration(labelText: '本地化者名称'),
        onChanged: (value) {
          _config.set(value.trim().isEmpty ? 'Local' : value.trim(), 'translator_credit');
          _touch();
        },
      ),
      const SizedBox(height: 12),
      ValueListenableBuilder<TextEditingValue>(
        valueListenable: controller,
        builder: (context, value, _) {
          final name = value.text.trim().isEmpty ? 'Local' : value.text.trim();
          return Text('包名后缀预览：${creditSuffix(_config.str('target_language'), name)}',
              style: Theme.of(context).textTheme.bodySmall);
        },
      ),
    ];
  }

  List<Widget> _llmBody(String section, {required bool withOcr}) {
    final label = withOcr ? '图片' : '文本';
    return <Widget>[
      Text('兼容 OpenAI 的 /chat/completions 端点。', style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: 12),
      _field('${section}_base_url', 'Base URL', hint: 'https://api.deepseek.com/v1', onChanged: (v) {
        _config.set(v.trim(), section, 'base_url');
        _touch();
      }),
      _field('${section}_api_key', 'API Key', password: true, onChanged: (v) {
        _config.set(v.trim(), section, 'api_key');
        _touch();
      }),
      _field('${section}_model', 'Model', onChanged: (v) {
        _config.set(v.trim(), section, 'model');
        _touch();
      }),
      _field('${section}_proxy', '代理（留空 = 直连）', hint: '127.0.0.1:7890', onChanged: (v) {
        _config.set(v.trim(), section, 'proxy');
        _touch();
      }),
      if (withOcr)
        _field('ocr_endpoint', 'OCR 服务地址（可选）', hint: 'http://127.0.0.1:8868/ocr', onChanged: (v) {
          _config.set(v.trim(), 'ocr_endpoint');
          _touch();
        }),
      const SizedBox(height: 16),
      Wrap(
        spacing: 10,
        runSpacing: 8,
        children: <Widget>[
          OutlinedButton.icon(
            onPressed: () => _testConnection(section, label),
            icon: const Icon(Icons.wifi_tethering),
            label: const Text('测试连接'),
          ),
          OutlinedButton.icon(
            onPressed: () => _diagnoseNetwork(section),
            icon: const Icon(Icons.troubleshoot),
            label: const Text('网络诊断'),
          ),
        ],
      ),
      if (_log.lines.isNotEmpty) ...<Widget>[
        const SizedBox(height: 12),
        LogPanel(control: _log, height: 120),
      ],
    ];
  }

  Widget _field(String key, String label,
      {bool password = false, String hint = '', required ValueChanged<String> onChanged}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextField(
        controller: _fields[key]!,
        obscureText: password,
        decoration: InputDecoration(labelText: label, hintText: hint.isEmpty ? null : hint),
        onChanged: onChanged,
      ),
    );
  }

  List<Widget> _driveBody() {
    final drive = _drive!;
    return <Widget>[
      Text(drive.notes, style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: 12),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('导出后自动上传'),
        value: drive.enabled,
        onChanged: (v) {
          drive.enabled = v;
          _config.scheduleSave();
          setState(() {});
        },
      ),
      for (final spec in drive.configFields())
        _field(spec.key, spec.label, password: spec.kind == 'password', hint: spec.hint, onChanged: (v) {
          drive.cfg[spec.key] = v.trim();
          _touch();
        }),
      if (drive.authMode == 'oauth_code')
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: () async {
              try {
                await Env.openUrl(drive.authorizeUrl());
              } catch (e) {
                if (mounted) showError(context, '$e');
              }
            },
            icon: const Icon(Icons.open_in_browser),
            label: const Text('打开授权页'),
          ),
        ),
      if (drive.authMode == 'cookie')
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: () => Env.openUrl('https://pan.quark.cn/'),
            icon: const Icon(Icons.open_in_browser),
            label: const Text('打开网盘网页'),
          ),
        ),
      const SizedBox(height: 8),
      Row(
        children: <Widget>[
          OutlinedButton.icon(
            onPressed: () => _testDrive(drive),
            icon: const Icon(Icons.cloud),
            label: const Text('测试网盘'),
          ),
        ],
      ),
      const SizedBox(height: 8),
      Text('状态：${drive.statusText()}', style: Theme.of(context).textTheme.bodySmall),
    ];
  }

  Future<void> _diagnoseNetwork(String section) async {
    final base = _config.str(section, 'base_url').trim();
    if (base.isEmpty) {
      showError(context, '请先填写 Base URL');
      return;
    }
    String host;
    try {
      host = Uri.parse(base.contains('://') ? base : 'https://$base').host;
    } catch (_) {
      showError(context, 'Base URL 无法解析');
      return;
    }
    _log.add('网络诊断：$host');
    final report = await Net.diagnose(host);
    for (final line in report.split('\n')) {
      if (line.trim().isNotEmpty) _log.add('  $line');
    }
    if (mounted) setState(() {});
  }

  Future<void> _testConnection(String section, String label) async {
    final cfg = LlmConfig.from(_config.raw[section] as Map<String, dynamic>?);
    if (!cfg.configured) {
      showError(context, '请先填写$label API Key');
      return;
    }
    _log.add('测试$label 连接…');
    try {
      final client = LlmClient(cfg);
      final resp = await client.complete(
        <Map<String, dynamic>>[
          <String, dynamic>{'role': 'user', 'content': 'ping'},
        ],
        maxTokens: 5,
        label: '$label 连接测试',
      );
      final content = LlmClient.contentOf(resp);
      _log.add('✓ 连接成功：${content.length > 40 ? content.substring(0, 40) : content}');
    } catch (e) {
      _log.add('✗ 连接失败：$e');
    }
    if (mounted) setState(() {});
  }

  Future<void> _testDrive(CloudDrive drive) async {
    await _config.flush();
    if (!drive.isAuthorized()) {
      showError(context, '请先完成登录或填写 Cookie');
      return;
    }
    try {
      final name = await drive.testConnection();
      if (!mounted) return;
      showToast(context, '${drive.displayName}可用：$name');
      setState(() {});
    } catch (e) {
      if (mounted) showError(context, '${drive.displayName}测试失败：$e');
    }
  }
}
