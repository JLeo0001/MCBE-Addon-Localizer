import 'types.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:path/path.dart' as p;

import 'net.dart';

/// OpenAI-compatible chat client (text + image editing).
class LlmConfig {
  LlmConfig({required this.baseUrl, required this.apiKey, required this.model, this.proxy = ''});

  final String baseUrl;
  final String apiKey;
  final String model;
  final String proxy;

  bool get configured => apiKey.trim().isNotEmpty;

  static LlmConfig from(Map<String, dynamic>? cfg) {
    cfg ??= const <String, dynamic>{};
    return LlmConfig(
      baseUrl: (cfg['base_url'] ?? '').toString().trim(),
      apiKey: (cfg['api_key'] ?? '').toString().trim(),
      model: (cfg['model'] ?? '').toString().trim(),
      proxy: (cfg['proxy'] ?? '').toString().trim(),
    );
  }
}

class LlmException implements Exception {
  LlmException(this.message);
  final String message;
  @override
  String toString() => message;
}

class LlmClient {
  LlmClient(this.config);

  final LlmConfig config;

  http.Client _client() {
    // Net handles broken system resolvers by falling back to HTTPS DNS.
    return IOClient(Net.createClient(proxy: config.proxy));
  }

  Uri get _endpoint {
    var base = config.baseUrl.trim();
    if (base.isEmpty) throw LlmException('未配Base URL');
    if (!base.startsWith('http')) base = 'https://$base';
    base = base.replaceAll(RegExp(r'/+$'), '');
    return Uri.parse('$base/chat/completions');
  }

  Map<String, String> get _headers => <String, String>{
    'Content-Type': 'application/json',
    if (config.apiKey.isNotEmpty) 'Authorization': 'Bearer ${config.apiKey}',
  };

  /// Runs a chat completion with a 15s heartbeat so long calls stay visible.
  Future<Map<String, dynamic>> complete(
    List<Map<String, dynamic>> messages, {
    double? temperature,
    int? maxTokens,
    LogFn? log,
    String label = 'LLM',
  }) async {
    final body = <String, dynamic>{
      'model': config.model,
      'messages': messages,
      if (temperature != null) 'temperature': temperature,
      if (maxTokens != null) 'max_tokens': maxTokens,
    };
    final client = _client();
    final started = DateTime.now();
    final heartbeat = Timer.periodic(const Duration(seconds: 15), (_) {
      final secs = DateTime.now().difference(started).inSeconds;
      log?.call('  … 仍在等待 $label 响应（${secs}s）');
    });
    try {
      final resp = await client
          .post(_endpoint, headers: _headers, body: jsonEncode(body))
          .timeout(const Duration(seconds: 300));
      if (resp.statusCode >= 400) {
        throw LlmException('HTTP ${resp.statusCode}: ${_short(resp.body)}');
      }
      final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
      if (decoded is! Map<String, dynamic>) throw LlmException('响应不是 JSON 对象');
      return decoded;
    } on SocketException catch (e) {
      final host = _endpoint.host;
      final proxy = config.proxy.trim();
      final hint = proxy.isEmpty
          ? '无法连接 $host：请检查网络、DNS 或是否需要代理。'
          : '无法连接 $host（代理 $proxy）：请确认代理端口可达。';
      throw LlmException('$hint\n原始错误：${e.osError?.message ?? e.message}');
    } catch (e) {
      if (e is LlmException) rethrow;
      throw LlmException('请求失败：$e');
    } finally {
      heartbeat.cancel();
      client.close();
    }
  }

  static String _short(String s) => s.length > 300 ? s.substring(0, 300) : s;

  static String contentOf(Map<String, dynamic> resp) {
    final choices = resp['choices'];
    if (choices is! List || choices.isEmpty) return '';
    final first = choices.first;
    if (first is! Map) return '';
    final msg = first['message'];
    if (msg is Map) {
      final content = msg['content'];
      if (content is String) return content;
      if (content is List) {
        final buf = StringBuffer();
        for (final part in content) {
          if (part is Map) {
            if (part['type'] == 'text' && part['text'] is String) {
              buf.write(part['text']);
            } else if (part['type'] == 'image_url') {
              final url = part['image_url'];
              if (url is Map && url['url'] is String) buf.write('[image]${url['url']}');
            }
          }
        }
        return buf.toString();
      }
    }
    return '';
  }

