import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// One entry in the "recent projects" list.
class RecentProject {
  RecentProject({
    required this.name,
    required this.resourcePack,
    required this.behaviorPack,
    required this.openedAt,
  });

  final String name;
  final String? resourcePack;
  final String? behaviorPack;
  final DateTime openedAt;

  bool get hasRp => resourcePack != null && resourcePack!.isNotEmpty;
  bool get hasBp => behaviorPack != null && behaviorPack!.isNotEmpty;

  String get key => '${resourcePack ?? ''}|${behaviorPack ?? ''}';

  bool get exists =>
      (hasRp && Directory(resourcePack!).existsSync()) ||
      (hasBp && Directory(behaviorPack!).existsSync());

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'resource_pack': resourcePack ?? '',
        'behavior_pack': behaviorPack ?? '',
        'opened_at': openedAt.toIso8601String(),
      };

  static RecentProject fromJson(Map<String, dynamic> json) => RecentProject(
        name: '${json['name'] ?? ''}',
        resourcePack: '${json['resource_pack'] ?? ''}'.isEmpty ? null : '${json['resource_pack']}',
        behaviorPack: '${json['behavior_pack'] ?? ''}'.isEmpty ? null : '${json['behavior_pack']}',
        openedAt: DateTime.tryParse('${json['opened_at'] ?? ''}') ?? DateTime.now(),
      );
}

/// Persists the last opened mods so the dashboard can offer one-tap resume.
class RecentProjects {
  RecentProjects._(this._file, this._items);

  final File _file;
  final List<RecentProject> _items;

  static const int maxItems = 12;
  static RecentProjects? _instance;

  static Future<RecentProjects> load() async {
    final cached = _instance;
    if (cached != null) return cached;
    final dir = await getApplicationSupportDirectory();
    final file = File(p.join(dir.path, 'recent_projects.json'));
    final items = <RecentProject>[];
    if (file.existsSync()) {
      try {
        final data = jsonDecode(file.readAsStringSync());
        if (data is List) {
          for (final row in data) {
            if (row is Map<String, dynamic>) items.add(RecentProject.fromJson(row));
          }
        }
      } catch (_) {
        items.clear();
      }
    }
    return _instance = RecentProjects._(file, items);
  }

  List<RecentProject> get items => List<RecentProject>.unmodifiable(_items);

  Future<void> remember(RecentProject project) async {
    _items.removeWhere((e) => e.key == project.key);
    _items.insert(0, project);
    if (_items.length > maxItems) _items.removeRange(maxItems, _items.length);
    await _flush();
  }

  Future<void> remove(RecentProject project) async {
    _items.removeWhere((e) => e.key == project.key);
    await _flush();
  }

  Future<void> clear() async {
    _items.clear();
    await _flush();
  }

  Future<void> _flush() async {
    try {
      await _file.parent.create(recursive: true);
      await _file.writeAsString(
        jsonEncode(_items.map((e) => e.toJson()).toList()),
        flush: true,
      );
    } catch (_) {
      // best effort
    }
  }
}
