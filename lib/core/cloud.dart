import 'types.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'models.dart';

class CloudDriveException implements Exception {
  CloudDriveException(this.message);
  final String message;
  @override
  String toString() => message;
}

class ConfigField {
  const ConfigField(this.key, this.label, {this.kind = 'text', this.hint = ''});
  final String key;
  final String label;
  final String kind; // text | password
  final String hint;
}

abstract class CloudDrive {
  CloudDrive(this.cfg);

  final Map<String, dynamic> cfg;

  String get id;
  String get displayName;
  bool get supportsShare => false;
  String get authMode => 'none'; // oauth_code | cookie | none
  String get notes => '';

  Map<String, dynamic> defaultConfig() => <String, dynamic>{'enabled': false};
  List<ConfigField> configFields() => const <ConfigField>[];

  bool get enabled => cfg['enabled'] == true;
  set enabled(bool value) => cfg['enabled'] = value;

  bool isAuthorized();
  String statusText() => '${isAuthorized() ? '已就' : '未就'} · $displayName';
  String authorizeUrl() => throw CloudDriveException('该网盘无需网页授权');
  Future<void> exchangeCode(String code) async =>
      throw CloudDriveException('该网盘不支持授权码登');
  Future<String> testConnection() async => throw CloudDriveException('未实现连接测');
  Future<UploadResult> upload(String localPath, {LogFn? log});
  Future<ShareResult> share(UploadResult uploaded, {LogFn? log}) async =>
      throw CloudDriveException('不支持自动分');

  Future<PublishResult> publish(String localPath, {LogFn? log}) async {
    try {
      final uploaded = await upload(localPath, log: log);
      ShareResult? shared;
      if (supportsShare) {
        try {
          shared = await share(uploaded, log: log);
        } catch (e) {
          log?.call('  分享失败: $e');
        }
      }
      return PublishResult(
        driverId: id,
        driverName: displayName,
        uploaded: uploaded,
        share: shared,
      );
    } catch (e) {
      return PublishResult(driverId: id, driverName: displayName, error: '$e');
    }
  }
}

String _md5Hex(List<int> bytes) => md5.convert(bytes).toString();
String _sha1Hex(List<int> bytes) => sha1.convert(bytes).toString();

/// Quark drive (cookie auth, multipart upload, share link).
class QuarkDrive extends CloudDrive {
  QuarkDrive(super.cfg);

  static const String api = 'https://drive-pc.quark.cn/1/clouddrive';
  static const String ossUa = 'aliyun-sdk-js/6.6.1 Chrome 98.0.4758.80 on Windows 10 64-bit';

  @override
  String get id => 'quark';
  @override
  String get displayName => '夸克网盘';
  @override
  bool get supportsShare => true;
  @override
  String get authMode => 'cookie';
  @override
  String get notes => '在浏览器登录 pan.quark.cn，F12 Network 复制 Cookie 粘贴到下方';

  @override
  Map<String, dynamic> defaultConfig() => <String, dynamic>{
    'enabled': false,
    'cookie': '',
    'parent_fid': '0',
    'share_password': '',
  };

  @override
  List<ConfigField> configFields() => const <ConfigField>[
    ConfigField('cookie', 'Cookie', kind: 'password'),
    ConfigField('parent_fid', '目标目录 FID', hint: '0 = 根目'),
    ConfigField('share_password', '分享提取', hint: '留空则公开分享'),
  ];

  @override
  bool isAuthorized() => (cfg['cookie'] ?? '').toString().trim().isNotEmpty;

  String get _cookie => (cfg['cookie'] ?? '').toString();

  Map<String, String> get _headers => <String, String>{
    'Accept': 'application/json, text/plain, */*',
    'Origin': 'https://pan.quark.cn',
    'Referer': 'https://pan.quark.cn/',
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/120.0.0.0 Safari/537.36',
    'Cookie': _cookie,
  };

  Uri _uri(String path, [Map<String, String>? extra]) => Uri.parse('$api$path').replace(
    queryParameters: <String, String>{'pr': 'ucpro', 'fr': 'pc', ...?extra},
  );

