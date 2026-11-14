import 'package:flutter/material.dart';

import '../core/report.dart';

/// Before/after view of the last translation pass, with manual corrections.
class DiffPage extends StatefulWidget {
  const DiffPage({super.key});

  @override
  State<DiffPage> createState() => _DiffPageState();
}

class _DiffPageState extends State<DiffPage> {
  String _query = '';

  Future<void> _edit(ReportEntry entry) async {
    final controller = TextEditingController(text: entry.after);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('修改译文'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(entry.key, style: const TextStyle(fontSize: 11, fontFamily: 'monospace')),
            const SizedBox(height: 6),
            Text(entry.before, style: const TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 10),
            TextField(
              controller: controller,
              maxLines: 3,
              decoration: const InputDecoration(labelText: '译文'),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('保存')),
        ],
      ),
    );
    if (ok != true) return;
    final value = controller.text.trim();
    if (value.isEmpty) return;
    entry.after = value;
    final applied = TranslationReport.instance.applyEdit(entry);
    if (!mounted) return;
    if (applied) {
      setState(() {});
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('写入失败，文件可能已被移动')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnimatedBuilder(
      animation: TranslationReport.instance,
      builder: (context, _) {
        final report = TranslationReport.instance;
        final q = _query.trim().toLowerCase();
        final entries = report.entries
            .where((e) =>
                q.isEmpty ||
                e.key.toLowerCase().contains(q) ||
                e.before.toLowerCase().contains(q) ||
                e.after.toLowerCase().contains(q))
            .toList();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text('本次运行共记录 ${report.length} 条改动，点任意一行可手工修订。',
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                ),
                TextButton(
                  onPressed: report.length == 0 ? null : report.clear,
                  child: const Text('清空'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              decoration: const InputDecoration(
                hintText: '搜索键或文本',
                prefixIcon: Icon(Icons.search, size: 20),
                isDense: true,
              ),
              onChanged: (value) => setState(() => _query = value),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: entries.isEmpty
                  ? Center(
                      child: Text(report.length == 0 ? '跑一次翻译后这里会显示逐条对照' : '没有匹配的条目',
                          style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
                    )
                  : ListView.separated(
                      itemCount: entries.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final entry = entries[index];
                        return ListTile(
                          dense: true,
                          title: Text(entry.before,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 12,
                                  color: theme.colorScheme.onSurfaceVariant,
                                  decoration: TextDecoration.lineThrough)),
                          subtitle: Text(entry.after,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 13)),
                          trailing: const Icon(Icons.edit_outlined, size: 16),
                          onTap: () => _edit(entry),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }
}
