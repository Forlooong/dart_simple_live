import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_tv_app/app/app_error.dart';

import 'package:flutter_easyrefresh/easy_refresh.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';

class BaseController extends GetxController {
  /// 加载中，更新页面
  var pageLoadding = false.obs;

  /// 加载中
  var loadding = false.obs;

  /// 空白页面
  var pageEmpty = false.obs;

  /// 页面错误
  var pageError = false.obs;

  /// 未登录
  var notLogin = false.obs;

  /// 错误信息
  var errorMsg = "".obs;

  /// 显示错误
  /// * [msg] 错误信息
  /// * [showPageError] 显示页面错误
  /// * 只在第一页加载错误时showPageError=true，后续页加载错误时使用Toast弹出通知
  void handleError(Object exception, {bool showPageError = false}) {
    var msg = exceptionToString(exception);
    if (exception is AppError && exception.notLogin) {
      notLogin.value = true;
      pageError.value = false;
      return;
    }
    if (showPageError) {
      pageError.value = true;
      errorMsg.value = msg;
    } else {
      SmartDialog.showToast(exceptionToString(msg));
    }
  }

  String exceptionToString(Object exception) {
    if (exception is AppError) {
      return exception.toString();
    }
    return exception.toString().replaceAll("Exception:", "");
  }

  void onLogin() {}
  void onLogout() {}
}

class BasePageController<T> extends BaseController {
  final ScrollController scrollController = ScrollController();
  final EasyRefreshController easyRefreshController = EasyRefreshController();
  int currentPage = 1;
  int count = 0;
  int maxPage = 0;
  int pageSize = 24;
  var canLoadMore = false.obs;
  var list = <T>[].obs;

  Object? _activePage;
  Duration? get pageTimeout => null;
  bool _exhausted = false;
  int _pageGeneration = 0;
  int get pageGeneration => _pageGeneration;

  Future<void> refreshData() async {
    _pageGeneration++;
    if (_activePage case RequestContext context) context.cancel();
    _activePage = null;
    _exhausted = false;
    currentPage = 1;
    canLoadMore.value = false;
    list.clear();
    await loadData();
  }

  Future<void> loadData({bool retry = false}) async {
    if (isClosed || _activePage != null || (_exhausted && !retry)) return;
    final timeout = pageTimeout;
    final context = timeout == null ? null : RequestContext(timeout: timeout);
    final request = context ?? Object();
    final page = currentPage;
    _activePage = request;
    try {
      loadding.value = true;
      pageError.value = false;
      pageEmpty.value = false;
      notLogin.value = false;
      pageLoadding.value = page == 1;
      final result = await (context == null
          ? getPage(page, pageSize, retry: retry)
          : context.run(() => getPage(page, pageSize, retry: retry)));
      if (!identical(_activePage, request)) return;
      if (result.items.isNotEmpty || result.hasMore) currentPage = page + 1;
      _exhausted = !result.hasMore;
      canLoadMore.value = result.hasMore;
      list.addAll(result.items);
      pageEmpty.value = list.isEmpty && !result.hasMore;
    } catch (error) {
      if (!identical(_activePage, request)) return;
      handleError(error, showPageError: list.isEmpty);
    } finally {
      if (identical(_activePage, request)) {
        _activePage = null;
        loadding.value = false;
        pageLoadding.value = false;
      }
    }
  }

  Future<({List<T> items, bool hasMore})> getPage(
    int page,
    int pageSize, {
    bool retry = false,
  }) async {
    final items = await getData(page, pageSize);
    return (items: items, hasMore: items.isNotEmpty);
  }

  @override
  void onClose() {
    _pageGeneration++;
    if (_activePage case RequestContext context) context.cancel();
    _activePage = null;
    super.onClose();
  }

  Future<List<T>> getData(int page, int pageSize) async {
    return [];
  }

  void scrollToTopOrRefresh() {
    if (scrollController.offset > 0) {
      scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 200),
        curve: Curves.linear,
      );
    } else {
      easyRefreshController.callRefresh();
    }
  }
}
