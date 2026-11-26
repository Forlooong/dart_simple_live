# 2026-11-26 Simple Live 维护治理与净变更审计

## 审计范围

北京时间 2026-11-12 至 11-26。日常 Git 引用涉及 37 个提交。原始工作区以 `d297431` 为 HEAD，有 91 个跟踪文件变化和 22 个未跟踪文件。远端引用已通过 `git ls-remote origin refs/heads/master` 核实为 `2276af99831c75ab975255dca9e18babc3f9328f`，维护分支以此为基线。原工作区保留。管理工作树的默认写权限受限，实施使用针对隔离工作树获批的命令；`AGENTS.md` 首先独立提交。

## 历史提交治理

| 提交 | 处置 | 依据 |
| --- | --- | --- |
| `fb73e90`、`7e5656b`、`6773452` | 保留主线，等价候选不再叠加 | `git diff 6773452 fb73e90` 无变化。WebDAV、通知、账号和发布保护已由主线继承。 |
| `a35532e`；另核对 `f5b366b` | 保留主线更新通道 | 两提交最终树相同。清单来源、包身份和摘要贯穿下载与安装；自动检查时机的工作区实验延期。 |
| `270f702`、`2007f7c`、`1fe94ac` | 保留四站礼物、版本历史和四构建目标 | Dart 与 Rust 消费同一礼物模型；发布工具与工作流共同选择四个目标。 |
| `7e10f3c`、`38c571f`、`2d950f1` | 保留聚合、推荐排序与按标签中文说明；删除废弃入口 | 路由进聚合搜索，四个旧搜索文件仅在旧实现内相互引用。推荐跨分区快照仍被分页使用。构建标签对应说明仍由发布准备读取。 |
| `2cd1d33`、`7ced3bf`、`0ce3bf8`、`c614392` | 保留生命周期、关键词和开播时间修复；重写搜索来源状态 | Room 控制器串行命令，关注服务读取状态快照开播时间。搜索两个来源原先共用一个页码，部分失败没有制约失败来源。 |
| `ea4aa07`、`e3a3873`、`8744833`、`0c97014` | 保留 Windows 修正引擎、专用锁文件、缩放探针和版本历史 | 安装工作流对 Windows 使用专用锁。探针原先尚未接入主线候选运行检查。 |
| `75f6cec`、`e5efac1`、`2276af9` | 保留弹幕生命周期、动态握手回退和重试预算 | 直播间、弹幕 transport 及渲染器负责不同生命周期；播放器原有限额按媒体推进重置，滚动预算补足短时重复中断。 |
| `b711d6f`、`2f48b4f`、`2da5ae4` | 采用主线对应补丁 | `git range-diff c614392..origin/master c614392..32f18ff` 显示前两项补丁一致，第三项只有提交消息差异。 |
| `009b4c8`、`96fe78e`、`548b78f`、`7d47efa`、`f4b6457` | 保留为实验记录 | 引擎对照和屏幕缩放实验在验证分支。维护分支复用实际安装和设备验证接口，屏幕缩放矩阵保留手工验收。 |
| `61d5e7c`、`5d20051`、`29661e1`、`4bc6e29`、`4610730`、`6adf114`、`d3d3edb`、`32f18ff` | 合并可复用的验收，撤掉固定旧包名与运行号 | 独立工作流从现有发布准备流程取得候选 SHA、签名和包摘要；Android 复用 4 KiB／16 KiB 模拟器升级检查，Windows 区分实际安装包与同源播放探针。 |

## 候选净变更检查

