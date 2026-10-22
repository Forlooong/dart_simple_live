import 'dart:async';
import 'package:simple_live_core/simple_live_core.dart';
import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/services/bilibili_account_service.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:udp/udp.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf_router/shelf_router.dart';
import 'package:uuid/uuid.dart';

class SyncService extends GetxService {
  static SyncService get instance => Get.find<SyncService>();

  UDP? udp;
  RxList<SyncClinet> scanClients = <SyncClinet>[].obs;
  static const int udpPort = 23235;
  static const int httpPort = 23234;
  DeviceInfoPlugin deviceInfo = DeviceInfoPlugin();
  NetworkInfo networkInfo = NetworkInfo();
  late final SecureSyncServer _session = SecureSyncServer(
    approve: (peer) =>
        Utils.showAlertDialog('允许 $peer 在本次会话中向本机同步数据？', title: '确认配对'),
    handle: _handleSecureRequest,
    onStopped: () {
      ++_sessionGeneration;
      httpRunning.value = false;
      udp?.close();
      udp = null;
    },
  );
  int _sessionGeneration = 0;
  bool _closed = false;
  String get pairingKey => _session.pairingKey;
  String get pairingAddress => ipAddress.value
      .split(';')
      .map((ip) => 'simplelive://$ip:$httpPort#${_session.pairingKey}')
      .join(';');

  Future<void> startSession() async {
    if (_closed) return;
    final generation = _sessionGeneration;
    try {
      await _session.start();
      if (_closed || generation != _sessionGeneration || !_session.running) {
        return;
      }
      httpRunning.value = true;
      httpErrorMsg.value = '';
      ipAddress.value = await getLocalIP();
      if (_closed || generation != _sessionGeneration || !_session.running) {
        return;
      }
      await listenUDP();
    } catch (_) {
      httpErrorMsg.value = '无法启动同步会话，请退出页面后重试';
      await stopSession();
    }
  }

  Future<void> stopSession() {
    ++_sessionGeneration;
    return _session.stop();
  }

  Future<Object?> _handleSecureRequest(Map<String, dynamic> data) async {
    final path = data['path'];
    const routes = {
      '/info',
      '/sync/follow',
      '/sync/tag',
      '/sync/history',
      '/sync/blocked_word',
      '/sync/account/bilibili',
    };
    if (!routes.contains(path) || data['overlay'] is! bool) {
      throw const FormatException('同步格式无效');
    }
    final body = data['body'];
    if (path != '/info' &&
        path != '/sync/account/bilibili' &&
        path != '/sync/follow' &&
        (body is! List || body.length > 10000)) {
      throw const FormatException('同步列表无效');
    }
    final router = Router();
    router.get('/info', _infoRequest);
    router.post('/sync/follow', _syncFollowUserReuqest);
    router.post('/sync/tag', _syncFollowUserTagRequest);
    router.post('/sync/history', _syncHistoryReuqest);
    router.post('/sync/blocked_word', _syncBlockedWordReuqest);
    router.post('/sync/account/bilibili', _syncBiliAccountReuqest);
    final response = await router(
      shelf.Request(
        path == '/info' ? 'GET' : 'POST',
        Uri.parse(
          'http://localhost$path?overlay=${data['overlay'] == true ? 1 : 0}',
        ),
        body: jsonEncode(body),
      ),
    );
    return jsonDecode(await response.readAsString());
  }

  var ipAddress = "".obs;
  var httpRunning = false.obs;
  var httpErrorMsg = "".obs;

  var deviceId = "";

  @override
  void onInit() {
    Log.d('TVService init');
    deviceId = (const Uuid().v4()).split('-').first;
    super.onInit();
  }

  /// 监听其他端UDP广播的回复
  Future<void> listenUDP() async {
    if (udp != null || !_session.running) return;
    final generation = _sessionGeneration;
    final socket = await UDP.bind(Endpoint.any(port: const Port(udpPort)));
    if (generation != _sessionGeneration || !_session.running) {
      socket.close();
      return;
    }
    udp = socket;
    udp!.asStream().listen(listenUdp);
  }

