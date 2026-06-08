package com.example.thermal_printer_flutter

import android.Manifest
import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothSocket
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.plugin.common.PluginRegistry
import java.io.IOException
import java.io.OutputStream
import java.util.UUID
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

private const val TAG = "THERMAL_PRINTER_FLUTTER"
private val SPP_UUID: UUID = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")
private const val BLUETOOTH_PERMISSION_REQUEST_CODE = 1
private const val BLUETOOTH_ENABLE_REQUEST_CODE = 2

/// Canonical string for the bluetooth printer type returned to Dart.
private const val PRINTER_TYPE_BLUETOOTH = "bluetooth"

/// Decodes bytes arriving from Dart's Uint8List (ByteArray) or legacy List<Int>.
/// Returns null if the argument is neither.
internal fun decodeBytes(arguments: Any?): ByteArray? = when (arguments) {
    is ByteArray -> arguments
    is List<*> -> {
        val ints = arguments.filterIsInstance<Int>()
        if (ints.size == arguments.size) ints.map { it.toByte() }.toByteArray() else null
    }
    else -> null
}

/**
 * Flutter plugin for thermal printer communication over Bluetooth SPP on Android.
 *
 * Threading model (the reason for this rewrite): every blocking Bluetooth IO —
 * connect, write and disconnect — runs on a single background executor, never on
 * the platform/UI thread. Results are posted back to the main thread via
 * [MainThreadResult]. The previous implementation connected and wrote on the
 * platform thread, freezing the Flutter UI for the whole transmission (the
 * perceived "slow" printing, especially with raster images).
 *
 * Because all access to [connection] is serialized through [ioExecutor], writes
 * never interleave and there are no socket races.
 */