| 范围 | 必要性、实现取舍与保留契约 |
| --- | --- |
| 通知 | 原逻辑用任意房间的确认状态消费整批记录。改为按房间和凭据版本提交，复用后台已有单写者、订阅 generation 和序列化写入。状态先落盘，发送失败或落盘后退出可能漏发，避免重放可能已经显示的通知。落盘前失败不发通知，下一轮可重试。 |
| WebDAV 数据 | 恢复日志以预期写入结果核实提交，跳过并发冲突。无改动继续沿用原版本恢复点。保留标签顺序及既有组内恢复，不引入跨组事务。现有 Hive 格式与旧备份读取路径维持。 |
| WebDAV 会话 | 原地址、用户名、已确认目标和密码分别写入，后一步失败会留下混合配置。将同一会话置于一个安全存储条目，成功后才更新客户端与界面。仅缺少新条目时回读旧字段，退出以空条目屏蔽旧会话。旧密码清理失败只记录诊断，新会话继续有效。 |
| B 站导入 | 运输入口复用账号服务，远程验证结束后在串行提交点复核代次。原配对、用户确认和响应格式继续使用。持久化成功才更新账号和平台会话。 |
| 搜索 | TV 以现有分页基类统一请求所有权。取消和 20 秒请求预算只配置给房间和主播搜索，其他入口保持原请求预算。房间和主播从已提交结果导航。Core 房间查询会话维护两个抖音来源的分页状态，复用退避和协议解析；通用搜索接口和直链保留。网页按钮作为失败或空结果的补充入口。双端原有关注和历史匹配保持。 |
| 清理 | 四个废弃搜索文件经全仓引用检索后删除。抖音调试输出只走 CoreLog。格式化范围限于修复所在文件并去除大段测试的无关排版变化。旧版本发布资料保留。 |
| 发布 | 候选运行检查使用现有发布准备器验证 SHA、版本、签名和摘要。说明按应用选择已有纯文本字段，旧文件继续读取。公开发布工作流要求已审阅 SHA 与候选一致。 |
| 延期项 | 首页查量排序的首屏等待仍需测量。跨端播放器、更新 UI、Android 桥接与通用存储归并缺少本轮必须改变的行为依据，单独排期。 |

## 工作区逐文件处置

比较原工作区文件、`fb73e90` 和 `2276af9` Git blob，忽略纯 CRLF 差异。基线已包含的内容只在维护分支保留一份。对照报告中的“保留”包含基线保留后在维护分支修复对应缺陷的文件。

| 路径 | 处置与依据 |
| --- | --- |