  void listenUdp(Datagram? datagram) {
    if (datagram == null || datagram.data.length > 4096) return;
    final str = String.fromCharCodes(datagram.data);
    if (str.startsWith('{') && str.endsWith('}')) {
      final data = _discoveryData(str);
      if (data == null) return;
      //如果是自己的广播，就不处理
      if (data['id'] == deviceId) {
        return;
      }
      //处理Hello的广播
      if (data["type"] == "hello") {
        //如果http服务已经启动，就回复自己的信息
        if (httpRunning.value) {
          sendInfo();
        }
        return;
      }
      // 处理其他端的广播
      // 地址直接从datagram中获取，能收到回复说明地址是可以连通的
      var address = datagram.address.address;
      //检查是否已经存在
      var index = scanClients.indexWhere(
        (element) => element.address == address,
      );
      if (index == -1) {
        scanClients.add(
          SyncClinet(
            id: data['id'],
            name: data['name'],
            address: address,
            port: httpPort,
            type: data['type'],
          ),
        );
      }
    }
  }

  /// 发送UDP广播至其他端
  void sendHello() async {
    final socket = udp;
    if (socket == null || !_session.running) return;
    await socket.send(
      json.encode({"id": deviceId, "protocol": 2, "type": "hello"}).codeUnits,
      Endpoint.broadcast(port: const Port(udpPort)),
    );
    Log.i("send udp: hello");
  }

  /// UDP广播自身信息
  void sendInfo() async {
    //var ip = await getLocalIP();

    var name = await getDeviceName();

    var data = {
      "id": deviceId,
      "protocol": 2,
      "type": Platform.operatingSystem,
      //'version': Utils.packageInfo.version,
      "name": name,
      //"address": ip,
      //"port": httpPort,
    };

    final socket = udp;
    if (socket == null || !_session.running) return;
    await socket.send(
      json.encode(data).codeUnits,
      Endpoint.broadcast(port: const Port(udpPort)),
    );
    Log.i("send udp info: $data");
  }

  Future<String> getDeviceName() async {
    var name = "SimpleLive-${Platform.operatingSystem}";
    if (Platform.isAndroid) {
      var info = await deviceInfo.androidInfo;
      name = info.model;
    } else if (Platform.isIOS) {
      var info = await deviceInfo.iosInfo;
      name = info.name;
    } else if (Platform.isMacOS) {
      var info = await deviceInfo.macOsInfo;
      name = info.computerName;
    } else if (Platform.isLinux) {
      var info = await deviceInfo.linuxInfo;
      name = info.name;
    } else if (Platform.isWindows) {
      var info = await deviceInfo.windowsInfo;
      name = info.userName;
    }
    return name;
  }

  void refreshClients() {
    scanClients.clear();
    sendHello();
  }

  /// 读取本地IP
  /// - 如果是wifi，直接获取wifi的IP
  /// - 如果是有线，获取所有的IP，找到全部的IP
  Future<String> getLocalIP() async {
    String? ip = "";
    try {
      ip = await networkInfo.getWifiIP();
    } catch (e) {
      Log.logPrint(e);
    }
    try {
      if (ip == null || ip.isEmpty) {
        var interfaces = await NetworkInterface.list();
        var ipList = <String>[];
        for (var interface in interfaces) {
          for (var addr in interface.addresses) {
            if (addr.type.name == 'IPv4' &&
                !addr.address.startsWith('127') &&
                !addr.isMulticast &&
                !addr.isLoopback) {
              ipList.add(addr.address);
              break;
            }
          }
        }
        ip = ipList.join(';');
      }
    } catch (e) {
      Log.logPrint(e);
    }
    return ip ?? "";
  }

  Map<String, dynamic>? _discoveryData(String source) {
    try {
      final data = jsonDecode(source);
      if (data is! Map<String, dynamic> ||
          data['protocol'] != 2 ||
          data['id'] is! String ||
          data['type'] is! String ||
          (data['type'] != 'hello' && data['name'] is! String)) {
        return null;
      }
      return data;
    } catch (_) {
      return null;
    }
  }

  /// 发送自己的信息
  Future<shelf.Response> _infoRequest(shelf.Request request) async {
    var name = await getDeviceName();
    return toJsonResponse({
      "id": deviceId,
      "protocol": 2,
      'type': Platform.operatingSystem,
      'name': name,
      'version': Utils.packageInfo.version,
      'address': ipAddress.value,
      'port': httpPort,
    });
  }

