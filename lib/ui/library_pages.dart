import 'package:flutter/material.dart';

import '../core/config.dart';
import '../core/glossary.dart';
import '../core/languages.dart';
import '../core/profiles.dart';
import 'widgets.dart';

/// Terminology list with add / delete, applied during translation.
class GlossaryView extends StatefulWidget {
  const GlossaryView({super.key, required this.config});

  final HubConfig config;

  @override
  State<GlossaryView> createState() => _GlossaryViewState();
}

class _GlossaryViewState extends State<GlossaryView> {
  Glossary? _glossary;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final glossary = await Glossary.load();
    if (!mounted) return;
    setState(() => _glossary = glossary);
  }

  Future<void> _add() async {
    final termController = TextEditingController();
    final translationController = TextEditingController();
    String lang = widget.config.str('target_language');
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('新增术语'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            TextField(
              controller: termController,
              decoration: const InputDecoration(labelText: '原文'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: translationController,
              decoration: const InputDecoration(labelText: '固定译文'),
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              initialValue: lang,
              isExpanded: true,
              decoration: const InputDecoration(labelText: '语言'),
              items: languages
                  .map((l) => DropdownMenuItem<String>(value: l.code, child: Text(l.label)))
                  .toList(),
              onChanged: (value) => lang = value ?? lang,
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('添加')),
        ],
      ),
    );
    if (ok != true) return;
    final term = termController.text.trim();
    final translation = translationController.text.trim();
    if (term.isEmpty || translation.isEmpty) return;
    await _glossary!.add(GlossaryTerm(term: term, translation: translation, lang: lang));
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final glossary = _glossary;
    if (glossary == null) return const Center(child: CircularProgressIndicator());
    final q = _query.trim().toLowerCase();
    final terms = glossary.all
        .where((t) => q.isEmpty || t.term.toLowerCase().contains(q) || t.translation.toLowerCase().contains(q))
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text('命中术语的条目会直接使用固定译文，不消耗 token。',
                  style: Theme.of(context).textTheme.bodySmall),
            ),
            FilledButton.icon(
              onPressed: _add,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('新增'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        TextField(
          decoration: const InputDecoration(
            hintText: '搜索术语',
            prefixIcon: Icon(Icons.search, size: 20),
            isDense: true,
          ),
          onChanged: (value) => setState(() => _query = value),
        ),
        const SizedBox(height: 10),
        Expanded(
          child: terms.isEmpty
              ? Center(
                  child: Text(glossary.all.isEmpty ? '还没有术语' : '没有匹配的术语',
                      style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                )
              : ListView.separated(
                  itemCount: terms.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final term = terms[index];
                    final realIndex = glossary.all.indexOf(term);
                    return ListTile(
                      dense: true,
                      title: Text('${term.term}  →  ${term.translation}'),
                      subtitle: Text(labelOf(term.lang), style: const TextStyle(fontSize: 11)),
                      trailing: IconButton(
                        icon: const Icon(Icons.close, size: 16),
                        onPressed: () async {
                          await glossary.removeAt(realIndex);
                          if (mounted) setState(() {});
                        },
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

/// Saved bundles of language + credit + LLM settings.
class ProfilesView extends StatefulWidget {
  const ProfilesView({super.key, required this.config, this.onApplied});

  final HubConfig config;
  final VoidCallback? onApplied;

  @override
  State<ProfilesView> createState() => _ProfilesViewState();
}

class _ProfilesViewState extends State<ProfilesView> {
  Profiles? _profiles;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final profiles = await Profiles.load();
    if (!mounted) return;
    setState(() => _profiles = profiles);
  }

  Future<void> _capture() async {
    final controller = TextEditingController(text: '预设 ${(_profiles?.all.length ?? 0) + 1}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('保存当前配置为预设'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(labelText: '预设名称'),
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('保存')),
        ],
      ),
    );
    if (ok != true) return;
    final name = controller.text.trim();
    if (name.isEmpty) return;
    await _profiles!.save(ConfigProfile.capture(widget.config, name));
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final profiles = _profiles;
    if (profiles == null) return const Center(child: CircularProgressIndicator());
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text('把语言、署名和 LLM 配置打包保存，切换时一次性生效。',
                  style: theme.textTheme.bodySmall),
            ),
            FilledButton.icon(
              onPressed: _capture,
              icon: const Icon(Icons.save_outlined, size: 18),
              label: const Text('保存当前'),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Expanded(
          child: profiles.all.isEmpty
              ? Center(
                  child: Text('还没有预设',
                      style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
                )
              : ListView.separated(
                  itemCount: profiles.all.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final profile = profiles.all[index];
                    return Card(
                      child: ListTile(
                        title: Text(profile.name, style: const TextStyle(fontSize: 14)),
                        subtitle: Text(
                          '${labelOf(profile.language)} · ${profile.credit} · ${profile.textLlm['model'] ?? '无模型'}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11.5),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            TextButton(
                              onPressed: () async {
                                await profile.applyTo(widget.config);
                                widget.onApplied?.call();
                                if (!context.mounted) return;
                                showToast(context, '已应用「${profile.name}」');
                                setState(() {});
                              },
                              child: const Text('应用'),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline, size: 18),
                              onPressed: () async {
                                await profiles.remove(profile.name);
                                if (mounted) setState(() {});
                              },
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