| .codex-remote-attachments/01a14a96-4acf-7a10-9dea-e0598a2528d8/3482356c-bf65-469c-8c67-596bdad6b3b3/1-1000128899.jpg | 排除。原工作区的本地附件或生成产物。 |
| .dart_tool/Simple-Live-1.12.30+11131-r12.1-2d950f1-Android-arm64-ReleaseSigned.apk | 排除。原工作区的本地附件或生成产物。 |
| .dart_tool/android-playback-final-test.txt | 排除。原工作区的本地附件或生成产物。 |
| .dart_tool/android-playback-focused-test.txt | 排除。原工作区的本地附件或生成产物。 |
| .dart_tool/android-playback-reliability-plan.md | 排除。原工作区的本地附件或生成产物。 |
| .dart_tool/run_playback_tests_without_native_hooks.py | 排除。原工作区的本地附件或生成产物。 |
| .github/workflows/installers.yml | 保留较新主线契约。撤销旧版本、旧 Windows 引擎、旧播放状态、旧抖音能力或删减结果字段；维护分支仅加入有据修复。 |
| .github/workflows/pull-request-checks.yml | 保留。原工作区和主线内容一致。 |
| .github/workflows/update-release.yml | 保留。原工作区和主线内容一致。 |
| README.md | 保留。原工作区和主线内容一致。 |
| docs/fork-builds.md | 取有效增量。保留主线按标签说明和发布校验，补应用专属说明与候选审批。 |
| docs/live-interaction-feasibility.md | 延期。探索文档或新增外站账号入口，当前修复无该依赖。 |
| docs/release-gates.md | 取有效增量。保留主线按标签说明和发布校验，补应用专属说明与候选审批。 |
| docs/selected-room-live-notifications.md | 保留。原工作区和主线内容一致。 |
| simple_live_app/android/app/src/main/kotlin/com/xycz/simple_live/MainActivity.kt | 保留。原工作区和主线内容一致。 |
| simple_live_app/lib/app/controller/app_settings_controller.dart | 保留。原工作区和主线内容一致。 |
| simple_live_app/lib/app/log.dart | 保留。原工作区和主线内容一致。 |
| simple_live_app/lib/main.dart | 延期。保留主线自动更新时机与版本判定，另测跨路由提示变更。 |
| simple_live_app/lib/models/db/follow_user.dart | 撤销较早快照。保留主线后续修复。 |
| simple_live_app/lib/modules/follow_user/follow_user_page.dart | 保留。原工作区和主线内容一致。 |
| simple_live_app/lib/modules/follow_user/live_reminder_center.dart | 保留。原工作区和主线内容一致。 |
| simple_live_app/lib/modules/live_room/live_room_controller.dart | 保留较新主线契约。撤销旧版本、旧 Windows 引擎、旧播放状态、旧抖音能力或删减结果字段；维护分支仅加入有据修复。 |
| simple_live_app/lib/modules/live_room/live_room_page.dart | 保留较新主线契约。撤销旧版本、旧 Windows 引擎、旧播放状态、旧抖音能力或删减结果字段；维护分支仅加入有据修复。 |
| simple_live_app/lib/modules/live_room/player/player_controller.dart | 撤销较早快照。保留主线后续修复。 |
| simple_live_app/lib/modules/live_room/player/player_controls.dart | 保留。原工作区和主线内容一致。 |
| simple_live_app/lib/modules/mine/account/account_page.dart | 延期。探索文档或新增外站账号入口，当前修复无该依赖。 |
| simple_live_app/lib/modules/mine/mine_page.dart | 保留。原工作区和主线内容一致。 |
| simple_live_app/lib/modules/search/aggregate_search.dart | 重写有据的分页／回退差异，保留主线结果模型、聚合、关键词搜索和直链。传入的数据模型继续兼容现有调用。 |
| simple_live_app/lib/modules/search/aggregate_search_view.dart | 重写有据的分页／回退差异，保留主线结果模型、聚合、关键词搜索和直链。传入的数据模型继续兼容现有调用。 |
| simple_live_app/lib/modules/search/douyin/douyin_search_controller.dart | 删除。聚合搜索已替代路由和 GetX 注册，全仓引用仅在废弃文件内。 |
| simple_live_app/lib/modules/search/douyin/douyin_search_view.dart | 删除。聚合搜索已替代路由和 GetX 注册，全仓引用仅在废弃文件内。 |
| simple_live_app/lib/modules/search/search_controller.dart | 重写有据的分页／回退差异，保留主线结果模型、聚合、关键词搜索和直链。传入的数据模型继续兼容现有调用。 |
| simple_live_app/lib/modules/search/search_page.dart | 重写有据的分页／回退差异，保留主线结果模型、聚合、关键词搜索和直链。传入的数据模型继续兼容现有调用。 |
| simple_live_app/lib/modules/settings/other/other_settings_controller.dart | 保留。原工作区和主线内容一致。 |
| simple_live_app/lib/modules/settings/play_settings_page.dart | 保留。原工作区和主线内容一致。 |
| simple_live_app/lib/modules/sync/local_sync/device/sync_device_controller.dart | 保留。原工作区和主线内容一致。 |
| simple_live_app/lib/modules/sync/remote_sync/room/remote_sync_room_controller.dart | 保留。原工作区和主线内容一致。 |
| simple_live_app/lib/modules/sync/remote_sync/webdav/remote_sync_webdav_controller.dart | 保留。原工作区和主线内容一致。 |
| simple_live_app/lib/modules/sync/remote_sync/webdav/remote_sync_webdav_page.dart | 保留。原工作区和主线内容一致。 |
| simple_live_app/lib/modules/sync/remote_sync/webdav/webdav_restore.dart | 保留。原工作区和主线内容一致。 |
| simple_live_app/lib/services/app_update_service.dart | 延期。保留主线自动更新时机与版本判定，另测跨路由提示变更。 |
| simple_live_app/lib/services/bilibili_account_service.dart | 保留。原工作区和主线内容一致。 |
| simple_live_app/lib/services/db_service.dart | 保留。原工作区和主线内容一致。 |
| simple_live_app/lib/services/follow_service.dart | 保留。原工作区和主线内容一致。 |
| simple_live_app/lib/services/live_notification_service.dart | 保留。原工作区和主线内容一致。 |
| simple_live_app/lib/services/live_notifications/android_live_notifications.dart | 保留。原工作区和主线内容一致。 |
| simple_live_app/lib/services/live_notifications/live_check_runner.dart | 保留。原工作区和主线内容一致。 |
| simple_live_app/lib/services/live_notifications/notification_store.dart | 保留。原工作区和主线内容一致。 |
| simple_live_app/lib/services/live_notifications/notification_subscription.dart | 保留。原工作区和主线内容一致。 |
| simple_live_app/lib/services/local_storage_service.dart | 保留。原工作区和主线内容一致。 |
| simple_live_app/lib/services/signalr_service.dart | 保留。原工作区和主线内容一致。 |
| simple_live_app/lib/services/sync_service.dart | 保留。原工作区和主线内容一致。 |
| simple_live_app/lib/widgets/follow_user_item.dart | 撤销较早快照。保留主线后续修复。 |
| simple_live_app/lib/widgets/page_grid_view.dart | 保留。原工作区和主线内容一致。 |
| simple_live_app/test/account_session_test.dart | 保留。原工作区和主线内容一致。 |
| simple_live_app/test/aggregate_search_test.dart | 重写有据的分页／回退差异，保留主线结果模型、聚合、关键词搜索和直链。传入的数据模型继续兼容现有调用。 |
| simple_live_app/test/credential_safety_test.dart | 保留。原工作区和主线内容一致。 |
| simple_live_app/test/live_notification_runner_test.dart | 保留。原工作区和主线内容一致。 |
| simple_live_app/test/live_notification_service_test.dart | 保留。原工作区和主线内容一致。 |
| simple_live_app/test/storage_restore_test.dart | 保留。原工作区和主线内容一致。 |
| simple_live_core/lib/simple_live_core.dart | 撤销较早快照。保留主线后续修复。 |
| simple_live_core/lib/src/bilibili_site.dart | 保留。原工作区和主线内容一致。 |
| simple_live_core/lib/src/common/app_update.dart | 延期。保留主线自动更新时机与版本判定，另测跨路由提示变更。 |
| simple_live_core/lib/src/common/core_error.dart | 保留。原工作区和主线内容一致。 |
| simple_live_core/lib/src/common/diagnostic_metadata.dart | 保留。原工作区和主线内容一致。 |
| simple_live_core/lib/src/common/platform_recovery.dart | 保留。原工作区和主线内容一致。 |
| simple_live_core/lib/src/common/status_refresh.dart | 保留。原工作区和主线内容一致。 |
| simple_live_core/lib/src/danmaku/douyu_danmaku.dart | 保留。原工作区和主线内容一致。 |
| simple_live_core/lib/src/danmaku/huya_danmaku.dart | 保留。原工作区和主线内容一致。 |
| simple_live_core/lib/src/danmaku/native_live_danmaku.dart | 保留。原工作区和主线内容一致。 |
| simple_live_core/lib/src/douyin_site.dart | 保留较新主线契约。撤销旧版本、旧 Windows 引擎、旧播放状态、旧抖音能力或删减结果字段；维护分支仅加入有据修复。 |
| simple_live_core/lib/src/douyu_site.dart | 保留。原工作区和主线内容一致。 |
| simple_live_core/lib/src/huya_site.dart | 保留。原工作区和主线内容一致。 |
| simple_live_core/lib/src/interface/live_site.dart | 保留。原工作区和主线内容一致。 |
| simple_live_core/lib/src/model/live_anchor_item.dart | 撤销较早快照。保留主线后续修复。 |
| simple_live_core/lib/src/model/live_message.dart | 保留。原工作区和主线内容一致。 |
| simple_live_core/lib/src/model/live_room_item.dart | 重写有据的分页／回退差异，保留主线结果模型、聚合、关键词搜索和直链。传入的数据模型继续兼容现有调用。 |
| simple_live_core/lib/src/model/live_search_result.dart | 重写有据的分页／回退差异，保留主线结果模型、聚合、关键词搜索和直链。传入的数据模型继续兼容现有调用。 |
| simple_live_core/packages/danmaku_native/rust/src/protocols.rs | 保留。原工作区和主线内容一致。 |
| simple_live_core/packages/danmaku_native/rust/src/tars.rs | 保留。原工作区和主线内容一致。 |
| simple_live_core/packages/danmaku_native/rust/src/tests.rs | 保留。原工作区和主线内容一致。 |
| simple_live_core/test/app_update_test.dart | 延期。保留主线自动更新时机与版本判定，另测跨路由提示变更。 |
| simple_live_core/test/douyin_home_feed_test.dart | 保留。原工作区和主线内容一致。 |
| simple_live_core/test/douyin_search_test.dart | 重写有据的分页／回退差异，保留主线结果模型、聚合、关键词搜索和直链。传入的数据模型继续兼容现有调用。 |
| simple_live_core/test/live_gift_test.dart | 保留。原工作区和主线内容一致。 |
| simple_live_core/test/platform_recovery_test.dart | 保留。原工作区和主线内容一致。 |
| simple_live_core/test/playback_transport_test.dart | 保留。原工作区和主线内容一致。 |
| simple_live_tv_app/android/app/src/main/kotlin/com/xycz/simple_live_tv/MainActivity.kt | 保留。原工作区和主线内容一致。 |
| simple_live_tv_app/lib/app/log.dart | 保留。原工作区和主线内容一致。 |
| simple_live_tv_app/lib/main.dart | 延期。保留主线自动更新时机与版本判定，另测跨路由提示变更。 |
| simple_live_tv_app/lib/models/db/follow_user.dart | 保留。原工作区和主线内容一致。 |
| simple_live_tv_app/lib/modules/follow_user/follow_user_page.dart | 保留。原工作区和主线内容一致。 |
| simple_live_tv_app/lib/modules/hot_live/hot_live_controller.dart | 保留较新主线契约。撤销旧版本、旧 Windows 引擎、旧播放状态、旧抖音能力或删减结果字段；维护分支仅加入有据修复。 |
| simple_live_tv_app/lib/modules/hot_live/hot_live_page.dart | 保留。原工作区和主线内容一致。 |
| simple_live_tv_app/lib/modules/search/anchor/search_anchor_controller.dart | 重写有据的分页／回退差异，保留主线结果模型、聚合、关键词搜索和直链。传入的数据模型继续兼容现有调用。 |
| simple_live_tv_app/lib/modules/search/anchor/search_anchor_page.dart | 重写有据的分页／回退差异，保留主线结果模型、聚合、关键词搜索和直链。传入的数据模型继续兼容现有调用。 |
| simple_live_tv_app/lib/modules/search/douyin_search_fallback.dart | 重写。仅在失败或空结果时降级为网页；关键词仍先走应用搜索。 |
| simple_live_tv_app/lib/modules/search/room/search_room_controller.dart | 重写有据的分页／回退差异，保留主线结果模型、聚合、关键词搜索和直链。传入的数据模型继续兼容现有调用。 |
| simple_live_tv_app/lib/modules/search/room/search_room_page.dart | 重写有据的分页／回退差异，保留主线结果模型、聚合、关键词搜索和直链。传入的数据模型继续兼容现有调用。 |
| simple_live_tv_app/lib/modules/settings/settings_page.dart | 保留。原工作区和主线内容一致。 |
| simple_live_tv_app/lib/modules/sync/sync_controller.dart | 保留。原工作区和主线内容一致。 |
| simple_live_tv_app/lib/services/app_update_service.dart | 延期。保留主线自动更新时机与版本判定，另测跨路由提示变更。 |
| simple_live_tv_app/lib/services/follow_user_service.dart | 保留。原工作区和主线内容一致。 |
| simple_live_tv_app/lib/services/signalr_service.dart | 保留。原工作区和主线内容一致。 |
| simple_live_tv_app/lib/services/sync_service.dart | 保留。原工作区和主线内容一致。 |
| simple_live_tv_app/lib/widgets/card/anchor_card.dart | 保留。原工作区和主线内容一致。 |
| simple_live_tv_app/lib/widgets/highlight_widget.dart | 保留。原工作区和主线内容一致。 |
| simple_live_tv_app/lib/widgets/status/app_error_widget.dart | 保留。原工作区和主线内容一致。 |
| simple_live_tv_app/test/douyin_search_fallback_test.dart | 重写。仅在失败或空结果时降级为网页；关键词仍先走应用搜索。 |
| simple_live_tv_app/test/highlight_widget_test.dart | 保留。原工作区和主线内容一致。 |
| tool/prepare_update_release.py | 取有效增量。保留主线按标签说明和发布校验，补应用专属说明与候选审批。 |
| tool/test_installer_identity.py | 保留。原工作区和主线内容一致。 |
| tool/test_update_release.py | 取有效增量。保留主线按标签说明和发布校验，补应用专属说明与候选审批。 |
