import 'package:flutter/widgets.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/controller/base_controller.dart';

class DanmuShieldController extends BaseController {
  final TextEditingController textEditingController = TextEditingController();
  final AppSettingsController settingsController =
      Get.find<AppSettingsController>();
  Future<void> add() async {
    if (textEditingController.text.isEmpty) {
      SmartDialog.showToast("请输入关键词");
      return;
    }

    final rule = textEditingController.text.trim();
    if (await settingsController.addValidatedShieldRule(rule) &&
        textEditingController.text.trim() == rule) {
      textEditingController.text = "";
    }
  }

  void remove(String item) {
    settingsController.removeShieldList(item);
  }
}
