import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_tv_app/app/constant.dart';
import 'package:simple_live_tv_app/app/sites.dart';
import 'package:simple_live_tv_app/models/account/bilibili_user_info_page.dart';
import 'package:simple_live_tv_app/requests/http_client.dart';
import 'package:simple_live_tv_app/services/local_storage_service.dart';

class BiliBiliAccountService extends GetxService {
  static BiliBiliAccountService get instance =>
      Get.find<BiliBiliAccountService>();

  var logined = false.obs;

  var cookie = "";
  var uid = 0;
  int _accountRevision = 0;
  int _userInfoRequest = 0;
  var name = "未登录".obs;

  @override
  void onInit() {
    cookie = LocalStorageService.instance.getValue(
      LocalStorageService.kBilibiliCookie,
      "",
    );
    logined.value = cookie.isNotEmpty;
    setSite();
    loadUserInfo();
    super.onInit();
  }

  Future<void> loadUserInfo() async {
    if (cookie.isEmpty) {
      return;
    }
    final revision = _accountRevision;
    final request = ++_userInfoRequest;
    final requestedCookie = cookie;
    bool current() =>
        revision == _accountRevision &&
        request == _userInfoRequest &&
        cookie == requestedCookie;
    try {
      var result = await HttpClient.instance.getJson(
        "https://api.bilibili.com/x/member/web/account",
        header: {"Cookie": requestedCookie},
      );
      if (!current()) return;
      if (result["code"] == 0) {
        var info = BiliBiliUserInfoModel.fromJson(result["data"]);
        name.value = info.uname ?? "未登录";
        uid = info.mid ?? 0;
        setSite();
      } else {
        SmartDialog.showToast("哔哩哔哩登录已失效，请重新登录");
        await logout();
      }
    } catch (e) {
      if (!current()) return;
      SmartDialog.showToast("获取哔哩哔哩用户信息失败，可前往账号管理重试");
    }
  }

  void setSite() {
    var site = (Sites.allSites[Constant.kBiliBili]!.liveSite as BiliBiliSite);
    site.userId = uid;
    site.cookie = cookie;
  }

  Future<void> setCookie(String cookie) async {
    // Invalidate pending account checks before waiting for the vault. Only a
    // successful write changes the in-memory session and provider credentials.
    _accountRevision++;
    await LocalStorageService.instance.setValue(
      LocalStorageService.kBilibiliCookie,
      cookie,
    );
    _accountRevision++;
    this.cookie = cookie;
    uid = 0;
    name.value = "未登录";
    logined.value = cookie.isNotEmpty;
    setSite();
  }

  Future<void> logout() async {
    await setCookie('');
  }

  @override
  void onClose() {
    _accountRevision++;
    super.onClose();
  }
}
