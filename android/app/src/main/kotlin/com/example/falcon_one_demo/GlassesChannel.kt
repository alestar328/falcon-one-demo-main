package com.example.falcon_one_demo

import android.bluetooth.BluetoothDevice
import android.content.Context
import android.net.wifi.WifiManager
import android.os.Handler
import android.os.Looper
import com.bleequp.bleequplibrary.BleeqUpCommandManager
import com.bleequp.bleequplibrary.BleeqUpDevice
import com.bleequp.bleequplibrary.BleeqUpDeviceManager
import com.bleequp.bleequplibrary.BleeqUpSDK
import com.bleequp.bleequplibrary.BleeqUpWifiManager
import com.bleequp.bleequplibrary.DeviceConnectionState
import com.bleequp.bleequplibrary.KeyEvent
import com.bleequp.bleequplibrary.WifiName
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.net.InetAddress

class GlassesChannel(private val context: Context) :
    MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private val mainHandler = Handler(Looper.getMainLooper())
    private var eventSink: EventChannel.EventSink? = null
    private var connectedDevice: BleeqUpDevice? = null

    // Devices discovered during scan, keyed by MAC address.
    // BleeqUpDevice constructor is internal — only obtainable via onDeviceFound.
    private val discoveredDevices = mutableMapOf<String, BleeqUpDevice>()

    // BleeqUpDeviceManager.<clinit> calls BleeqUpSDK.getMContext() — so no SDK class may be
    // touched until BleeqUpSDK.init() has run. Callback registration is deferred to initSdk().
    private var callbackRegistered = false

    private fun registerGlobalCallback() {
        if (callbackRegistered) return
        callbackRegistered = true
        BleeqUpDeviceManager.registerCallback(object : BleeqUpDeviceManager.BluetoothListener {
            override fun onConnected(device: BleeqUpDevice) {
                emit("onConnected", mapOf("mac" to device.address, "name" to device.name))
            }

            override fun onReady(device: BleeqUpDevice) {
                connectedDevice = device
                registerDeviceCallbacks(device)
                BleeqUpWifiManager.registerWifiListener(device, wifiListener)
                emit("onConnected", mapOf("mac" to device.address, "name" to device.name))
            }

            override fun onDisconnected(device: BleeqUpDevice) {
                if (connectedDevice?.address == device.address) {
                    BleeqUpWifiManager.unregisterWifiCallback(device)
                    unregisterDeviceCallbacks(device)
                    connectedDevice = null
                }
                emit("onDisconnected", mapOf("mac" to device.address))
            }

            override fun onError(device: BleeqUpDevice, code: Int, message: String) {
                emit("onError", mapOf("message" to "[$code] $message", "mac" to device.address))
            }

            override fun onBondStateChanged(device: BluetoothDevice, state: Int) {}
        })
    }

    private val wifiListener = object : BleeqUpWifiManager.WifiListener {
        override fun onSwitch(z: Boolean) {
            if (z) emit("onWifiOn", emptyMap()) else emit("onWifiOff", emptyMap())
        }
        override fun onConnection(z: Boolean) {
            emit("onWifiConnection", mapOf("connected" to z))
        }
    }

    private fun registerDeviceCallbacks(device: BleeqUpDevice) {
        BleeqUpCommandManager.registerCameraCallback(device,
            object : BleeqUpCommandManager.CameraListener {
                override fun onVideoInfo(fileName: String) {
                    emit("onRecordingStopped", emptyMap())
                    emit("onVideoReady", mapOf("fileName" to fileName))
                }
                override fun onPhotoInfo(fileName: String) {
                    emit("onPhotoReady", mapOf("fileName" to fileName))
                }
            })

        BleeqUpCommandManager.registerButtonCallback(device,
            object : BleeqUpCommandManager.ButtonListener {
                override fun onLeftButtonEvent(event: KeyEvent) {
                    emit("onButton", mapOf("side" to "left", "action" to event.name))
                }
                override fun onRightButtonEvent(event: KeyEvent) {
                    emit("onButton", mapOf("side" to "right", "action" to event.name))
                }
            })

        BleeqUpCommandManager.registerPowerCallback(device,
            object : BleeqUpCommandManager.PowerListener {
                override fun onBatteryLevel(level: Int) {
                    emit("onBattery", mapOf("level" to level))
                }
                override fun onChargingStatus(charge: Boolean) {
                    emit("onCharging", mapOf("charging" to charge))
                }
            })
    }

    private fun unregisterDeviceCallbacks(device: BleeqUpDevice) {
        BleeqUpCommandManager.unregisterCameraCallback(device)
        BleeqUpCommandManager.unregisterButtonCallback(device)
        BleeqUpCommandManager.unregisterPowerCallback(device)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {

            "initSdk" -> {
                val apiKey = call.argument<String>("apiKey") ?: "falcon-one"
                BleeqUpSDK.init(context, apiKey) { _: Int, _: String -> }
                registerGlobalCallback()
                result.success(null)
            }

            "startScan" -> {
                discoveredDevices.clear()
                BleeqUpDeviceManager.startScan(object : BleeqUpDeviceManager.BluetoothScanListener {
                    override fun onDeviceFound(device: BleeqUpDevice) {
                        discoveredDevices[device.address] = device
                        emit("onDeviceFound", mapOf(
                            "name"    to device.name,
                            "address" to device.address,
                            "rssi"    to device.rssi,
                        ))
                    }
                    override fun onScanError(code: Int, message: String) {
                        emit("onError", mapOf("message" to "Scan [$code]: $message"))
                    }
                }, 10_000L)
                result.success(null)
            }

            "stopScan" -> {
                BleeqUpDeviceManager.stopScan()
                result.success(null)
            }

            "connectDevice" -> {
                val address = call.argument<String>("address") ?: run {
                    result.error("ARGS", "address required", null); return
                }
                val device = discoveredDevices[address]
                    ?: deviceFromBondedAddress(address)
                    ?: run {
                        result.error("NOT_FOUND", "device $address not bonded — scan with glasses powered on", null); return
                    }
                BleeqUpDeviceManager.connect(device, 30_000L) { ok: Boolean ->
                    if (ok) result.success(null)
                    else result.error("CONNECT", "connection failed — ensure glasses are powered on and not connected elsewhere", null)
                }
            }

            "disconnect" -> {
                connectedDevice?.let { BleeqUpDeviceManager.disconnect(it) }
                result.success(null)
            }

            "startRecording" -> {
                val dev = connectedDevice ?: run {
                    result.error("NOT_CONNECTED", "glasses not connected", null); return
                }
                if (dev.state != DeviceConnectionState.READY) {
                    result.error("NOT_READY", "glasses not ready", null); return
                }
                BleeqUpCommandManager.startRecord(dev) { ok: Boolean, msg: String ->
                    if (ok) {
                        emit("onRecordingStarted", emptyMap())
                        result.success(null)
                    } else {
                        result.error("CMD", msg, null)
                    }
                }
            }

            "stopRecording" -> {
                val dev = connectedDevice ?: run {
                    result.error("NOT_CONNECTED", "glasses not connected", null); return
                }
                if (dev.state != DeviceConnectionState.READY) {
                    result.error("NOT_READY", "glasses not ready", null); return
                }
                BleeqUpCommandManager.stopRecord(dev) { ok: Boolean, msg: String ->
                    if (ok) result.success(null)
                    else result.error("CMD", msg, null)
                }
            }

            "takePhoto" -> {
                val dev = connectedDevice ?: run {
                    result.error("NOT_CONNECTED", "glasses not connected", null); return
                }
                if (dev.state != DeviceConnectionState.READY) {
                    result.error("NOT_READY", "glasses not ready", null); return
                }
                BleeqUpCommandManager.takePhoto(dev) { ok: Boolean, msg: String ->
                    if (ok) result.success(null) else result.error("CMD", msg, null)
                }
            }

            "turnOnWifi" -> {
                val dev = connectedDevice ?: run {
                    result.error("NOT_CONNECTED", "glasses not connected", null); return
                }
                val password = call.argument<String>("password") ?: run {
                    result.error("ARGS", "password required (8 alphanumeric chars)", null); return
                }
                BleeqUpWifiManager.turnOnWifi(dev, password) { ok: Boolean, wifiName: WifiName, msg: String ->
                    if (ok) result.success(mapOf("ssid" to wifiName.name, "password" to wifiName.password))
                    else result.error("WIFI", msg, null)
                }
            }

            "turnOffWifi" -> {
                val dev = connectedDevice ?: run { result.success(null); return }
                BleeqUpWifiManager.turnOffWifi(dev) { _: Boolean, _: String -> }
                result.success(null)
            }

            "downloadFile" -> {
                val dev = connectedDevice ?: run {
                    result.error("NOT_CONNECTED", "glasses not connected", null); return
                }
                val fileName = call.argument<String>("fileName") ?: run {
                    result.error("ARGS", "fileName required", null); return
                }
                val fileSize: Number = call.argument<Int>("fileSize") ?: 0

                val ip = getGatewayIp() ?: run {
                    result.error("WIFI", "not connected to glasses WiFi — no gateway found", null); return
                }

                val downloadDir = context.getExternalFilesDir("GlassesVideos") ?: context.filesDir
                downloadDir.mkdirs()

                BleeqUpWifiManager.downloadFile(
                    dev,
                    ip,
                    fileName,
                    "video",
                    fileSize,
                    downloadDir.absolutePath,
                    { msg: String ->
                        result.error("DOWNLOAD", msg, null)
                    },
                    { bytes: Number ->
                        val total = fileSize.toLong()
                        val progress = if (total > 0) bytes.toLong().toDouble() / total else 0.0
                        emit("onDownloadProgress", mapOf("progress" to progress.coerceIn(0.0, 1.0)))
                    },
                    {
                        val filePath = File(downloadDir, fileName).absolutePath
                        emit("onDownloadComplete", mapOf("path" to filePath, "filePath" to filePath))
                        result.success(mapOf("path" to filePath))
                    },
                )
            }

            "getBondedDevices" -> {
                try {
                    @Suppress("DEPRECATION")
                    val adapter = android.bluetooth.BluetoothAdapter.getDefaultAdapter()
                    val bonded = adapter?.bondedDevices?.map { d ->
                        mapOf("name" to (d.name ?: ""), "address" to d.address)
                    } ?: emptyList()
                    result.success(bonded)
                } catch (e: Exception) {
                    result.success(emptyList<Map<String, String>>())
                }
            }

            "isConnected" -> {
                result.success(connectedDevice?.state == DeviceConnectionState.READY)
            }

            "release" -> {
                connectedDevice?.let {
                    BleeqUpWifiManager.unregisterWifiCallback(it)
                    unregisterDeviceCallbacks(it)
                }
                BleeqUpDeviceManager.release()
                connectedDevice = null
                discoveredDevices.clear()
                result.success(null)
            }

            else -> result.notImplemented()
        }
    }

    // BleeqUpDevice constructor is `internal` (module-private at Kotlin level) but compiles to
    // `public` in JVM bytecode, so reflection can bypass the compile-time restriction and let us
    // connect to a bonded device without needing a prior BLE scan.
    @Suppress("DEPRECATION")
    private fun deviceFromBondedAddress(address: String): BleeqUpDevice? {
        return try {
            val adapter = android.bluetooth.BluetoothAdapter.getDefaultAdapter() ?: return null
            val btDevice = adapter.getRemoteDevice(address) ?: return null
            val clazz = BleeqUpDevice::class.java
            // Find the primary constructor whose first parameter is BluetoothDevice
            val ctor = clazz.declaredConstructors.firstOrNull { c ->
                c.parameterTypes.firstOrNull() == android.bluetooth.BluetoothDevice::class.java
                    && c.parameterTypes.size <= 5 // exclude Kotlin's synthetic default-arg ctor
            } ?: return null
            ctor.isAccessible = true
            val args: Array<Any?> = when (ctor.parameterTypes.size) {
                1 -> arrayOf(btDevice)
                2 -> arrayOf(btDevice, null)
                3 -> arrayOf(btDevice, null, -60)
                4 -> arrayOf(btDevice, null, -60, "W")
                else -> return null
            }
            val dev = ctor.newInstance(*args) as? BleeqUpDevice
            if (dev != null) discoveredDevices[address] = dev
            dev
        } catch (e: Exception) {
            android.util.Log.w("GlassesChannel", "deviceFromBondedAddress($address) failed: ${e.message}")
            null
        }
    }

    private fun getGatewayIp(): String? {
        return try {
            @Suppress("DEPRECATION")
            val wm = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            val gateway = wm.dhcpInfo?.gateway ?: return null
            if (gateway == 0) return null
            InetAddress.getByAddress(byteArrayOf(
                (gateway        and 0xFF).toByte(),
                (gateway shr  8 and 0xFF).toByte(),
                (gateway shr 16 and 0xFF).toByte(),
                (gateway shr 24 and 0xFF).toByte(),
            )).hostAddress
        } catch (e: Exception) {
            null
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    private fun emit(event: String, extras: Map<String, Any?>) {
        val payload = HashMap<String, Any?>(extras.size + 1)
        payload["event"] = event
        extras.forEach { (k, v) -> if (v != null) payload[k] = v }
        mainHandler.post { eventSink?.success(payload) }
    }
}