  /// 同步关注用户列表
  Future<shelf.Response> _syncFollowUserReuqest(shelf.Request request) async {
    try {
      var overlay = int.parse(
        request.requestedUri.queryParameters['overlay'] ?? '0',
      );

      var body = await request.readAsString();
      var jsonBody = json.decode(body);
      if (jsonBody is! Map ||
          jsonBody['follows'] is! List ||
          (jsonBody['follows'] as List).length > 10000 ||
          jsonBody['tags'] is! List ||
          (jsonBody['tags'] as List).length > 10000) {
        throw const FormatException('关注备份格式无效');
      }
      await DBService.instance.importSnapshot(
        follows: jsonBody['follows'],
        tags: jsonBody['tags'],
        replace: overlay == 1,
      );

      SmartDialog.showToast('已同步关注用户列表');
      EventBus.instance.emit(Constant.kUpdateFollow, 0);
      return toJsonResponse({'status': true, 'message': 'success'});
    } catch (e) {
      return toJsonResponse({
        'status': false,
        'message': '同步失败，原数据已保留；请检查数据格式后重试',
      });
    }
  }

  /// 同步标签列表
  Future<shelf.Response> _syncFollowUserTagRequest(
    shelf.Request request,
  ) async {
    try {
      var overlay = int.parse(
        request.requestedUri.queryParameters['overlay'] ?? '0',
      );

      var body = await request.readAsString();
      var jsonBody = json.decode(body);
      await DBService.instance.importTags(jsonBody, replace: overlay == 1);

      SmartDialog.showToast('已同步标签列表');
      EventBus.instance.emit(Constant.kUpdateFollow, 0);
      return toJsonResponse({'status': true, 'message': 'success'});
    } catch (e) {
      return toJsonResponse({
        'status': false,
        'message': '同步失败，原数据已保留；请检查数据格式后重试',
      });
    }
  }

  /// 同步观看记录
  Future<shelf.Response> _syncHistoryReuqest(shelf.Request request) async {
    try {
      var overlay = int.parse(
        request.requestedUri.queryParameters['overlay'] ?? '0',
      );
      var body = await request.readAsString();
      var jsonBody = json.decode(body);
      await DBService.instance.importHistories(jsonBody, replace: overlay == 1);

      SmartDialog.showToast('已同步观看记录');
      EventBus.instance.emit(Constant.kUpdateHistory, 0);
      return toJsonResponse({'status': true, 'message': 'success'});
    } catch (e) {
      return toJsonResponse({
        'status': false,
        'message': '同步失败，原数据已保留；请检查数据格式后重试',
      });
    }
  }

  /// 同步弹幕屏蔽词
  Future<shelf.Response> _syncBlockedWordReuqest(shelf.Request request) async {
    try {
      var overlay = int.parse(
        request.requestedUri.queryParameters['overlay'] ?? '0',
      );
      var body = await request.readAsString();
      var jsonBody = json.decode(body);
      await AppSettingsController.instance.importShieldRules(
        jsonBody,
        replace: overlay == 1,
      );
      SmartDialog.showToast('已同步弹幕屏蔽词');
      return toJsonResponse({'status': true, 'message': 'success'});
    } catch (e) {
      return toJsonResponse({
        'status': false,
        'message': '同步失败，原数据已保留；请检查数据格式后重试',
      });
    }
  }

  /// 同步哔哩哔哩账号
  Future<shelf.Response> _syncBiliAccountReuqest(shelf.Request request) async {
    try {
      var body = await request.readAsString();
      var jsonBody = json.decode(body);
      final cookie = jsonBody['cookie'];
      if (cookie is! String || cookie.length > 65536) {
        throw const FormatException('账号格式无效');
      }
      await BiliBiliAccountService.instance.setCookie(cookie);
      BiliBiliAccountService.instance.loadUserInfo();
      SmartDialog.showToast('已同步哔哩哔哩账号');
      return toJsonResponse({'status': true, 'message': 'success'});
    } catch (e) {
      return toJsonResponse({
        'status': false,
        'message': '同步失败，原数据已保留；请检查数据格式后重试',
      });
    }
  }

  shelf.Response toJsonResponse(Map<String, dynamic> data) {
    return shelf.Response.ok(
      json.encode(data),
      headers: {'Content-Type': 'application/json'},
      encoding: Encoding.getByName('utf-8'),
    );
  }

  @override
  void onClose() {
    Log.d('SyncService close');
    _closed = true;
    unawaited(stopSession());
    super.onClose();
  }
}

class SyncClinet {
  SyncCipher? cipher;
  final String id;
  final String name;
  final String address;
  final int port;
  final String type;
  SyncClinet({
    required this.id,
    required this.name,
    required this.address,
    required this.port,
    required this.type,
  });
}
