package com.example.falcon_one_demo

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private lateinit var bodyCamChannel: BodyCamChannel
    private lateinit var glassesChannel: GlassesChannel

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        bodyCamChannel = BodyCamChannel(applicationContext)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
            .setMethodCallHandler(bodyCamChannel)

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
            .setStreamHandler(bodyCamChannel)

        glassesChannel = GlassesChannel(applicationContext)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.falconone/glasses")
            .setMethodCallHandler(glassesChannel)

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "com.falconone/glasses_events")
            .setStreamHandler(glassesChannel)

        requestBluetoothPermissions()
    }

    private fun requestBluetoothPermissions() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val perms = arrayOf(
                Manifest.permission.BLUETOOTH_CONNECT,
                Manifest.permission.BLUETOOTH_SCAN,
            )
            val missing = perms.filter {
                checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED
            }
            if (missing.isNotEmpty()) requestPermissions(missing.toTypedArray(), 200)
        }
    }
}