  dynamic _decode(http.Response resp) {
    if (resp.statusCode >= 400) {
      throw CloudDriveException('HTTP ${resp.statusCode}');
    }
    final text = utf8.decode(resp.bodyBytes);
    dynamic data;
    try {
      data = jsonDecode(text);
    } catch (_) {
      throw CloudDriveException('响应JSON');
    }
    final status = data['status'];
    final code = data['code'];
    if ((status is num && status >= 400) || (code != null && code != 0)) {
      throw CloudDriveException('${data['message'] ?? data['error'] ?? code}');
    }
    return data;
  }

  @override
  Future<String> testConnection() async {
    final resp = await http.get(_uri('/member'), headers: _headers);
    final data = _decode(resp);
    final d = data['data'];
    final name = (d is Map ? (d['nickname'] ?? d['member_name']) : null)?.toString() ?? '';
    return name.isEmpty ? '夸克账号' : name;
  }

  @override
  Future<UploadResult> upload(String localPath, {LogFn? log}) async {
    final file = File(localPath);
    final data = file.readAsBytesSync();
    final fileMd5 = _md5Hex(data);
    final fileSha1 = _sha1Hex(data);
    final fid = (cfg['parent_fid'] ?? '0').toString();

    log?.call('  预上传 ${p.basename(localPath)}（${(data.length / 1048576).toStringAsFixed(1)} MB）');
    final preResp = await http.post(
      _uri('/file/upload/pre'),
      headers: <String, String>{..._headers, 'Content-Type': 'application/json'},
      body: jsonEncode(<String, dynamic>{
        'ccp_hash_update': true,
        'dir_name': '',
        'file_name': p.basename(localPath),
        'format_type': 'application/octet-stream',
        'l_created_at': DateTime.now().millisecondsSinceEpoch,
        'l_updated_at': DateTime.now().millisecondsSinceEpoch,
        'pdir_fid': fid,
        'size': data.length,
      }),
    );
    final pre = _decode(preResp);
    final pd = pre['data'] as Map<String, dynamic>;
    final taskId = '${pd['task_id'] ?? ''}';
    if (taskId.isEmpty) throw CloudDriveException('预上传失败（Cookie 可能已过期）');

    final hashResp = await http.post(
      _uri('/file/update/hash'),
      headers: <String, String>{..._headers, 'Content-Type': 'application/json'},
      body: jsonEncode(<String, dynamic>{'md5': fileMd5, 'sha1': fileSha1, 'task_id': taskId}),
    );
    final hashData = _decode(hashResp)['data'] as Map<String, dynamic>;
    if (hashData['finish'] == true) {
      log?.call('  秒传完成');
      return UploadResult(
        remoteId: '${hashData['fid'] ?? ''}',
        remoteLabel: p.basename(localPath),
      );
    }

    final authResp = await http.post(
      _uri('/file/upload/auth'),
      headers: <String, String>{..._headers, 'Content-Type': 'application/json'},
      body: jsonEncode(<String, dynamic>{
        'auth_info': pd['auth_info'],
        'auth_meta': '',
        'task_id': taskId,
      }),
    );
    final authKey = _decode(authResp)['data']['auth_key'] as String;

    final bucket = '${pd['bucket'] ?? ''}';
    final objKey = '${pd['obj_key'] ?? ''}';
    final uploadUrl = '${pd['upload_url'] ?? ''}';
    final uploadId = '${pd['upload_id'] ?? ''}';
    final partSize = (pd['part_size'] as num?)?.toInt() ?? 20 * 1024 * 1024;
    final host = Uri.parse(uploadUrl).host;
    final baseUrl = uploadUrl.contains(bucket) || bucket.isEmpty
        ? uploadUrl
        : 'https://$bucket.$host';

    final parts = <String, String>{};
    var index = 1;
    for (var offset = 0; offset < data.length; offset += partSize) {
      final chunk = data.sublist(offset, (offset + partSize).clamp(0, data.length));
      final uri = Uri.parse('$baseUrl/$objKey').replace(queryParameters: <String, String>{
        'partNumber': '$index',
        'uploadId': uploadId,
      });
      final put = await http.put(
        uri,
        headers: <String, String>{
          'Authorization': authKey,
          'Content-Type': 'application/octet-stream',
          'Referer': 'https://pan.quark.cn/',
          'x-oss-date': _gmtNow(),
          'x-oss-user-agent': ossUa,
        },
        body: chunk,
      );
      if (put.statusCode >= 400) {
        throw CloudDriveException('分片 $index 上传失败 HTTP ${put.statusCode}');
      }
      final etag = put.headers['etag'] ?? put.headers['ETag'];
      if (etag == null || etag.isEmpty) throw CloudDriveException('分片 $index 缺少 ETag');
      parts['$index'] = etag;
      log?.call('  分片 $index/${(data.length / partSize).ceil()} 完成');
      index++;
    }

    final xml = StringBuffer('<CompleteMultipartUpload>');
    parts.forEach((number, etag) {
      xml.write('<Part><PartNumber>$number</PartNumber><ETag>$etag</ETag></Part>');
    });
    xml.write('</CompleteMultipartUpload>');
    final complete = await http.post(
      Uri.parse('$baseUrl/$objKey').replace(queryParameters: <String, String>{'uploadId': uploadId}),
      headers: <String, String>{
        'Content-MD5': base64Encode(md5.convert(utf8.encode(xml.toString())).bytes),
        'x-oss-callback': base64Encode(utf8.encode(jsonEncode(pd['callback'] ?? <String, dynamic>{}))),
        'x-oss-date': _gmtNow(),
        'x-oss-user-agent': ossUa,
        'Content-Type': 'application/xml',
      },
      body: xml.toString(),
    );
    if (complete.statusCode >= 400) {
      throw CloudDriveException('合并分片失败 HTTP ${complete.statusCode}');
    }

    await http.post(
      _uri('/file/upload/finish'),
      headers: <String, String>{..._headers, 'Content-Type': 'application/json'},
      body: jsonEncode(<String, dynamic>{'obj_key': objKey, 'task_id': taskId}),
    );
    log?.call('  上传完成');
    return UploadResult(
      remoteId: '${pd['fid'] ?? ''}',
      remoteLabel: p.basename(localPath),
      extra: <String, dynamic>{'obj_key': objKey},
    );
  }

