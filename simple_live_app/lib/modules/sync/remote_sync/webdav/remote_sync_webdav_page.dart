import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/modules/sync/remote_sync/webdav/remote_sync_webdav_controller.dart';
import 'package:simple_live_app/routes/route_path.dart';
import 'package:simple_live_app/widgets/settings/settings_card.dart';

class RemoteSyncWebDAVPage extends GetView<RemoteSyncWebDAVController> {
  const RemoteSyncWebDAVPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("WebDAV同步")),
      body: ListView(
        padding: AppStyle.edgeInsetsA12,
        children: [
          SettingsCard(
            child: Obx(
              () => Column(
                children: controller.notLogin.value
                    ? [
                        ListTile(
                          title: const Text("点击登录"),
                          leading: const Icon(Icons.login),
                          subtitle: const Text("同步关注、标签、观看历史、屏蔽词和设置"),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () {
                            Get.toNamed(RoutePath.kRemoteSyncWebDavConfig);
                          },
                        ),
                      ]
                    : [
                        ListTile(
                          title: const Text("已登录"),
                          leading: const Icon(Icons.cloud_circle_outlined),
                          subtitle: Text(controller.user.value),
                          trailing: const Icon(Icons.logout),
                          onTap: () {
                            controller.onLogout();
                          },
                        ),
                        AppStyle.divider,
                        ListTile(
                          title: const Text("上传到云端"),
                          subtitle: Text("上次上传：${controller.lastUploadTime}"),
                          leading: const Icon(Icons.cloud_upload_outlined),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () {
                            controller.doWebDAVUpload();
                          },
                        ),
                        AppStyle.divider,
                        ListTile(
                          title: const Text("恢复到本地"),
                          subtitle: Text("上次恢复：${controller.lastRecoverTime}"),
                          leading: const Icon(Icons.cloud_download_outlined),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: controller.doWebDAVRecovery,
                        ),
                        AppStyle.divider,
                        ListTile(
                          title: const Text('导入旧备份账号'),
                          leading: const Icon(Icons.person_outline),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: controller.importLegacyAccount,
                        ),
                      ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          SettingsCard(
            child: ListTile(
              title: const Text('回滚最近一次恢复'),
              leading: const Icon(Icons.undo),
              trailing: const Icon(Icons.chevron_right),
              onTap: controller.rollback,
            ),
          ),
        ],
      ),
    );
  }
}
