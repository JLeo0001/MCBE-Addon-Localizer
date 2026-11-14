/// Target languages, credit-suffix templates and credit stripping.
library;

class Language {
  const Language(this.code, this.label, this.template, this.script);

  final String code;
  final String label;

  /// Contains `{credit}`; the closing bracket receives the `-with` tool tag.
  final String template;

  /// han | kana | hangul | latin | cyrillic | greek
  final String script;
}

const String defaultCode = 'zh_CN';
const String toolNameHan = 'MCBE 附加包本地化工具';
const String toolNameLatin = 'MCBE Addon Localizer';
const String toolJoiner = '-with ';

const List<Language> languages = <Language>[
  Language('zh_CN', '简体中文', '（{credit}汉化）', 'han'),
  Language('zh_TW', '繁體中文', '（{credit}漢化）', 'han'),
  Language('en_US', 'English (US)', '({credit} Localization)', 'latin'),
  Language('en_GB', 'English (UK)', '({credit} Localization)', 'latin'),
  Language('ja_JP', '日语', '（{credit}翻訳）', 'kana'),
  Language('ko_KR', '韩语', '({credit} 번역)', 'hangul'),
  Language('de_DE', '德语', '({credit} Lokalisierung)', 'latin'),
  Language('fr_FR', '法语', '({credit} Traduction)', 'latin'),
  Language('fr_CA', '法语 (加拿大)', '({credit} Traduction)', 'latin'),
  Language('es_ES', '西班牙语', '({credit} Traducción)', 'latin'),
  Language('es_MX', '西班牙语 (墨西哥)', '({credit} Traducción)', 'latin'),
  Language('pt_BR', '葡萄牙语 (巴西)', '({credit} Tradução)', 'latin'),
  Language('pt_PT', '葡萄牙语', '({credit} Tradução)', 'latin'),
  Language('it_IT', '意大利语', '({credit} Traduzione)', 'latin'),
  Language('nl_NL', '荷兰语', '({credit} Vertaling)', 'latin'),
  Language('pl_PL', '波兰语', '({credit} Tłumaczenie)', 'latin'),
  Language('cs_CZ', '捷克语', '({credit} Překlad)', 'latin'),
  Language('sk_SK', '斯洛伐克语', '({credit} Preklad)', 'latin'),
  Language('hu_HU', '匈牙利语', '({credit} Fordítás)', 'latin'),
  Language('tr_TR', '土耳其语', '({credit} Çeviri)', 'latin'),
  Language('sv_SE', '瑞典语', '({credit} Översättning)', 'latin'),
  Language('da_DK', '丹麦语', '({credit} Oversættelse)', 'latin'),
  Language('nb_NO', '挪威语', '({credit} Oversettelse)', 'latin'),
  Language('fi_FI', '芬兰语', '({credit} Käännös)', 'latin'),
  Language('ru_RU', '俄语', '({credit} Перевод)', 'cyrillic'),
  Language('uk_UA', '乌克兰语', '({credit} Переклад)', 'cyrillic'),
  Language('bg_BG', '保加利亚语', '({credit} Превод)', 'cyrillic'),
  Language('el_GR', '希腊语', '({credit} Μετάφραση)', 'greek'),
  Language('id_ID', '印尼语', '({credit} Terjemahan)', 'latin'),
];

Language languageOf(String? code) {
  if (code != null) {
    for (final l in languages) {
      if (l.code == code) return l;
    }
  }
  return languages.first;
}

String labelOf(String? code) => languageOf(code).label;

String _injectTool(String template, String script) {
  final tool = script == 'latin' ? toolNameLatin : toolNameHan;
  return template.substring(0, template.length - 1) +
      '$toolJoiner$tool' +
      template.substring(template.length - 1);
}

String creditSuffix(String code, String credit) {
  final c = credit.trim().isEmpty ? 'Local' : credit.trim();
  final lang = languageOf(code);
  return _injectTool(lang.template, lang.script).replaceAll('{credit}', c);
}

/// Removes a trailing localization credit, including the `-with <tool>` tag.
String stripCreditSuffix(String name) {
  var out = name;
  for (final lang in languages) {
    for (final tpl in <String>[lang.template, _injectTool(lang.template, lang.script)]) {
      final open = tpl.contains('（') ? '（' : '(';
      final close = tpl.contains('）') ? '）' : ')';
      var body = tpl.substring(1, tpl.length - 1);
      body = body.replaceAll('{credit}', open == '（' ? '[^）]*' : '[^)]*');
      if (body.contains('-with ')) body = body.replaceAll('-with ', r'-with\s*');
      final pattern = RegExp('\\s*${RegExp.escape(open)}$body${RegExp.escape(close)}\\s*\$');
      out = out.replaceAll(pattern, '');
    }
  }
  out = out.replaceAll(RegExp(r'\s*（[^）]*汉化）\s*$'), '');
  out = out.replaceAll(RegExp(r'\s*（[^）]*漢化）\s*$'), '');
  return out.trimRight();
}

String withCredit(String name, String credit, String code) {
  final base = stripCreditSuffix(name).trim();
  return (base.isEmpty ? 'pack' : base) + creditSuffix(code, credit);
}
