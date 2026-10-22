import 'dart:async';
import 'package:simple_live_core/simple_live_core.dart';
import 'dart:io';

import 'package:flutter/material.dart';

import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/controller/base_controller.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/requests/sync_client_request.dart';
import 'package:simple_live_app/routes/app_navigation.dart';
import 'package:simple_live_app/routes/route_path.dart';

import 'package:simple_live_app/services/sync_service.dart';

class LocalSyncController extends BaseController {
  final String? address;
  LocalSyncController(this.address);

  @override
  void onInit() {
    unawaited(_start());
    super.onInit();
  }

  bool _closing = false;
  Future<void> _start() async {
    await SyncService.instance.startSession();
    if (_closing) return;
    SyncService.instance.refreshClients();
    initConnect();
  }

  @override
  void onClose() {
    _closing = true;
    addressController.dispose();
    unawaited(SyncService.instance.stopSession());
    super.onClose();
  }

  void initConnect() {
    if (address != null && address!.isNotEmpty) {
      addressController.text = address!;
      connect();
    }
  }

  TextEditingController addressController = TextEditingController();
  SyncClientRequest request = SyncClientRequest();

  void connect() async {
    var address = addressController.text;
    if (address.isEmpty) {
      SmartDialog.showToast("请输入地址");
      return;
    }
    final uri = Uri.tryParse(
      address.contains('://') ? address : 'simplelive://$address',
    );
    if (uri == null || uri.host.isEmpty) {
      SmartDialog.showToast('地址无效');
      return;
    }
    address = uri.host;

    var client = SyncClinet(
      id: 'manual',
      address: address,
      port: SyncService.httpPort,
      name: "手动输入",
      type: Platform.operatingSystem,
    );
    connectClient(client, pairingKey: uri.fragment);
  }

  void connectClient(SyncClinet client, {String? pairingKey}) async {
    try {
      pairingKey ??= '';
      if (pairingKey.isEmpty) {
        pairingKey = await Utils.showEditTextDialog(
          '',
          title: '配对码',
          hintText: '输入接收端显示的完整配对码，或返回扫码',
        );
      }
      if (_closing || pairingKey == null || pairingKey.isEmpty) return;
      client.cipher = SyncCipher(pairingKey);

      SmartDialog.showLoading(msg: "连接中...");
      var info = await request.getClientInfo(client);
      if (!_closing) AppNavigator.toSyncDevice(client, info);
    } catch (e) {
      SmartDialog.showToast("连接失败:$e");
    } finally {
      SmartDialog.dismiss();
    }
  }

  void toScanQr() async {
    var result = await Get.toNamed(RoutePath.kSyncScan);
    if (result == null || result.isEmpty) {
      return;
    }
    var addressList = (result as String).split(";");
    if (addressList.length >= 2) {
      //弹窗选择
      showPickerAddress(addressList);
    } else {
      addressController.text = result;
      //connect();
    }
  }

  void showPickerAddress(List<String> addressList) {
    SmartDialog.showToast("扫描到多个地址，请选择一个连接");
    Utils.showBottomSheet(
      title: '请选择地址',
      child: ListView.builder(
        itemBuilder: (_, i) {
          return ListTile(
            title: Text(addressList[i]),
            onTap: () {
              Get.back();
              addressController.text = addressList[i];
              // connect();
            },
          );
        },
        itemCount: addressList.length,
      ),
    );
  }

  void showInfo() {
    Utils.showBottomSheet(
      title: "本机信息",
      child: Column(
        children: [
          Visibility(
            visible: SyncService.instance.httpRunning.value,
            child: GestureDetector(
              onTap: () {
                Get.back();
              },
              child: QrImageView(
                data: SyncService.instance.pairingAddress,
                version: QrVersions.auto,
                backgroundColor: Colors.white,
                padding: AppStyle.edgeInsetsA12,
                size: 200,
              ),
            ),
          ),
          AppStyle.vGap12,
          SelectableText(
            SyncService.instance.pairingKey,
            textAlign: TextAlign.center,
          ),
          AppStyle.vGap24,
          Visibility(
            visible: SyncService.instance.httpRunning.value,
            child: Text(
              '服务已启动：${SyncService.instance.ipAddress.value.split(';').map((e) => '$e:${SyncService.httpPort}').join('；')}',
              textAlign: TextAlign.center,
            ),
          ),
          Visibility(
            visible: !SyncService.instance.httpRunning.value,
            child: Text(
              'HTTP服务未启动：${SyncService.instance.httpErrorMsg}，请尝试重启应用',
              textAlign: TextAlign.center,
            ),
          ),
          AppStyle.vGap12,
          Visibility(
            visible: SyncService.instance.httpRunning.value,
            child: const Text(
              "请用新版客户端扫码或输入配对码，并在本机确认\n会话有效期10分钟，退出此页面即关闭",
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }
}
