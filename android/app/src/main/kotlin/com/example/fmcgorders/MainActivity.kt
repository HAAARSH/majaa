package com.example.fmcgorders

import android.app.PendingIntent
import android.content.Intent
import android.content.pm.PackageInstaller
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterFragmentActivity() {
    private val CHANNEL = "com.example.fmcgorders/apk_install"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "canRequestInstall" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            result.success(packageManager.canRequestPackageInstalls())
                        } else {
                            result.success(true)
                        }
                    }
                    "requestInstallPermission" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            val intent = Intent(
                                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                Uri.parse("package:$packageName")
                            )
                            startActivity(intent)
                        }
                        result.success(true)
                    }
                    "installApk" -> {
                        val filePath = call.argument<String>("filePath")
                        if (filePath != null) {
                            installApk(filePath)
                            result.success(true)
                        } else {
                            result.error("INVALID_PATH", "File path is null", null)
                        }
                    }
                    "installApkSession" -> {
                        val filePath = call.argument<String>("filePath")
                        if (filePath == null) {
                            result.error("INVALID_PATH", "File path is null", null)
                        } else {
                            // APK write into the session can take a few seconds for
                            // a 30+ MB file — keep off the UI thread.
                            Thread {
                                try {
                                    installApkViaSession(filePath)
                                    runOnUiThread {
                                        result.success(true)
                                        finishAffinity()
                                    }
                                } catch (e: Exception) {
                                    runOnUiThread {
                                        result.error("SESSION_INSTALL_FAILED", e.message, null)
                                    }
                                }
                            }.start()
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    // Legacy fallback: opens the system Package Installer via ACTION_VIEW.
    // Kept as a one-line revert path if installApkSession misbehaves on a
    // specific OEM ROM.
    private fun installApk(filePath: String) {
        val file = File(filePath)
        val uri = FileProvider.getUriForFile(
            this,
            "com.example.fmcgorders.fileprovider",
            file
        )

        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        startActivity(intent)
        // Close the app so only the system installer remains visible.
        finishAffinity()
    }

    // Preferred installer: streams the APK into a PackageInstaller.Session and
    // commits via a PendingIntent that InstallResultReceiver handles. On
    // Android 12+ (API 31+) with USER_ACTION_NOT_REQUIRED, second and later
    // self-updates from this same source install silently with zero taps.
    private fun installApkViaSession(filePath: String) {
        val apkFile = File(filePath)
        val packageInstaller = packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(
            PackageInstaller.SessionParams.MODE_FULL_INSTALL
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            params.setRequireUserAction(
                PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED
            )
        }
        val sessionId = packageInstaller.createSession(params)
        packageInstaller.openSession(sessionId).use { session ->
            apkFile.inputStream().use { input ->
                session.openWrite("majaa_apk", 0, apkFile.length()).use { out ->
                    input.copyTo(out)
                    session.fsync(out)
                }
            }
            val callbackIntent = Intent(this, InstallResultReceiver::class.java).apply {
                action = InstallResultReceiver.ACTION_INSTALL_RESULT
            }
            val pendingFlags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
            } else {
                PendingIntent.FLAG_UPDATE_CURRENT
            }
            val pending = PendingIntent.getBroadcast(
                this, sessionId, callbackIntent, pendingFlags
            )
            session.commit(pending.intentSender)
        }
    }
}
