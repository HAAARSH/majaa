package com.example.fmcgorders

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.os.Build

// Receives result callbacks from PackageInstaller.Session.commit().
//
// Three relevant statuses:
//  - STATUS_PENDING_USER_ACTION: Android needs the user to confirm the install
//    on the system installer screen. Happens on the first install from this
//    source on Android 12+, and always on Android 8-11.
//  - STATUS_SUCCESS: install succeeded. App is being replaced; nothing to do.
//  - anything else: install failed. The Flutter UI is gone (finishAffinity ran
//    inside MainActivity), so we surface the failure via a system notification.
class InstallResultReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, -1)
        when (status) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                @Suppress("DEPRECATION")
                val confirm = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
                } else {
                    intent.getParcelableExtra(Intent.EXTRA_INTENT)
                }
                confirm?.apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    addFlags(Intent.FLAG_ACTIVITY_CLEAR_TASK)
                }?.let { context.startActivity(it) }
            }
            PackageInstaller.STATUS_SUCCESS -> {
                // No-op: the new APK is installed and Android will let the user
                // re-launch it from the installer's "Open" button or the home
                // screen icon.
            }
            else -> {
                val msg = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)
                    ?: "Install failed (status $status)"
                postFailureNotification(context, msg)
            }
        }
    }

    private fun postFailureNotification(context: Context, message: String) {
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "App updates",
                NotificationManager.IMPORTANCE_HIGH,
            )
            nm.createNotificationChannel(channel)
        }
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context)
        }
        val notification = builder
            .setSmallIcon(android.R.drawable.stat_sys_warning)
            .setContentTitle("MAJAA update failed")
            .setContentText(message)
            .setStyle(Notification.BigTextStyle().bigText(message))
            .setAutoCancel(true)
            .build()
        nm.notify(NOTIFICATION_ID, notification)
    }

    companion object {
        const val ACTION_INSTALL_RESULT = "com.example.fmcgorders.INSTALL_RESULT"
        private const val CHANNEL_ID = "majaa_app_updates"
        private const val NOTIFICATION_ID = 9001
    }
}