  @override
  Future<ShareResult> share(UploadResult uploaded, {LogFn? log}) async {
    final password = (cfg['share_password'] ?? '').toString().trim();
    final createResp = await http.post(
      _uri('/share'),
      headers: <String, String>{..._headers, 'Content-Type': 'application/json'},
      body: jsonEncode(<String, dynamic>{
        'fid_list': <String>[uploaded.remoteId],
        'title': p.basename(uploaded.remoteLabel),
        'url_type': password.isEmpty ? 1 : 2,
        'expired_type': 1,
        if (password.isNotEmpty) 'passcode': password,
      }),
    );
    final taskId = '${_decode(createResp)['data']['task_id']}';
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 800));
      final taskResp = await http.get(
        _uri('/task', <String, String>{'task_id': taskId, 'retry_index': '0'}),
        headers: _headers,
      );
      final status = _decode(taskResp)['data']['status'];
      if (status == 2) break;
      if (status == 3 || status == 4) throw CloudDriveException('分享任务失败');
    }
    final pwdResp = await http.post(
      _uri('/share/password'),
      headers: <String, String>{..._headers, 'Content-Type': 'application/json'},
      body: jsonEncode(<String, dynamic>{'share_id': taskId}),
    );
    final d = _decode(pwdResp)['data'];
    return ShareResult(
      url: '${d['share_url'] ?? ''}',
      password: '${d['passcode'] ?? d['password'] ?? ''}',
    );
  }

  static String _gmtNow() {
    final now = DateTime.now().toUtc();
    const days = <String>['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const months = <String>['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    String two(int v) => v.toString().padLeft(2, '0');
    return '${days[now.weekday - 1]}, ${two(now.day)} ${months[now.month - 1]} ${now.year} '
        '${two(now.hour)}:${two(now.minute)}:${two(now.second)} GMT';
  }
}

/// Baidu Pan (OAuth device code + precreate/upload/create).
class BaiduDrive extends CloudDrive {
  BaiduDrive(super.cfg);

  static const String openApi = 'https://openapi.baidu.com';
  static const String pan = 'https://pan.baidu.com';
  static const String pcs = 'https://d.pcs.baidu.com';
  static const int chunk = 4 * 1024 * 1024;

