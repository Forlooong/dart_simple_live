package com.xycz.simple_live

import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.PackageInfo
import android.net.Uri
import android.os.Build
import android.os.Process
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest

class MainActivity : FlutterActivity() {
    @Suppress("DEPRECATION")
    private fun certificate(info: PackageInfo): String {
        val signers = if (Build.VERSION.SDK_INT >= 28)
            info.signingInfo?.apkContentsSigners else info.signatures
        require(signers != null && signers.size == 1) { "Unsupported signer" }
        return MessageDigest.getInstance("SHA-256").digest(signers[0].toByteArray())
            .joinToString("") { "%02x".format(it.toInt() and 255) }
    }

    @Suppress("DEPRECATION")
    private fun build(info: PackageInfo): Long =
        if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()

    @Suppress("DEPRECATION")
    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        MethodChannel(engine.dartExecutor.binaryMessenger, "simple_live/update")
            .setMethodCallHandler { call, result ->
                try {
                    val flags = if (Build.VERSION.SDK_INT >= 28)
                        PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES
                    val current = packageManager.getPackageInfo(packageName, flags)
                    when (call.method) {
                        "identity" -> {
                            val abis = Build.SUPPORTED_ABIS.filter {
                                it.contains("64") == Process.is64Bit()
                            }
                            val arch = when (abis.firstOrNull()) {
                                "arm64-v8a" -> "arm64"
                                "armeabi-v7a" -> "arm32"
                                "x86_64" -> "x64"
                                else -> "unsupported"
                            }
                            result.success(mapOf("arch" to arch, "sdk" to Build.VERSION.SDK_INT,
                                "certificate" to certificate(current)))
                        }
                        "install" -> {
                            val file = File(requireNotNull(call.argument<String>("path"))).canonicalFile
                            require(file.path.startsWith(cacheDir.canonicalPath + File.separator) &&
                                file.isFile && file.extension == "apk") { "Invalid update path" }
                            val archive = requireNotNull(packageManager.getPackageArchiveInfo(file.path, flags))
                            require(archive.packageName == packageName &&
                                certificate(archive) == certificate(current) &&
                                certificate(archive) == call.argument<String>("certificate") &&
                                build(archive) > build(current) &&
                                build(archive) == call.argument<Number>("build")?.toLong()) { "Incompatible update" }
                            if (Build.VERSION.SDK_INT >= 26 && !packageManager.canRequestPackageInstalls()) {
                                startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                    Uri.parse("package:" + packageName)))
                                result.success("permission")
                            } else {
                                val uri = FileProvider.getUriForFile(this, packageName + ".updates", file)
                                startActivity(Intent(Intent.ACTION_VIEW).setDataAndType(uri,
                                    "application/vnd.android.package-archive")
                                    .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION))
                                result.success("started")
                            }
                        }
                        else -> result.notImplemented()
                    }
                } catch (error: Exception) {
                    result.error("UPDATE_FAILED", "无法安装此更新，请检查签名、版本或系统授权", null)
                }
            }
    }
}
