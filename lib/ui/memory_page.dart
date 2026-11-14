import 'package:flutter/material.dart';

import '../core/translator.dart';
import 'widgets.dart';

/// Browses everything the translator has cached so far.
class MemoryPage extends StatefulWidget {
  const MemoryPage({super.key});

  @override
  State<MemoryPage> createState() => _MemoryPageState();
}

class _MemoryPageState extends State<MemoryPage> {
  TranslationCache? _cache;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final cache = await TranslationCache.load();
    if (!mounted) return;
    setState(() => _cache = cache);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cache = _cache;
    if (cache == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final entries = cache.entries.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final q = _query.trim().toLowerCase();
    final visible = q.isEmpty
        ? entries
        : entries.where((e) {
            final parts = e.key.split('\u0000');
            final text = parts.length > 1 ? parts[1] : e.key;
            return text.toLowerCase().contains(q) || e.value.toLowerCase().contains(q);
          }).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text('已缓存 ${cache.length} 条翻译，命中后不再重复请求。',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ),
            TextButton.icon(
              onPressed: cache.length == 0
                  ? null
                  : () async {
                      final ok = await confirmDialog(context,
                          title: '清空翻译记忆', message: '将删除全部 ${cache.length} 条缓存，无法恢复。');
                      if (!ok) return;
                      cache.clearAll();
                      await cache.flush();
                      if (mounted) setState(() {});
                    },
              icon: const Icon(Icons.delete_sweep_outlined, size: 18),
              label: const Text('清空'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        TextField(
          decoration: const InputDecoration(
            hintText: '搜索原文或译文',
            prefixIcon: Icon(Icons.search, size: 20),
            isDense: true,
          ),
          onChanged: (value) => setState(() => _query = value),
        ),
        const SizedBox(height: 10),
        Expanded(
          child: visible.isEmpty
              ? Center(
                  child: Text(cache.length == 0 ? '还没有缓存，跑一次翻译后这里会有内容' : '没有匹配的条目',
                      style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
                )
              : ListView.separated(
                  itemCount: visible.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final entry = visible[index];
                    final parts = entry.key.split('\u0000');
                    final lang = parts.isNotEmpty ? parts.first : '';
                    final source = parts.length > 1 ? parts[1] : entry.key;
                    return ListTile(
                      dense: true,
                      title: Text(source, maxLines: 2, overflow: TextOverflow.ellipsis),
                      subtitle: Text(entry.value,
                          maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
                      leading: CircleAvatar(
                        radius: 16,
                        child: Text(lang.split('_').first,
                            style: const TextStyle(fontSize: 9)),
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.close, size: 16),
                        tooltip: '删除这条',
                        onPressed: () async {
                          cache.removeKey(entry.key);
                          await cache.flush();
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
