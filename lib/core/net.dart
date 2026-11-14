import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Networking helpers that survive a broken system resolver.
///
/// Some Windows/Android setups resolve nothing through `getaddrinfo` while
/// plain HTTPS still works (browsers hide this behind their own DoH). When the
/// system lookup fails we ask a public resolver over HTTPS — connecting to a
/// hard-coded IP with the resolver's SNI — then dial the site by IP while
/// keeping the original hostname for TLS.
class Net {
  static const List<({String ip, String sni})> _dohProviders = <({String ip, String sni})>[
    (ip: '223.5.5.5', sni: 'dns.alidns.com'),
    (ip: '1.1.1.1', sni: 'cloudflare-dns.com'),
    (ip: '8.8.8.8', sni: 'dns.google'),
  ];

  static final Map<String, List<String>> _cache = <String, List<String>>{};

  /// Diagnostics for the settings screen.
  static Future<String> diagnose(String host) async {
    final out = StringBuffer('目标主机：$host\n');
    final sw = Stopwatch()..start();
    try {
      final list = await InternetAddress.lookup(host).timeout(const Duration(seconds: 5));
      out.writeln('系统 DNS：${list.map((e) => e.address).join(', ')}（${sw.elapsedMilliseconds}ms）');
    } catch (e) {
      out.writeln('系统 DNS：失败 —— ${_short(e)}');
    }
    sw.reset();
    final doh = await _dohLookup(host);
    out.writeln(doh.isEmpty
        ? 'HTTPS DNS：失败'
        : 'HTTPS DNS：${doh.join(', ')}（${sw.elapsedMilliseconds}ms）');
    sw.reset();
    try {
      final ips = await resolve(host);
      final socket = await Socket.connect(ips.first, 443, timeout: const Duration(seconds: 6));
      socket.destroy();
      out.writeln('TCP 443：可连接 ${ips.first}（${sw.elapsedMilliseconds}ms）');
    } catch (e) {
      out.writeln('TCP 443：失败 —— ${_short(e)}');
    }
    return out.toString();
  }

  static String _short(Object e) {
    final text = '$e';
    return text.length > 120 ? text.substring(0, 120) : text;
  }

  /// System lookup first, DoH as a fallback. Throws when both fail.
  static Future<List<String>> resolve(String host) async {
    if (_cache.containsKey(host)) return _cache[host]!;
    try {
      final list = await InternetAddress.lookup(host).timeout(const Duration(seconds: 5));
      final ips = list.map((e) => e.address).where((e) => e.isNotEmpty).toList();
      if (ips.isNotEmpty) {
        _cache[host] = ips;
        return ips;
      }
    } catch (_) {
      // fall through to DoH
    }
    final doh = await _dohLookup(host);
    if (doh.isEmpty) throw SocketException('无法解析 $host', osError: const OSError('域名解析失败', 7));
    _cache[host] = doh;
    return doh;
  }

  static Future<List<String>> _dohLookup(String host) async {
    for (final provider in _dohProviders) {
      try {
        final body = await _httpsGet(
          ip: provider.ip,
          sni: provider.sni,
          path: '/resolve?name=$host&type=A',
          accept: 'application/dns-json',
        );
        final data = jsonDecode(body);
        final answers = data is Map ? data['Answer'] : null;
        final ips = <String>[];
        if (answers is List) {
          for (final a in answers) {
            if (a is Map && a['type'] == 1 && a['data'] is String) {
              ips.add(a['data'] as String);
            }
          }
        }
        if (ips.isNotEmpty) return ips;
      } catch (_) {
        continue;
      }
    }
    return <String>[];
  }

  /// Minimal HTTPS GET that pins the IP but verifies the certificate against
  /// [sni].
  static Future<String> _httpsGet({
    required String ip,
    required String sni,
    required String path,
    required String accept,
  }) async {
    final raw = await Socket.connect(ip, 443, timeout: const Duration(seconds: 6));
    final secure = await SecureSocket.secure(raw, host: sni);
    try {
      secure.write('GET $path HTTP/1.1\r\n'
          'Host: $sni\r\n'
          'Accept: $accept\r\n'
          'User-Agent: arc-localizer\r\n'
          'Connection: close\r\n\r\n');
      final bytes = <int>[];
      await for (final chunk in secure.timeout(const Duration(seconds: 8))) {
        bytes.addAll(chunk);
      }
      final text = utf8.decode(bytes, allowMalformed: true);
      final split = text.indexOf('\r\n\r\n');
      if (split < 0) throw const HttpException('bad response');
      final head = text.substring(0, split);
      if (!head.startsWith('HTTP/1.1 200') && !head.startsWith('HTTP/1.0 200')) {
        throw HttpException('resolver returned ${head.split('\r\n').first}');
      }
      return text.substring(split + 4);
    } finally {
      secure.destroy();
    }
  }

  /// HttpClient used by the LLM client. Proxy support is kept; name resolution
  /// stays with the platform (the DoH path above is diagnostic only, because
  /// Dart cannot hand a TLS socket with a custom SNI to `HttpClient`).
  static HttpClient createClient({String proxy = ''}) {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    if (proxy.trim().isNotEmpty) {
      final hostPort = proxy.trim().replaceFirst(RegExp(r'^\w+://'), '');
      client.findProxy = (_) => 'PROXY $hostPort';
    }
    return client;
  }
}