class ThermalPrinterFlutterPlugin :
    FlutterPlugin,
    MethodCallHandler,
    ActivityAware,
    PluginRegistry.RequestPermissionsResultListener,
    PluginRegistry.ActivityResultListener {

    private lateinit var context: Context
    private lateinit var channel: MethodChannel

    private var activity: Activity? = null

    /// Single live connection. Written/read only from [ioExecutor]; marked
    /// volatile so the cheap `isConnected` read on the platform thread is safe.
    @Volatile
    private var connection: BluetoothConnection? = null

    /// Serializes all blocking Bluetooth IO off the platform thread.
    private val ioExecutor: ExecutorService = Executors.newSingleThreadExecutor()

    /// Lazy so constructing the plugin in a plain JVM unit test (no Android
    /// Looper) doesn't touch `Looper.getMainLooper()`.
    private val mainHandler by lazy { Handler(Looper.getMainLooper()) }

    /// Pending result for async permission request (answered exactly once).
    private var pendingPermissionResult: Result? = null

    /// Pending result for async Bluetooth-enable request (answered exactly once).
    private var pendingBluetoothEnableResult: Result? = null

    // ── FlutterPlugin ──────────────────────────────────────────────────────────

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "thermal_printer_flutter")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        ioExecutor.execute { closeConnectionInternal() }
        ioExecutor.shutdown()
    }

    // ── MethodCallHandler ──────────────────────────────────────────────────────

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "getPlatformVersion" -> result.success("Android ${Build.VERSION.RELEASE}")
            "checkBluetoothPermissions" -> checkBluetoothPermissions(result)
            "isBluetoothEnabled" -> result.success(bluetoothAdapter()?.isEnabled ?: false)
            "enableBluetooth" -> enableBluetooth(result)
            "pairedbluetooths" -> handlePairedBluetooths(result)
            "usbprinters" -> result.success(emptyList<Map<String, Any>>())
            "connect" -> handleConnect(call, result)
            "writebytes" -> handleWriteBytes(call, result)
            "disconnect" -> handleDisconnect(result)
            "isConnected" -> handleIsConnected(call, result)
            else -> result.notImplemented()
        }
    }

    // ── Handler helpers ────────────────────────────────────────────────────────

    private fun handlePairedBluetooths(result: Result) {
        if (!checkBluetoothPermission()) {
            result.error("PERMISSION_DENIED", "Bluetooth permission not granted", null)
            return
        }
        result.success(buildPairedDeviceMaps())
    }

    private fun handleConnect(call: MethodCall, rawResult: Result) {
        if (!checkBluetoothPermission()) {
            rawResult.error("PERMISSION_DENIED", "Bluetooth permission not granted", null)
            return
        }
        val macAddress = call.arguments as? String
        if (macAddress.isNullOrBlank()) {
            rawResult.error("INVALID_ARGUMENT", "MAC address is required", null)
            return
        }
        val adapter = bluetoothAdapter()
        if (adapter == null || !adapter.isEnabled) {
            rawResult.error("BLUETOOTH_DISABLED", "Bluetooth is not enabled", null)
            return
        }

        val result = MainThreadResult(rawResult)
        ioExecutor.execute {
            // Drop any previous connection before opening a new one.
            closeConnectionInternal()
            try {
                val device = adapter.getRemoteDevice(macAddress)
                // Discovery is heavy and slows down / breaks an active connect.
                adapter.cancelDiscovery()
                val socket = device.createRfcommSocketToServiceRecord(SPP_UUID)
                socket.connect()
                connection = BluetoothConnection(socket)
                result.success(true)
            } catch (e: IllegalArgumentException) {
                Log.e(TAG, "Invalid MAC address: $macAddress")
                closeConnectionInternal()
                result.error("INVALID_ARGUMENT", "Invalid MAC address: $macAddress", null)
            } catch (e: IOException) {
                Log.e(TAG, "Connection failed: ${e.message}")
                closeConnectionInternal()
                result.error("CONNECTION_ERROR", e.message ?: "IO error during connect", null)
            } catch (e: SecurityException) {
                Log.e(TAG, "Missing Bluetooth permission: ${e.message}")
                closeConnectionInternal()
                result.error("PERMISSION_DENIED", e.message ?: "Bluetooth permission denied", null)
            }
        }
    }

    private fun handleWriteBytes(call: MethodCall, rawResult: Result) {
        if (!checkBluetoothPermission()) {
            rawResult.error("PERMISSION_DENIED", "Bluetooth permission not granted", null)
            return
        }
        val bytes = decodeBytes(call.arguments)
        if (bytes == null) {
            rawResult.error("INVALID_ARGUMENT", "Bytes argument must be Uint8List or List<Int>", null)
            return
        }
        if (connection == null) {
            rawResult.error("NOT_CONNECTED", "Not connected to any device", null)
            return
        }

        val result = MainThreadResult(rawResult)
        ioExecutor.execute {
            val conn = connection
            if (conn == null) {
                result.error("NOT_CONNECTED", "Not connected to any device", null)
                return@execute
            }
            try {
                conn.write(bytes)
                result.success(true)
            } catch (e: IOException) {
                Log.e(TAG, "Write failed: ${e.message}")
                closeConnectionInternal()
                result.error("WRITE_ERROR", e.message ?: "IO error during write", null)
            }
        }
    }

    private fun handleDisconnect(rawResult: Result) {
        val result = MainThreadResult(rawResult)
        ioExecutor.execute {
            closeConnectionInternal()
            result.success(true)
        }
    }

    private fun handleIsConnected(call: MethodCall, result: Result) {
        val macAddress = call.arguments as? String
        if (macAddress.isNullOrBlank()) {
            result.error("INVALID_ARGUMENT", "MAC address is required", null)
            return
        }
        result.success(connection?.isConnected == true)
    }

    // ── Bluetooth helpers ──────────────────────────────────────────────────────

    private fun bluetoothAdapter(): BluetoothAdapter? = BluetoothAdapter.getDefaultAdapter()

    /// Returns paired Bluetooth devices as maps with the canonical "bluetooth" type.
    private fun buildPairedDeviceMaps(): List<Map<String, Any>> {
        val adapter = bluetoothAdapter() ?: return emptyList()
        if (!adapter.isEnabled) return emptyList()
        return adapter.bondedDevices.map { device -> deviceToMap(device) }
    }

    private fun deviceToMap(device: BluetoothDevice): Map<String, Any> = mapOf(
        "name" to (device.name ?: ""),
        // Canonical key expected by the Dart layer (matches iOS/macOS).
        "bleAddress" to device.address,
        "type" to PRINTER_TYPE_BLUETOOTH
    )

    /// Closes and clears the active connection. Must run on [ioExecutor].
    private fun closeConnectionInternal() {
        connection?.close()
        connection = null
    }

    /**
     * Holds an open RFCOMM socket and streams bytes to the printer.
     *
     * The write path is byte-for-byte identical to blue_thermal_printer's
     * `ConnectedThread`: the whole payload goes out in a single
     * `outputStream.write(bytes)` on the raw (unbuffered) socket stream — no
     * chunking, no per-write flush. Splitting into chunks forces extra RFCOMM
     * packets and was the source of the slower, non-identical behaviour.
     *
     * The read loop from blue_thermal_printer is intentionally omitted: the
     * Dart API never reads back from the printer.
     */
    private class BluetoothConnection(private val socket: BluetoothSocket) {
        private val output: OutputStream = socket.outputStream

        val isConnected: Boolean
            get() = socket.isConnected

        fun write(bytes: ByteArray) {
            output.write(bytes)
        }

        fun close() {
            try {
                output.flush()
                output.close()
            } catch (e: IOException) {
                Log.w(TAG, "Error closing output stream: ${e.message}")
            }
            try {
                socket.close()
            } catch (e: IOException) {
                Log.w(TAG, "Error closing socket: ${e.message}")
            }
        }
    }

    /// Wraps a [Result] so it is always answered on the main thread, even when
    /// completed from [ioExecutor].
    private inner class MainThreadResult(private val delegate: Result) : Result {
        override fun success(value: Any?) {
            mainHandler.post { delegate.success(value) }
        }

        override fun error(code: String, message: String?, details: Any?) {
            mainHandler.post { delegate.error(code, message, details) }
        }

        override fun notImplemented() {
            mainHandler.post { delegate.notImplemented() }
        }
    }

    // ── Permission handling ────────────────────────────────────────────────────

    private fun checkBluetoothPermission(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            hasPermission(Manifest.permission.BLUETOOTH_CONNECT) &&
                hasPermission(Manifest.permission.BLUETOOTH_SCAN)
        } else {
            true
        }

    private fun hasPermission(permission: String): Boolean =
        ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED

    private fun checkBluetoothPermissions(result: Result) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            requestPermissionsIfNeeded(
                result,
                arrayOf(Manifest.permission.BLUETOOTH_CONNECT, Manifest.permission.BLUETOOTH_SCAN)
            )
        } else {
            requestPermissionsIfNeeded(result, arrayOf(Manifest.permission.ACCESS_FINE_LOCATION))
        }
    }

    private fun requestPermissionsIfNeeded(result: Result, permissions: Array<String>) {
        val allGranted = permissions.all { hasPermission(it) }
        if (allGranted) {
            result.success(true)
            return
        }
        val act = activity
        if (act == null) {
            result.error("ACTIVITY_NOT_AVAILABLE", "Activity not available", null)
            return
        }
        pendingPermissionResult = result
        ActivityCompat.requestPermissions(act, permissions, BLUETOOTH_PERMISSION_REQUEST_CODE)
    }

    private fun enableBluetooth(result: Result) {
        val adapter = bluetoothAdapter()
        if (adapter == null) {
            result.error("BLUETOOTH_NOT_AVAILABLE", "Bluetooth is not available on this device", null)
            return
        }
        if (adapter.isEnabled) {
            result.success(true)
            return
        }
        val act = activity
        if (act == null) {
            result.error("ACTIVITY_NOT_AVAILABLE", "Activity not available", null)
            return
        }
        pendingBluetoothEnableResult = result
        val intent = Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE)
        act.startActivityForResult(intent, BLUETOOTH_ENABLE_REQUEST_CODE)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ): Boolean {
        if (requestCode != BLUETOOTH_PERMISSION_REQUEST_CODE) return false
        val allGranted = grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED }
        pendingPermissionResult?.success(allGranted)
        pendingPermissionResult = null
        return true
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != BLUETOOTH_ENABLE_REQUEST_CODE) return false
        pendingBluetoothEnableResult?.success(resultCode == Activity.RESULT_OK)
        pendingBluetoothEnableResult = null
        return true
    }

    // ── ActivityAware ──────────────────────────────────────────────────────────

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addRequestPermissionsResultListener(this)
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addRequestPermissionsResultListener(this)
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivity() {
        activity = null
    }
}
