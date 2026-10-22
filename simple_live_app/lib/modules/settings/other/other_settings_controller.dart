import 'dart:convert';
import 'dart:io';
import 'package:simple_live_core/simple_live_core.dart'
    show validateShieldRules;
import 'package:flutter/foundation.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/controller/base_controller.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:path/path.dart' as p;
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/services/local_storage_service.dart';

class OtherSettingsController extends BaseController {
  RxList<LogFileModel> logFiles = <LogFileModel>[].obs;

  var videoOutputDrivers = {
    "gpu": "gpu",
    "gpu-next": "gpu-next",
    "xv": "xv (X11 only)",
    "x11": "x11 (X11 only)",
    "vdpau": "vdpau (X11 only)",
    "direct3d": "direct3d (Windows only)",
    "sdl": "sdl",
    "dmabuf-wayland": "dmabuf-wayland",
    "vaapi": "vaapi",
    "null": "null",
    "libmpv": "libmpv",
    "mediacodec_embed": "mediacodec_embed (Android only)",
  };

  var audioOutputDrivers = {
    "null": "null (No audio output)",
    "pulse": "pulse (Linux, uses PulseAudio)",
    "pipewire": "pipewire (Linux, via Pulse compatibility or native)",
    "alsa": "alsa (Linux only)",
    "oss": "oss (Linux only)",
    "jack": "jack (Linux/macOS, low-latency audio)",
    "directsound": "directsound (Windows only)",
    "wasapi": "wasapi (Windows only)",
    "winmm": "winmm (Windows only, legacy API)",
    "audiounit": "audiounit (iOS only)",
    "coreaudio": "coreaudio (macOS only)",
    "opensles": "opensles (Android only)",
    "audiotrack": "audiotrack (Android only)",
    "aaudio": "aaudio (Android only)",
    "pcm": "pcm (Cross-platform)",
    "sdl": "sdl (Cross-platform, via SDL library)",
    "openal": "openal (Cross-platform, OpenAL backend)",
    "libao": "libao (Cross-platform, uses libao library)",
    "auto": "auto (Not available)",
  };

  var hardwareDecoder = {
    "no": "no",
    "auto": "auto",
    "auto-safe": "auto-safe",
    "yes": "yes",
    "auto-copy": "auto-copy",
    "d3d11va": "d3d11va",
    "d3d11va-copy": "d3d11va-copy",
    "videotoolbox": "videotoolbox",
    "videotoolbox-copy": "videotoolbox-copy",
    "vaapi": "vaapi",
    "vaapi-copy": "vaapi-copy",
    "nvdec": "nvdec",
    "nvdec-copy": "nvdec-copy",
    "drm": "drm",
    "drm-copy": "drm-copy",
    "vulkan": "vulkan",
    "vulkan-copy": "vulkan-copy",
    "dxva2": "dxva2",
    "dxva2-copy": "dxva2-copy",
    "vdpau": "vdpau",
    "vdpau-copy": "vdpau-copy",
    "mediacodec": "mediacodec",
    "mediacodec-copy": "mediacodec-copy",
    "cuda": "cuda",
    "cuda-copy": "cuda-copy",
    "crystalhd": "crystalhd",
    "rkmpp": "rkmpp",
  };

  @override
  void onInit() {
    loadLogFiles();
    super.onInit();
  }

  void setLogEnable(e) {
    AppSettingsController.instance.setLogEnable(e);
    if (e) {
      Log.initWriter();
      Future.delayed(const Duration(milliseconds: 100), () {
        loadLogFiles();
      });
    } else {
      Log.disposeWriter();
    }
  }

  void loadLogFiles() async {
    var supportDir = await getApplicationSupportDirectory();
    var logDir = Directory("${supportDir.path}/log");
    if (!await logDir.exists()) {
      await logDir.create();
    }
    logFiles.clear();
    await logDir.list().forEach((element) {
      var file = element as File;
      var name = p.basename(file.path);
      var time = file.lastModifiedSync();
      var size = file.lengthSync();
      logFiles.add(LogFileModel(name, file.path, time, size));
    });
    //logFiles 名称倒序
    logFiles.sort((a, b) => b.time.compareTo(a.time));
  }

  void cleanLog() async {
    if (AppSettingsController.instance.logEnable.value) {
      SmartDialog.showToast("请先关闭日志记录");
      return;
    }

    var supportDir = await getApplicationSupportDirectory();
    var logDir = Directory("${supportDir.path}/log");
    if (await logDir.exists()) {
      await logDir.delete(recursive: true);
    }
    loadLogFiles();
  }

  void shareLogFile(LogFileModel item) {
    SharePlus.instance.share(ShareParams(files: [XFile(item.path)]));
  }

  void saveLogFile(LogFileModel item) async {
    var filePath = await FilePicker.platform.saveFile(
      allowedExtensions: ['log'],
      type: FileType.custom,
      fileName: item.name,
      bytes: Uint8List(0),
    );
    if (filePath != null) {
      var file = File(item.path);
      await file.copy(filePath);
      SmartDialog.showToast("保存成功");
    }
  }

  bool _configBusy = false;