  @override
  String get id => 'baidu';
  @override
  String get displayName => '百度网盘';
  @override
  String get authMode => 'oauth_code';
  @override
  String get notes => '在百度开放平台创建应用，填入 AppKey/SecretKey；授权码登录后自动续期';

  @override
  Map<String, dynamic> defaultConfig() => <String, dynamic>{
    'enabled': false,
    'app_key': '',
    'secret_key': '',
    'app_name': 'MCBE 本地化工',
    'remote_dir': '',
    'access_token': '',
    'refresh_token': '',
    'expires_at': 0,
  };

  @override
  List<ConfigField> configFields() => const <ConfigField>[
    ConfigField('app_key', 'AppKey', kind: 'password'),
    ConfigField('secret_key', 'SecretKey', kind: 'password'),
    ConfigField('app_name', '应用名称', hint: '需与开放平台一'),
    ConfigField('remote_dir', '上传子目', hint: '可留'),
  ];

  @override
  bool isAuthorized() => (cfg['access_token'] ?? '').toString().isNotEmpty;

  String get _appKey => (cfg['app_key'] ?? '').toString();

  @override
  String authorizeUrl() {
    if (_appKey.isEmpty) throw CloudDriveException('请先填写 AppKey');
    return '$openApi/oauth/2.0/authorize?response_type=code&client_id=$_appKey'
        '&redirect_uri=oob&scope=basic,netdisk&display=popup';
  }

  @override
  Future<void> exchangeCode(String code) async {
    final uri = Uri.parse('$openApi/oauth/2.0/token').replace(queryParameters: <String, String>{
      'grant_type': 'authorization_code',
      'code': code,
      'client_id': _appKey,
      'client_secret': (cfg['secret_key'] ?? '').toString(),
      'redirect_uri': 'oob',
    });
    final resp = await http.get(uri);
    final data = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    if (data['error'] != null) throw CloudDriveException('${data['error_description'] ?? data['error']}');
    cfg['access_token'] = data['access_token'];
    cfg['refresh_token'] = data['refresh_token'];
    cfg['expires_at'] = DateTime.now().millisecondsSinceEpoch + ((data['expires_in'] as num?)?.toInt() ?? 2592000) * 1000;
  }

  Future<String> _token() async {
    final expires = (cfg['expires_at'] as num?)?.toInt() ?? 0;
    final token = (cfg['access_token'] ?? '').toString();
    if (token.isNotEmpty && expires > DateTime.now().millisecondsSinceEpoch + 60000) {
      return token;
    }
    final refresh = (cfg['refresh_token'] ?? '').toString();
    if (refresh.isEmpty) throw CloudDriveException('未登录，请先完成授权');
    final uri = Uri.parse('$openApi/oauth/2.0/token').replace(queryParameters: <String, String>{
      'grant_type': 'refresh_token',
      'refresh_token': refresh,
      'client_id': _appKey,
      'client_secret': (cfg['secret_key'] ?? '').toString(),
    });
    final resp = await http.get(uri);
    final data = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    if (data['error'] != null) throw CloudDriveException('刷新 token 失败: ${data['error_description'] ?? data['error']}');
    cfg['access_token'] = data['access_token'];
    cfg['refresh_token'] = data['refresh_token'];
    cfg['expires_at'] = DateTime.now().millisecondsSinceEpoch + ((data['expires_in'] as num?)?.toInt() ?? 2592000) * 1000;
    return '${data['access_token']}';
  }

  @override
  Future<String> testConnection() async {
    final token = await _token();
    final uri = Uri.parse('$pan/rest/2.0/xpan/nas').replace(queryParameters: <String, String>{
      'method': 'uinfo',
      'access_token': token,
    });
    final resp = await http.get(uri);
    final data = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    if (data['errno'] != null && data['errno'] != 0) {
      throw CloudDriveException('${data['errmsg'] ?? '未知错误'}（${data['errno']}）');
    }
    return '${data['baidu_name'] ?? data['netdisk_name'] ?? '百度账号'}';
  }

