import 'package:flutter/material.dart';

import 'core/config.dart';
import 'ui/dashboard_page.dart';
import 'ui/export_page.dart';
import 'ui/image_page.dart';
import 'ui/localize_page.dart';
import 'ui/settings_page.dart';
import 'ui/tools_page.dart';
import 'ui/welcome_page.dart';

const String appTitle = 'MCBE 附加包本地化工具';
const String appVersion = '1.0.0';

class NavItem {
  const NavItem(this.key, this.label, this.shortLabel, this.icon, this.activeIcon);
  final String key;
  final String label;
  final String shortLabel;
  final IconData icon;
  final IconData activeIcon;
}

const List<NavItem> navItems = <NavItem>[
  NavItem('dashboard', '概览', '概览', Icons.dashboard_outlined, Icons.dashboard),
  NavItem('localize', '模组本地化', '本地化', Icons.translate_outlined, Icons.translate),
  NavItem('image', '图片本地化', '图片', Icons.image_outlined, Icons.image),
  NavItem('tools', '工具', '工具', Icons.handyman_outlined, Icons.handyman),
  NavItem('export', '导出本地化包', '导出', Icons.archive_outlined, Icons.archive),
];

class HubApp extends StatefulWidget {
  const HubApp({super.key, required this.config});

  final HubConfig config;

  @override
  State<HubApp> createState() => _HubAppState();
}

class _HubAppState extends State<HubApp> {
  String _screen = 'welcome';
  String _returnScreen = 'welcome';
  int _navIndex = 0;
  HubConfig get _config => widget.config;

  String get _statusLine {
    final name = _config.str('current_mod_name').trim();
    if (name.isEmpty) return '请选择模组';
    final bits = <String>[name];
    if (_config.str('resource_pack_path').trim().isNotEmpty) bits.add('有RP');
    if (_config.str('behavior_pack_path').trim().isNotEmpty) bits.add('有BP');
    return bits.join('  ·  ');
  }

  void _showWelcome() => setState(() => _screen = 'welcome');
  void _showSettings() {
    setState(() {
      _returnScreen = _screen == 'settings' ? _returnScreen : _screen;
      _screen = 'settings';
    });
  }

  void _back() {
    if (_screen == 'settings') {
      setState(() => _screen = _returnScreen == 'toolbox' ? 'toolbox' : 'welcome');
      return;
    }
    _showWelcome();
  }

  Widget _body() {
    switch (_screen) {
      case 'toolbox':
        return _toolbox();
      case 'settings':
        return Padding(
          padding: const EdgeInsets.all(16),
          child: SettingsPage(config: _config, onSaved: () => setState(() {})),
        );
      default:
        return Padding(
          padding: const EdgeInsets.all(16),
          child: WelcomePage(
            config: _config,
            onEnter: (_) => setState(() {
              _screen = 'toolbox';
              _navIndex = 0;
            }),
            onModsChanged: () => setState(() {}),
          ),
        );
    }
  }

  Widget _toolbox() {
    final pages = <Widget>[
      DashboardPage(
        config: _config,
        onNavigate: (index) => setState(() => _navIndex = index),
        onChanged: () => setState(() {}),
      ),
      LocalizePage(config: _config, onPathsChanged: () => setState(() {})),
      ImagePage(config: _config),
      ToolsPage(config: _config),
      ExportPage(config: _config),
    ];
    return Column(
      children: <Widget>[
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1180),
                // IndexedStack keeps scroll position and page state when the
                // user hops between tabs; the long-running job itself lives in
                // TaskCenter and is unaffected either way.
                child: IndexedStack(index: _navIndex, children: pages),
              ),
            ),
          ),
        ),
        NavigationBar(
          selectedIndex: _navIndex,
          labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
          height: 68,
          onDestinationSelected: (index) => setState(() => _navIndex = index),
          destinations: navItems
              .map((item) => NavigationDestination(
                    icon: Icon(item.icon),
                    selectedIcon: Icon(item.activeIcon),
                    label: item.shortLabel,
                    tooltip: item.label,
                  ))
              .toList(),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        leading: _screen == 'welcome'
            ? null
            : IconButton(
                tooltip: '返回',
                onPressed: _back,
                icon: const Icon(Icons.arrow_back),
              ),
        title: Row(
          children: <Widget>[
            Text('v$appVersion',
                style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(width: 12),
            Flexible(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                child: Text(
                  _statusLine,
                  key: ValueKey<String>(_statusLine),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
            ),
          ],
        ),
        actions: <Widget>[
          if (_screen != 'settings')
            IconButton(
              tooltip: '设置',
              onPressed: _showSettings,
              icon: const Icon(Icons.settings),
            ),
          const SizedBox(width: 4),
        ],
      ),
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 280),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (child, animation) => FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: Tween<Offset>(begin: const Offset(0, 0.02), end: Offset.zero).animate(animation),
            child: child,
          ),
        ),
        child: KeyedSubtree(
          key: ValueKey<String>('$_screen-$_navIndex'),
          child: _body(),
        ),
      ),
    );
  }
}
