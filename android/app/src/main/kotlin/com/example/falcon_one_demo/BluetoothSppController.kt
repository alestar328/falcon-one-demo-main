package com.example.falcon_one_demo

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothSocket
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.util.UUID
import java.util.concurrent.Executors

private const val TAG = "FalconBT"

// Custom UUID matching BtServerService on bodycam — avoids conflict with native SPP firmware
private val FALCON_UUID: UUID = UUID.fromString("FA1C0000-1337-4242-CAFE-DEADBEEF0001")
const val BODYCAM_MAC = "40:45:DA:44:C8:9B"
const val BODYCAM_NAME = "DSJ-ZXAN9A1"

enum class BtState { DISCONNECTED, CONNECTING, CONNECTED, ERROR }

class BluetoothSppController(private val context: Context) {

    private val adapter: BluetoothAdapter? = BluetoothAdapter.getDefaultAdapter()
    private var socket: BluetoothSocket? = null
    private var outputStream: OutputStream? = null
    private var inputStream: InputStream? = null
    private val executor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    var onStateChange: ((BtState, String?) -> Unit)? = null
    var onDataReceived: ((ByteArray) -> Unit)? = null

    private var state: BtState = BtState.DISCONNECTED

    /**
     * Único embudo de cambio de estado: actualiza el campo interno Y notifica a Flutter.
     * Nunca llamar a onStateChange directamente — si no, el campo `state` se queda
     * desincronizado y connect() rechaza reconexiones para siempre.
     */
    private fun updateState(value: BtState, error: String? = null) {
        state = value
        mainHandler.post { onStateChange?.invoke(value, error) }
    }

    fun connect(macAddress: String = BODYCAM_MAC) {
        if (state == BtState.CONNECTING || state == BtState.CONNECTED) return
        updateState(BtState.CONNECTING)

        executor.execute {
            try {
                Log.d(TAG, "Conectando a $macAddress…")
                val device: BluetoothDevice = adapter?.getRemoteDevice(macAddress)
                    ?: run {
                        updateState(BtState.ERROR, "Bluetooth no disponible")
                        return@execute
                    }

                adapter.cancelDiscovery()

                val s = createSocket(device)
                Log.d(TAG, "Socket creado, conectando RFCOMM…")
                s.connect()
                socket = s
                outputStream = s.outputStream
                inputStream = s.inputStream
                Log.d(TAG, "Conectado OK")
                updateState(BtState.CONNECTED)
                startReading()
            } catch (e: SecurityException) {
                Log.e(TAG, "Permiso BLUETOOTH_CONNECT denegado: ${e.message}")
                closeQuietly()
                updateState(BtState.ERROR, "Permiso BT denegado — otorgar en Ajustes")
            } catch (e: IOException) {
                Log.e(TAG, "Error conexión BT: ${e.message}")
                closeQuietly()
                updateState(BtState.ERROR, e.message)
            }
        }
    }

    fun disconnect() {
        closeQuietly()
        updateState(BtState.DISCONNECTED)
    }

    fun send(data: ByteArray): Boolean {
        return try {
            outputStream?.write(data)
            outputStream?.flush()
            true
        } catch (e: IOException) {
            disconnect()
            false
        }
    }

    fun send(text: String) = send(text.toByteArray(Charsets.UTF_8))

    // Comandos — protocolo definido en Protocol.kt del BodyCamServer
    fun startRecording() = send("REC_START\n")
    fun stopRecording()  = send("REC_STOP\n")
    fun takePhoto()      = send("PHOTO\n")
    fun ping()           = send("PING\n")
    fun status()         = send("STATUS\n")
    fun irOn()           = send("IR_ON\n")
    fun irOff()          = send("IR_OFF\n")
    fun setLed(v: Int)   = send("LED:$v\n")
    fun gpsOn()          = send("GPS_ON\n")
    fun gpsOff()         = send("GPS_OFF\n")

    fun isConnected(): Boolean = state == BtState.CONNECTED

    private fun createSocket(device: BluetoothDevice): BluetoothSocket {
        return try {
            Log.d(TAG, "Trying insecure RFCOMM with FALCON_UUID via SDP…")
            device.createInsecureRfcommSocketToServiceRecord(FALCON_UUID)
        } catch (e: Exception) {
            Log.w(TAG, "SDP failed, fallback to channel 1: ${e.message}")
            try {
                val m = device.javaClass.getMethod("createInsecureRfcommSocket", Int::class.javaPrimitiveType)
                m.invoke(device, 1) as BluetoothSocket
            } catch (ite: java.lang.reflect.InvocationTargetException) {
                throw IOException("createInsecureRfcommSocket failed: ${ite.cause?.message}", ite.cause)
            }
        }
    }

    private fun startReading() {
        executor.execute {
            val buffer = ByteArray(1024)
            while (state == BtState.CONNECTED) {
                try {
                    val bytes = inputStream?.read(buffer) ?: break
                    if (bytes > 0) {
                        val data = buffer.copyOf(bytes)
                        mainHandler.post { onDataReceived?.invoke(data) }
                    }
                } catch (e: IOException) {
                    if (state == BtState.CONNECTED) {
                        closeQuietly()
                        // updateState actualiza el campo `state` -> connect() podrá reconectar.
                        updateState(BtState.ERROR, "Conexión perdida")
                    }
                    break
                }
            }
        }
    }

    private fun closeQuietly() {
        try { outputStream?.close() } catch (_: IOException) {}
        try { inputStream?.close() } catch (_: IOException) {}
        try { socket?.close() } catch (_: IOException) {}
        socket = null
        outputStream = null
        inputStream = null
    }
}
