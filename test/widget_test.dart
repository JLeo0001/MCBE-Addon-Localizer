import 'package:flutter_test/flutter_test.dart';

import 'package:arc_localizer/core/languages.dart';

void main() {
  group('credit suffix', () {
    test('appends the localized credit with the tool tag', () {
      final suffix = creditSuffix('zh_CN', 'JasonLeoZhou');
      expect(suffix.contains('JasonLeoZhou'), isTrue);
      expect(suffix.contains('汉化'), isTrue);
    });

    test('replaces an existing credit instead of stacking it', () {
      final once = withCredit('Example Pack', 'JasonLeoZhou', 'zh_CN');
      final twice = withCredit(once, 'JasonLeoZhou', 'zh_CN');
      expect(twice, once);
    });

    test('strips a previous credit', () {
      final credited = withCredit('Example Pack', 'JasonLeoZhou', 'zh_CN');
      expect(stripCreditSuffix(credited), 'Example Pack');
    });
  });

  group('language table', () {
    test('falls back to zh_CN for unknown codes', () {
      expect(languageOf('xx_XX').code, 'zh_CN');
    });

    test('has unique codes', () {
      final codes = languages.map((l) => l.code).toSet();
      expect(codes.length, languages.length);
    });
  });
}
