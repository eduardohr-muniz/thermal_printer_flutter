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

private const val TAG = "THERMAL_PRINTER_FLUTTER"
private const val SPP_UUID = "00001101-0000-1000-8000-00805F9B34FB"
private const val BLUETOOTH_PERMISSION_REQUEST_CODE = 1
private const val BLUETOOTH_ENABLE_REQUEST_CODE = 2

/// Canonical string for the bluetooth printer type returned to Dart.
private const val PRINTER_TYPE_BLUETOOTH = "bluetooth"

/// Accepts both the current "bluetooth" and legacy "bluethoot" typo.
private fun String.isBluetoothType(): Boolean =
    equals("bluetooth", ignoreCase = true) || equals("bluethoot", ignoreCase = true)

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

/** Flutter plugin for thermal printer communication over Bluetooth SPP on Android. */
class ThermalPrinterFlutterPlugin :
    FlutterPlugin,
    MethodCallHandler,
    ActivityAware,
    PluginRegistry.RequestPermissionsResultListener,
    PluginRegistry.ActivityResultListener {

    private lateinit var context: Context
    private lateinit var channel: MethodChannel

    private var bluetoothSocket: BluetoothSocket? = null
    private var outputStream: OutputStream? = null
    private var activity: Activity? = null

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
        closeConnection()
    }

    // ── MethodCallHandler ──────────────────────────────────────────────────────

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "getPlatformVersion" -> result.success("Android ${Build.VERSION.RELEASE}")
            "checkBluetoothPermissions" -> checkBluetoothPermissions(result)
            "isBluetoothEnabled" -> result.success(bluetoothAdapter()?.isEnabled ?: false)
            "enableBluetooth" -> enableBluetooth(result)
            "getPrinters" -> handleGetPrinters(call, result)
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

    private fun handleGetPrinters(call: MethodCall, result: Result) {
        val printerType = (call.arguments as? Map<*, *>)?.get("printerType") as? String
        if (printerType != null && !printerType.isBluetoothType()) {
            // USB / network not handled on Android via this path
            result.success(emptyList<Map<String, Any>>())
            return
        }
        if (!checkBluetoothPermission()) {
            result.error("PERMISSION_DENIED", "Bluetooth permission not granted", null)
            return
        }
        result.success(buildPairedDeviceMaps())
    }

    private fun handlePairedBluetooths(result: Result) {
        if (!checkBluetoothPermission()) {
            result.error("PERMISSION_DENIED", "Bluetooth permission not granted", null)
            return
        }
        result.success(buildPairedDeviceMaps())
    }

    private fun handleConnect(call: MethodCall, result: Result) {
        if (!checkBluetoothPermission()) {
            result.error("PERMISSION_DENIED", "Bluetooth permission not granted", null)
            return
        }
        val macAddress = call.arguments as? String
        if (macAddress.isNullOrBlank()) {
            result.error("INVALID_ARGUMENT", "MAC address is required", null)
            return
        }
        connectToDevice(macAddress, result)
    }

    private fun handleWriteBytes(call: MethodCall, result: Result) {
        if (!checkBluetoothPermission()) {
            result.error("PERMISSION_DENIED", "Bluetooth permission not granted", null)
            return
        }
        val bytes = decodeBytes(call.arguments)
        if (bytes == null) {
            result.error("INVALID_ARGUMENT", "Bytes argument must be Uint8List or List<Int>", null)
            return
        }
        writeBytes(bytes, result)
    }

    private fun handleDisconnect(result: Result) {
        closeConnection()
        result.success(true)
    }

    private fun handleIsConnected(call: MethodCall, result: Result) {
        val macAddress = call.arguments as? String
        if (macAddress.isNullOrBlank()) {
            result.error("INVALID_ARGUMENT", "MAC address is required", null)
            return
        }
        result.success(bluetoothSocket?.isConnected == true && outputStream != null)
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
        "address" to device.address,
        "type" to PRINTER_TYPE_BLUETOOTH
    )

    private fun connectToDevice(macAddress: String, result: Result) {
        val adapter = bluetoothAdapter()
        if (adapter == null || !adapter.isEnabled) {
            result.error("BLUETOOTH_DISABLED", "Bluetooth is not enabled", null)
            return
        }

        closeConnection()

        try {
            val device = adapter.getRemoteDevice(macAddress)
            adapter.cancelDiscovery()
            val socket = device.createRfcommSocketToServiceRecord(UUID.fromString(SPP_UUID))
            socket.connect()
            bluetoothSocket = socket
            outputStream = socket.outputStream
            result.success(true)
        } catch (e: IOException) {
            Log.e(TAG, "Connection failed: ${e.message}")
            closeConnection()
            result.error("CONNECTION_ERROR", e.message ?: "IO error during connect", null)
        } catch (e: IllegalArgumentException) {
            Log.e(TAG, "Invalid MAC address: $macAddress")
            result.error("INVALID_ARGUMENT", "Invalid MAC address: $macAddress", null)
        }
    }

    private fun writeBytes(bytes: ByteArray, result: Result) {
        val stream = outputStream
        if (stream == null) {
            result.error("NOT_CONNECTED", "Not connected to any device", null)
            return
        }
        try {
            stream.write(bytes)
            stream.flush()
            result.success(true)
        } catch (e: IOException) {
            Log.e(TAG, "Write failed: ${e.message}")
            closeConnection()
            result.error("WRITE_ERROR", e.message ?: "IO error during write", null)
        }
    }

    /// Closes the output stream and socket safely, clearing both references.
    private fun closeConnection() {
        try {
            outputStream?.close()
        } catch (e: IOException) {
            Log.w(TAG, "Error closing output stream: ${e.message}")
        } finally {
            outputStream = null
        }
        try {
            bluetoothSocket?.close()
        } catch (e: IOException) {
            Log.w(TAG, "Error closing socket: ${e.message}")
        } finally {
            bluetoothSocket = null
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