  Map<String, dynamic> configurationSnapshot() => {
    'type': 'simple_live',
    'platform': Platform.operatingSystem,
    'version': 2,
    'time': DateTime.now().millisecondsSinceEpoch,
    'config': LocalStorageService.instance.exportSettings(),
    'shield': LocalStorageService.instance.shieldBox.values.toList(),
  };

  static ({Map<String, dynamic> settings, List<String> rules})
  validateConfiguration(dynamic data) {
    if (data is! Map ||
        data['type'] != 'simple_live' ||
        !const [1, 2].contains(data['version']) ||
        data['platform'] is! String ||
        data['config'] is! Map ||
        (data['shield'] is! List && data['shield'] is! Map)) {
      throw const FormatException('不支持的配置文件');
    }
    // Validate both sections before either enters a persistent write queue.
    final settings = LocalStorageService.validateSettings(data['config']);
    final rawRules = data['shield'];
    final rules = validateShieldRules(
      rawRules is Map ? rawRules.values : rawRules as List,
    );
    return (settings: settings, rules: rules);
  }

  Future<({List<String> succeeded, List<String> failed})> restoreConfiguration(
    dynamic data,
  ) async => _applyConfiguration(validateConfiguration(data));

  Future<({List<String> succeeded, List<String> failed})> _applyConfiguration(
    ({Map<String, dynamic> settings, List<String> rules}) input,
  ) async {
    final succeeded = <String>[];
    final failed = <String>[];
    try {
      await LocalStorageService.instance.restoreSettings(
        input.settings,
        replace: true,
      );
      AppSettingsController.instance.reloadSettings();
      succeeded.add('常规偏好');
    } catch (_, stack) {
      failed.add('常规偏好');
      Log.e('恢复常规偏好失败', stack);
    }
    try {
      await AppSettingsController.instance.importShieldRules(
        input.rules,
        replace: true,
      );
      succeeded.add('屏蔽词');
    } catch (_, stack) {
      failed.add('屏蔽词');
      Log.e('恢复屏蔽词失败', stack);
    }
    return (succeeded: succeeded, failed: failed);
  }

  void _showConfigResult(
    String action,
    ({List<String> succeeded, List<String> failed}) result,
  ) {
    if (result.failed.isEmpty) {
      SmartDialog.showToast('$action成功，已应用');
    } else if (result.succeeded.isEmpty) {
      SmartDialog.showToast('$action未完成，请重试');
    } else {
      SmartDialog.showToast(
        '已完成：${result.succeeded.join('、')}；'
        '未完成：${result.failed.join('、')}，请重试',
      );
    }
  }

  Future<void> exportConfig() async {
    if (_configBusy) return;
    _configBusy = true;
    try {
      final bytes = Uint8List.fromList(
        utf8.encode(jsonEncode(configurationSnapshot())),
      );
      final inlineSave = Platform.isAndroid || Platform.isIOS || kIsWeb;
      final path = await FilePicker.platform.saveFile(
        allowedExtensions: ['json'],
        type: FileType.custom,
        fileName: 'simple_live_config.json',
        bytes: inlineSave ? bytes : null,
      );
      if (path == null && !kIsWeb) return;
      if (!inlineSave && path != null) await File(path).writeAsBytes(bytes);
      SmartDialog.showToast('保存成功');
    } catch (_, stack) {
      Log.e('导出配置失败', stack);
      SmartDialog.showToast('导出失败，请检查保存位置后重试');
    } finally {
      _configBusy = false;
    }
  }

  Future<void> importConfig() async {
    if (_configBusy) return;
    _configBusy = true;
    try {
      final selection = await FilePicker.platform.pickFiles(
        allowedExtensions: ['json'],
        type: FileType.custom,
      );
      if (selection == null) return;
      final file = File(selection.files.single.path!);
      if (await file.length() > 8 * 1024 * 1024) {
        throw const FormatException('配置文件过大');
      }
      final data = jsonDecode(await file.readAsString());
      final input = validateConfiguration(data);
      if (data['platform'] != Platform.operatingSystem &&
          !await Utils.showAlertDialog('配置文件的平台不同，是否继续导入？', title: '平台不匹配')) {
        return;
      }
      _showConfigResult('导入', await _applyConfiguration(input));
    } catch (_, stack) {
      Log.e('导入配置失败', stack);
      SmartDialog.showToast('导入失败，请检查配置文件后重试');
    } finally {
      _configBusy = false;
    }
  }

  Future<void> resetDefaultConfig() async {
    if (_configBusy) return;
    _configBusy = true;
    try {
      if (!await Utils.showAlertDialog('是否重置常规偏好和屏蔽词？账号、同步配置和日志开关会保留。')) {
        return;
      }
      _showConfigResult(
        '重置',
        await _applyConfiguration((settings: {}, rules: [])),
      );
    } catch (_, stack) {
      Log.e('重置配置失败', stack);
      SmartDialog.showToast('重置未完成，请重试');
    } finally {
      _configBusy = false;
    }
  }
}

class LogFileModel {
  late String name;
  late String path;
  late DateTime time;
  late int size;
  LogFileModel(this.name, this.path, this.time, this.size);
}
