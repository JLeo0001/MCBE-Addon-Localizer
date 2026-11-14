import 'package:flutter/material.dart';

import '../core/config.dart';
import 'diff_page.dart';
import 'health_page.dart';
import 'memory_page.dart';
import 'tool_pages.dart';

/// Groups the smaller utilities behind one tab with a segmented switch, so the
/// bottom bar stays short.
class ToolsPage extends StatefulWidget {
  const ToolsPage({super.key, required this.config});

  final HubConfig config;

  @override
  State<ToolsPage> createState() => _ToolsPageState();
}

class _ToolsPageState extends State<ToolsPage> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      PbrPage(config: widget.config),
      AchievementPage(config: widget.config),
      EntityPage(config: widget.config),
      HealthPage(config: widget.config),
      const DiffPage(),
      const MemoryPage(),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SegmentedButton<int>(
            segments: const <ButtonSegment<int>>[
              ButtonSegment<int>(value: 0, label: Text('灵动视效')),
              ButtonSegment<int>(value: 1, label: Text('成就')),
              ButtonSegment<int>(value: 2, label: Text('实体')),
              ButtonSegment<int>(value: 3, label: Text('体检')),
              ButtonSegment<int>(value: 4, label: Text('对照')),
              ButtonSegment<int>(value: 5, label: Text('记忆')),
            ],
            selected: <int>{_index},
            showSelectedIcon: false,
            onSelectionChanged: (value) => setState(() => _index = value.first),
          ),
        ),
        const SizedBox(height: 12),
        Expanded(child: pages[_index]),
      ],
    );
  }
}