  /// Translates `key=value` entries; unknown keys keep their original text.
  Future<Map<String, String>> translateLang(
    List<MapEntry<String, String>> entries,
    String langLabel, {
    LogFn? log,
    String label = '语言翻译',
  }) async {
    if (entries.isEmpty) return <String, String>{};
    final prompt = StringBuffer()
      ..writeln('你是 Minecraft 基岩版附加包的本地化译者，把等号右边的文本翻译langLabel')
      ..writeln('规则：只输出 key=译文；保留 § 颜色代码、%s/%d/%1\$s 占位符和 \\n 转义；不要输出解释或空行。');
    for (final e in entries) {
      prompt.writeln('${e.key}=${e.value}');
    }
    final resp = await complete(
      <Map<String, dynamic>>[
        <String, dynamic>{'role': 'user', 'content': prompt.toString()},
      ],
      temperature: 0.2,
      log: log,
      label: label,
    );
    final text = contentOf(resp);
    final known = entries.map((e) => e.key).toSet();
    final out = <String, String>{};
    for (final line in const LineSplitter().convert(text)) {
      final idx = line.indexOf('=');
      if (idx <= 0) continue;
      final key = line.substring(0, idx).trim();
      final value = line.substring(idx + 1).trim();
      if (!known.contains(key) || value.isEmpty) continue;
      out[key] = value;
    }
    return out;
  }

  /// Translates a batch of image strings using the numbered protocol.
  Future<List<String>> translateImageTexts(
    List<String> texts,
    String langLabel, {
    LogFn? log,
    String label = '图片文本翻译',
    String hint = '',
  }) async {
    if (texts.isEmpty) return <String>[];
    final prompt = StringBuffer()
      ..writeln('把下面带编号的 Minecraft 界面文本翻译成$langLabel，保持编号与顺序。')
      ..writeln('只输出 "编号. 译文" 的行，保留 § 颜色代码与占位符，不要解释。');
    if (hint.trim().isNotEmpty) prompt.writeln(hint.trim());
    for (var i = 0; i < texts.length; i++) {
      prompt.writeln('${i + 1}. ${texts[i]}');
    }
    final resp = await complete(
      <Map<String, dynamic>>[
        <String, dynamic>{'role': 'user', 'content': prompt.toString()},
      ],
      temperature: 0.2,
      log: log,
      label: label,
    );
    final text = contentOf(resp);
    final out = List<String>.from(texts);
    final re = RegExp(r'^(\d+)\.\s*(.+)$');
    for (final line in const LineSplitter().convert(text)) {
      final m = re.firstMatch(line.trim());
      if (m == null) continue;
      final idx = int.tryParse(m.group(1)!);
      final value = m.group(2)!.trim();
      if (idx == null || idx < 1 || idx > out.length || value.isEmpty) continue;
      out[idx - 1] = value;
    }
    return out;
  }

  /// Sends an image plus instructions; returns the edited image bytes.
  Future<Uint8List?> editImage(
    String imagePath,
    String prompt, {
    LogFn? log,
    String label = '图片本地',
  }) async {
    final file = File(imagePath);
    if (!file.existsSync()) return null;
    final bytes = file.readAsBytesSync();
    final mime = _mimeFor(imagePath);
    final b64 = base64Encode(bytes);
    final resp = await complete(
      <Map<String, dynamic>>[
        <String, dynamic>{
          'role': 'user',
          'content': <Map<String, dynamic>>[
            <String, dynamic>{
              'type': 'image_url',
              'image_url': <String, dynamic>{'url': 'data:$mime;base64,$b64'},
            },
            <String, dynamic>{'type': 'text', 'text': prompt},
          ],
        },
      ],
      log: log,
      label: label,
    );
    final text = contentOf(resp);
    final dataUri = RegExp(r'data:image/[\w.+-]+;base64,([A-Za-z0-9+/=]+)').firstMatch(text);
    if (dataUri != null) {
      try {
        return base64Decode(dataUri.group(1)!);
      } catch (_) {}
    }
    final url = RegExp(r'https?://[^\s)"\]]+').firstMatch(text);
    if (url != null) {
      try {
        final client = _client();
        final res = await client.get(Uri.parse(url.group(0)!));
        client.close();
        if (res.statusCode == 200) return res.bodyBytes;
      } catch (_) {}
    }
    log?.call('  响应中没有可用图');
    return null;
  }

  static String _mimeFor(String path) {
    switch (p.extension(path).toLowerCase()) {
      case '.png':
        return 'image/png';
      case '.jpg':
      case '.jpeg':
        return 'image/jpeg';
      case '.webp':
        return 'image/webp';
      case '.bmp':
        return 'image/bmp';
      default:
        return 'image/png';
    }
  }
}


