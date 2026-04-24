package com.example.falcon_one_demo

import android.content.Context
import android.net.wifi.WifiManager
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

const val METHOD_CHANNEL = "com.falconone/bodycam"
const val EVENT_CHANNEL  = "com.falconone/bodycam_events"

class BodyCamChannel(private val context: Context) : MethodCallHandler, EventChannel.StreamHandler {

    private val bt = BluetoothSppController(context)
    private var eventSink: EventChannel.EventSink? = null

    init {
        bt.onStateChange = { state, error ->
            val map = mutableMapOf<String, Any?>(
                "type"  to "bt_state",
                "state" to state.name,
                "error" to error
            )
            eventSink?.success(map)
        }
        bt.onDataReceived = { data ->
            val map = mapOf(
                "type" to "bt_data",
                "data" to String(data, Charsets.UTF_8)
            )
            eventSink?.success(map)
        }
    }

    // ── MethodChannel ──────────────────────────────────────────────────────────

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {

            "connect" -> {
                val mac = call.argument<String>("mac") ?: BODYCAM_MAC
                bt.connect(mac)
                result.success(null)
            }

            "disconnect" -> {
                bt.disconnect()
                result.success(null)
            }

            "isConnected" -> result.success(bt.isConnected())

            "startRecording" -> {
                if (!bt.isConnected()) { result.error("NOT_CONNECTED", "Bodycam no conectada", null); return }
                result.success(bt.startRecording())
            }

            "stopRecording" -> {
                if (!bt.isConnected()) { result.error("NOT_CONNECTED", "Bodycam no conectada", null); return }
                result.success(bt.stopRecording())
            }

            "takePhoto" -> {
                if (!bt.isConnected()) { result.error("NOT_CONNECTED", "Bodycam no conectada", null); return }
                result.success(bt.takePhoto())
            }

            "sendRaw" -> {
                val data = call.argument<String>("data") ?: ""
                if (!bt.isConnected()) { result.error("NOT_CONNECTED", "Bodycam no conectada", null); return }
                result.success(bt.send(data))
            }

            "setWifiAlwaysOn" -> {
                setWifiAlwaysOn()
                result.success(null)
            }

            "getBodycamInfo" -> result.success(mapOf(
                "mac"  to BODYCAM_MAC,
                "name" to BODYCAM_NAME,
                "uuid" to "00001101-0000-1000-8000-00805F9B34FB"
            ))

            else -> result.notImplemented()
        }
    }

    // ── EventChannel ───────────────────────────────────────────────────────────

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
        eventSink = sink
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    // ── WiFi keep-alive ────────────────────────────────────────────────────────

    private fun setWifiAlwaysOn() {
        val wm = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        @Suppress("DEPRECATION")
        wm.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "falcon_one_wifi_lock").acquire()
    }
}