  String _remotePath(String fileName) {
    final appName = (cfg['app_name'] ?? 'MCBE 本地化工').toString().trim();
    final sub = (cfg['remote_dir'] ?? '').toString().replaceAll(r'\', '/').split('/')
      ..removeWhere((e) => e.isEmpty || e == '.');
    final parts = <String>['apps', appName, ...sub, fileName];
    return '/${parts.join('/')}';
  }

  @override
  Future<UploadResult> upload(String localPath, {LogFn? log}) async {
    final token = await _token();
    final file = File(localPath);
    final data = file.readAsBytesSync();
    final remote = _remotePath(p.basename(localPath));
    final blocks = <String>[];
    for (var i = 0; i < data.length; i += chunk) {
      blocks.add(_md5Hex(data.sublist(i, (i + chunk).clamp(0, data.length))));
    }
    if (blocks.isEmpty) blocks.add(_md5Hex(const <int>[]));
    final sliceMd5 = _md5Hex(data.sublist(0, data.length.clamp(0, 256 * 1024)));

    final pre = await http.post(
      Uri.parse('$pan/rest/2.0/xpan/file').replace(queryParameters: <String, String>{'method': 'precreate'}),
      body: <String, String>{
        'path': remote,
        'size': '${data.length}',
        'isdir': '0',
        'autoinit': '1',
        'rtype': '3',
        'block_list': jsonEncode(blocks),
        'content-md5': _md5Hex(data),
        'slice-md5': sliceMd5,
        'access_token': token,
      },
    );
    final preData = jsonDecode(utf8.decode(pre.bodyBytes)) as Map<String, dynamic>;
    if (preData['errno'] != null && preData['errno'] != 0) {
      throw CloudDriveException('预上传失败: ${preData['errmsg'] ?? preData['errno']}');
    }
    final uploadId = '${preData['uploadid']}';
    final missing = (preData['block_list'] as List?)?.map((e) => int.tryParse('$e') ?? 0).toList() ?? <int>[];
    for (final index in missing) {
      final start = index * chunk;
      final chunkBytes = data.sublist(start, (start + chunk).clamp(0, data.length));
      final req = http.MultipartRequest(
        'POST',
        Uri.parse('$pcs/rest/2.0/pcs/superfile2').replace(queryParameters: <String, String>{
          'method': 'upload',
          'access_token': token,
          'type': 'tmpfile',
          'path': remote,
          'uploadid': uploadId,
          'partseq': '$index',
        }),
      )..files.add(http.MultipartFile.fromBytes('file', chunkBytes, filename: p.basename(localPath)));
      final resp = await req.send();
      if (resp.statusCode >= 400) throw CloudDriveException('分片 $index 上传失败');
      log?.call('  分片 $index 完成');
    }
    final create = await http.post(
      Uri.parse('$pan/rest/2.0/xpan/file').replace(queryParameters: <String, String>{'method': 'create'}),
      body: <String, String>{
        'path': remote,
        'size': '${data.length}',
        'isdir': '0',
        'rtype': '3',
        'uploadid': uploadId,
        'block_list': jsonEncode(blocks),
        'access_token': token,
      },
    );
    final createData = jsonDecode(utf8.decode(create.bodyBytes)) as Map<String, dynamic>;
    if (createData['errno'] != null && createData['errno'] != 0) {
      throw CloudDriveException('创建文件失败: ${createData['errmsg'] ?? createData['errno']}');
    }
    return UploadResult(remoteId: remote, remoteLabel: '我的应用数据/${remote.replaceFirst('/apps/', '')}');
  }
}

/// Registry + config defaults for every supported drive.
class CloudDrives {
  static List<CloudDrive> from(Map<String, dynamic> root) {
    final section = root['cloud_drives'];
    final map = section is Map<String, dynamic> ? section : <String, dynamic>{};
    if (section is! Map<String, dynamic>) root['cloud_drives'] = map;
    final drives = <CloudDrive>[];
    for (final factory in <CloudDrive Function(Map<String, dynamic>)>[
      QuarkDrive.new,
      BaiduDrive.new,
    ]) {
      final probe = factory(<String, dynamic>{});
      final existing = map[probe.id];
      final cfg = existing is Map<String, dynamic> ? existing : <String, dynamic>{};
      if (existing is! Map<String, dynamic>) map[probe.id] = cfg;
      for (final e in probe.defaultConfig().entries) {
        if (!cfg.containsKey(e.key)) cfg[e.key] = e.value;
      }
      drives.add(factory(cfg));
    }
    return drives;
  }

  static Uint8List emptyBytes() => Uint8List(0);
}


