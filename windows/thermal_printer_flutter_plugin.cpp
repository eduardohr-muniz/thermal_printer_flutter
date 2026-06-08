// thermal_printer_flutter_plugin.h includes <winsock2.h> first, which must
// precede <windows.h> (pulled in by the headers below) to avoid winsock1
// redefinition errors.
#include "thermal_printer_flutter_plugin.h"

// Windows system headers
#include <ws2bth.h>          // SOCKADDR_BTH, AF_BTH, BTHPROTO_RFCOMM
#include <windows.h>
#include <bluetoothapis.h>   // BluetoothFindFirstDevice / Radio
#include <winspool.h>
#include <VersionHelpers.h>

// Flutter headers
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <flutter/encodable_value.h>

#include <cstdint>
#include <cstdio>
#include <memory>
#include <optional>
#include <sstream>
#include <string>
#include <vector>

namespace thermal_printer_flutter {

// ─────────────────────────────────────────────
// Plugin registration
// ─────────────────────────────────────────────

void ThermalPrinterFlutterPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows *registrar) {
  auto channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), "thermal_printer_flutter",
          &flutter::StandardMethodCodec::GetInstance());

  auto plugin = std::make_unique<ThermalPrinterFlutterPlugin>();

  channel->SetMethodCallHandler(
      [plugin_pointer = plugin.get()](const auto &call, auto result) {
        plugin_pointer->HandleMethodCall(call, std::move(result));
      });

  registrar->AddPlugin(std::move(plugin));
}

// ─────────────────────────────────────────────
// Constructor / destructor
// ─────────────────────────────────────────────

ThermalPrinterFlutterPlugin::ThermalPrinterFlutterPlugin() {}

ThermalPrinterFlutterPlugin::~ThermalPrinterFlutterPlugin() {
  BluetoothDisconnect();
  if (wsa_started_) {
    WSACleanup();
    wsa_started_ = false;
  }
}

// ─────────────────────────────────────────────
// Helper: UTF-8 -> wide string (safe, no raw new[])
// ─────────────────────────────────────────────

// static
std::wstring ThermalPrinterFlutterPlugin::StringToWideString(
    const std::string& utf8) {
  if (utf8.empty()) return std::wstring();

  int needed = MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), -1, nullptr, 0);
  if (needed <= 0) return std::wstring();

  std::wstring wide(static_cast<size_t>(needed), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), -1, &wide[0], needed);

  // MultiByteToWideChar with -1 includes the terminating null in `needed`;
  // std::wstring already owns the storage, so strip the embedded null.
  if (!wide.empty() && wide.back() == L'\0') {
    wide.pop_back();
  }
  return wide;
}

// ─────────────────────────────────────────────
// Helper: wide string -> UTF-8 (free function, used by GetPrinters)
// ─────────────────────────────────────────────

static std::string WideStringToString(LPCWSTR wideStr) {
  if (wideStr == nullptr) return std::string();

  int needed = WideCharToMultiByte(CP_UTF8, 0, wideStr, -1,
                                   nullptr, 0, nullptr, nullptr);
  if (needed <= 0) return std::string();

  std::string result(static_cast<size_t>(needed), '\0');
  WideCharToMultiByte(CP_UTF8, 0, wideStr, -1,
                      &result[0], needed, nullptr, nullptr);

  if (!result.empty() && result.back() == '\0') {
    result.pop_back();
  }
  return result;
}

// ─────────────────────────────────────────────
// Helper: extract byte payload from an EncodableValue.
// Prefers FlutterStandardTypedData (vector<uint8_t>); falls back to
// EncodableList of int32_t for callers that still send List<int>.
// ─────────────────────────────────────────────

// static
std::optional<std::vector<uint8_t>> ThermalPrinterFlutterPlugin::ExtractBytes(
    const flutter::EncodableValue& value) {

  // Primary path: Dart Uint8List -> FlutterStandardTypedData -> vector<uint8_t>
  if (const auto* typed = std::get_if<std::vector<uint8_t>>(&value)) {
    return *typed;
  }

  // Legacy fallback: Dart List<int> -> EncodableList of int32_t
  if (const auto* list = std::get_if<flutter::EncodableList>(&value)) {
    std::vector<uint8_t> bytes;
    bytes.reserve(list->size());
    for (const auto& item : *list) {
      if (const auto* iv = std::get_if<int32_t>(&item)) {
        bytes.push_back(static_cast<uint8_t>(*iv));
      } else {
        // Malformed list element — abort
        return std::nullopt;
      }
    }
    return bytes;
  }

  return std::nullopt;
}

// ─────────────────────────────────────────────
// GetPrinters — enumerate local + connected printers
// ─────────────────────────────────────────────

std::vector<std::string> ThermalPrinterFlutterPlugin::GetPrinters() {
  std::vector<std::string> printers;
  DWORD needed = 0;
  DWORD returned = 0;

  // First call: determine required buffer size
  EnumPrinters(PRINTER_ENUM_LOCAL | PRINTER_ENUM_CONNECTIONS,
               NULL, 2, NULL, 0, &needed, &returned);

  if (needed == 0) return printers;

  std::vector<BYTE> buffer(needed);
  if (!EnumPrinters(PRINTER_ENUM_LOCAL | PRINTER_ENUM_CONNECTIONS,
                    NULL, 2, buffer.data(), needed, &needed, &returned)) {
    return printers;
  }

  auto* info = reinterpret_cast<PRINTER_INFO_2*>(buffer.data());
  printers.reserve(returned);
  for (DWORD i = 0; i < returned; ++i) {
    printers.push_back(WideStringToString(info[i].pPrinterName));
  }
  return printers;
}

// ─────────────────────────────────────────────
// PrintBytes — send raw ESC/POS bytes to the Windows spooler
//
// Flow:
//   1. OpenPrinter
//   2. StartDocPrinter  (datatype = L"RAW" — prevents driver re-rendering)
//   3. StartPagePrinter
//   4. WritePrinter in a loop (handles partial writes)
//   5. EndPagePrinter / EndDocPrinter / ClosePrinter
//
// Every Win32 call is checked; on failure we clean up and return false.
// ─────────────────────────────────────────────

// Opens the named printer with a DEVMODE that forces a single copy.
//
// The Windows print processor (winprint) honours the driver's "Copies"
// setting even for RAW jobs, so a driver configured with copies > 1 makes a
// single RAW submission come out multiple times. Forcing dmCopies = 1 makes
// the byte stream the single source of truth for how many receipts print
// (copies are repeated in the payload by the Dart layer instead).
//
// On success sets *outHandle and returns true. Falls back to a plain
// OpenPrinter when the DEVMODE cannot be obtained, so behaviour degrades
// gracefully rather than failing the print.
static bool OpenPrinterForRawSingleCopy(const std::wstring& wName,
                                        HANDLE* outHandle) {
  *outHandle = nullptr;

  HANDLE hProbe = nullptr;
  if (!OpenPrinter(const_cast<LPWSTR>(wName.c_str()), &hProbe, nullptr)) {
    return false;
  }

  // Determine the DEVMODE buffer size for this driver.
  LONG needed = DocumentProperties(nullptr, hProbe,
                                   const_cast<LPWSTR>(wName.c_str()),
                                   nullptr, nullptr, 0);
  if (needed <= 0) {
    // Driver exposes no DEVMODE — use the plain handle as-is.
    *outHandle = hProbe;
    return true;
  }

  std::vector<BYTE> devmodeBuf(static_cast<size_t>(needed));
  DEVMODE* pDevMode = reinterpret_cast<DEVMODE*>(devmodeBuf.data());

  // Load the driver defaults, then override the copy count.
  if (DocumentProperties(nullptr, hProbe,
                         const_cast<LPWSTR>(wName.c_str()),
                         pDevMode, nullptr, DM_OUT_BUFFER) != IDOK) {
    *outHandle = hProbe;
    return true;
  }

  pDevMode->dmFields |= DM_COPIES;
  pDevMode->dmCopies = 1;
  DocumentProperties(nullptr, hProbe,
                     const_cast<LPWSTR>(wName.c_str()),
                     pDevMode, pDevMode, DM_IN_BUFFER | DM_OUT_BUFFER);

  ClosePrinter(hProbe);

  // Reopen bound to our DEVMODE. OpenPrinter copies the DEVMODE internally,
  // so it is safe to let devmodeBuf go out of scope afterwards.
  PRINTER_DEFAULTS defaults{};
  defaults.pDatatype     = nullptr;
  defaults.pDevMode      = pDevMode;
  defaults.DesiredAccess = PRINTER_ACCESS_USE;

  HANDLE hPrinter = nullptr;
  if (!OpenPrinter(const_cast<LPWSTR>(wName.c_str()), &hPrinter, &defaults)) {
    // Fall back to a plain open if the DEVMODE-bound open is rejected.
    return OpenPrinter(const_cast<LPWSTR>(wName.c_str()),
                       outHandle, nullptr) != 0;
  }
  *outHandle = hPrinter;
  return true;
}

bool ThermalPrinterFlutterPlugin::PrintBytes(const std::vector<uint8_t>& bytes,
                                             const std::string& printerName) {
  if (bytes.empty()) return false;

  const std::wstring wPrinterName = StringToWideString(printerName);
  const std::wstring wDocName     = L"ESC/POS Print Job";

  HANDLE hPrinter = nullptr;
  if (!OpenPrinterForRawSingleCopy(wPrinterName, &hPrinter) ||
      hPrinter == nullptr) {
    return false;
  }

  // RAII-style guard: always close the printer handle on scope exit. If the
  // job did not complete fully, delete the spool job so the printer never
  // receives a truncated ESC/POS stream (a partial stream can leave a thermal
  // printer mid-command and "running away").
  struct PrinterGuard {
    HANDLE h;
    DWORD  jobId       = 0;
    bool   docStarted  = false;
    bool   pageStarted = false;
    bool   succeeded   = false;
    ~PrinterGuard() {
      if (pageStarted) EndPagePrinter(h);
      if (docStarted)  EndDocPrinter(h);
      if (!succeeded && jobId != 0) {
        SetJob(h, jobId, 0, nullptr, JOB_CONTROL_DELETE);
      }
      ClosePrinter(h);
    }
  } guard{ hPrinter };

  // Force RAW datatype so the driver passes bytes straight through
  // without re-rendering, which is the root cause of "prints multiple copies".
  DOC_INFO_1 docInfo{};
  docInfo.pDocName    = const_cast<LPWSTR>(wDocName.c_str());
  docInfo.pOutputFile = nullptr;
  docInfo.pDatatype   = const_cast<LPWSTR>(L"RAW");

  DWORD jobId = StartDocPrinter(hPrinter, 1,
                                reinterpret_cast<LPBYTE>(&docInfo));
  if (jobId == 0) return false;
  guard.docStarted = true;
  guard.jobId      = jobId;

  if (!StartPagePrinter(hPrinter)) return false;
  guard.pageStarted = true;

  // Write in a loop to handle partial writes (WritePrinter may write fewer
  // bytes than requested in a single call).
  const BYTE* src       = bytes.data();
  DWORD       remaining = static_cast<DWORD>(bytes.size());

  while (remaining > 0) {
    DWORD written = 0;
    // WritePrinter signature: (HANDLE, LPVOID, DWORD, LPDWORD)
    if (!WritePrinter(hPrinter,
                      const_cast<LPVOID>(static_cast<const void*>(src)),
                      remaining,
                      &written)
        || written == 0) {
      // Partial or failed write — abort; guard destructor deletes the job.
      return false;
    }
    src       += written;
    remaining -= written;
  }

  // Mark success so the guard finishes (rather than deletes) the job.
  guard.succeeded = true;
  return true;
}

void ThermalPrinterFlutterPlugin::PopulateDefaultStatus(flutter::EncodableMap& statusMap) const {
  statusMap[flutter::EncodableValue("hasStatus")] = flutter::EncodableValue(false);
  statusMap[flutter::EncodableValue("hasError")] = flutter::EncodableValue(false);
  statusMap[flutter::EncodableValue("isPaperOut")] = flutter::EncodableValue(false);
  statusMap[flutter::EncodableValue("isPaperJam")] = flutter::EncodableValue(false);
  statusMap[flutter::EncodableValue("isDoorOpen")] = flutter::EncodableValue(false);
  statusMap[flutter::EncodableValue("isOffline")] = flutter::EncodableValue(false);
  statusMap[flutter::EncodableValue("isPaperLow")] = flutter::EncodableValue(false);
  statusMap[flutter::EncodableValue("needsUserAction")] = flutter::EncodableValue(false);
  statusMap[flutter::EncodableValue("rawStatus")] = flutter::EncodableValue(0);
  statusMap[flutter::EncodableValue("description")] = flutter::EncodableValue("");
}

flutter::EncodableMap ThermalPrinterFlutterPlugin::BuildPrinterStatusMap(const std::string& printerName) {
  flutter::EncodableMap statusMap;
  PopulateDefaultStatus(statusMap);

  if (printerName.empty()) {
    statusMap[flutter::EncodableValue("description")] = flutter::EncodableValue("Printer name cannot be empty.");
    return statusMap;
  }

  int wchars_num = MultiByteToWideChar(CP_UTF8, 0, printerName.c_str(), -1, NULL, 0);
  if (wchars_num == 0) {
    statusMap[flutter::EncodableValue("description")] = flutter::EncodableValue("Unable to convert printer name to UTF-16.");
    return statusMap;
  }

  std::wstring wname(wchars_num, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, printerName.c_str(), -1, wname.data(), wchars_num);

  HANDLE hPrinter = NULL;
  if (!OpenPrinter(wname.data(), &hPrinter, NULL)) {
    DWORD error = GetLastError();
    std::ostringstream errorStream;
    errorStream << "Unable to open printer. Error: " << error;
    statusMap[flutter::EncodableValue("description")] = flutter::EncodableValue(errorStream.str());
    return statusMap;
  }

  DWORD needed = 0;
  GetPrinter(hPrinter, 2, NULL, 0, &needed);
  if (needed == 0) {
    ClosePrinter(hPrinter);
    statusMap[flutter::EncodableValue("description")] = flutter::EncodableValue("Printer status is unavailable.");
    return statusMap;
  }

  std::vector<BYTE> buffer(needed);
  if (!GetPrinter(hPrinter, 2, buffer.data(), needed, &needed)) {
    DWORD error = GetLastError();
    ClosePrinter(hPrinter);
    std::ostringstream errorStream;
    errorStream << "Failed to query printer information. Error: " << error;
    statusMap[flutter::EncodableValue("description")] = flutter::EncodableValue(errorStream.str());
    return statusMap;
  }

  PRINTER_INFO_2* printerInfo = reinterpret_cast<PRINTER_INFO_2*>(buffer.data());
  DWORD status = printerInfo->Status;
  DWORD attributes = printerInfo->Attributes;
  ClosePrinter(hPrinter);

  statusMap[flutter::EncodableValue("rawStatus")] = flutter::EncodableValue(static_cast<int>(status));
  statusMap[flutter::EncodableValue("hasStatus")] = flutter::EncodableValue(true);

  auto hasFlag = [&](DWORD flag) -> bool {
    return (status & flag) != 0;
  };

  bool isPaperOut = hasFlag(PRINTER_STATUS_PAPER_OUT);
  bool isPaperJam = hasFlag(PRINTER_STATUS_PAPER_JAM);
  bool isDoorOpen = hasFlag(PRINTER_STATUS_DOOR_OPEN);
#ifdef PRINTER_STATUS_PAPER_LOW
  bool isPaperLow = hasFlag(PRINTER_STATUS_PAPER_LOW);
#else
  bool isPaperLow = false;
#endif
  bool isOffline = hasFlag(PRINTER_STATUS_OFFLINE) || ((attributes & PRINTER_ATTRIBUTE_WORK_OFFLINE) != 0);
  bool needsUserAction = hasFlag(PRINTER_STATUS_USER_INTERVENTION) || hasFlag(PRINTER_STATUS_OUT_OF_MEMORY);
  bool hasError = hasFlag(PRINTER_STATUS_ERROR) || isPaperOut || isPaperJam || isDoorOpen || needsUserAction;

  statusMap[flutter::EncodableValue("hasError")] = flutter::EncodableValue(hasError);
  statusMap[flutter::EncodableValue("isPaperOut")] = flutter::EncodableValue(isPaperOut);
  statusMap[flutter::EncodableValue("isPaperJam")] = flutter::EncodableValue(isPaperJam);
  statusMap[flutter::EncodableValue("isDoorOpen")] = flutter::EncodableValue(isDoorOpen);
  statusMap[flutter::EncodableValue("isOffline")] = flutter::EncodableValue(isOffline);
  statusMap[flutter::EncodableValue("isPaperLow")] = flutter::EncodableValue(isPaperLow || isPaperOut);
  statusMap[flutter::EncodableValue("needsUserAction")] = flutter::EncodableValue(needsUserAction);

  std::ostringstream description;
  if (hasError) {
    if (isPaperOut) description << "Out of paper. ";
    if (isPaperJam) description << "Paper jam. ";
    if (isDoorOpen) description << "Cover open. ";
    if (needsUserAction) description << "User intervention required. ";
  }

  if (isOffline && !isPaperOut && !isDoorOpen) {
    description << "Printer offline. ";
  }

  if (description.str().empty()) {
    description << "Printer ready.";
  }

  statusMap[flutter::EncodableValue("description")] = flutter::EncodableValue(description.str());
  return statusMap;
}

// ─────────────────────────────────────────────
// Bluetooth (RFCOMM / SPP over Winsock)
//
// Mirrors the Android path: enumerate paired devices, connect to the SPP
// service by address, stream raw ESC/POS bytes over an RFCOMM socket. One
// connection at a time; all calls run synchronously on the platform thread
// (Flutter Windows requires MethodResult to be answered there).
// ─────────────────────────────────────────────

bool ThermalPrinterFlutterPlugin::EnsureWinsock() {
  if (wsa_started_) return true;
  WSADATA wsaData;
  if (WSAStartup(MAKEWORD(2, 2), &wsaData) != 0) {
    return false;
  }
  wsa_started_ = true;
  return true;
}

// static
std::string ThermalPrinterFlutterPlugin::FormatBluetoothAddress(
    unsigned long long addr) {
  // The address occupies the low 48 bits, most-significant byte first.
  unsigned int b[6];
  for (int i = 0; i < 6; ++i) {
    b[i] = static_cast<unsigned int>((addr >> (8 * (5 - i))) & 0xFF);
  }
  char buf[18];
  std::snprintf(buf, sizeof(buf), "%02X:%02X:%02X:%02X:%02X:%02X",
                b[0], b[1], b[2], b[3], b[4], b[5]);
  return std::string(buf);
}

// static
std::optional<unsigned long long>
ThermalPrinterFlutterPlugin::ParseBluetoothAddress(const std::string& mac) {
  std::string hex;
  hex.reserve(12);
  for (char c : mac) {
    if (c == ':' || c == '-' || c == ' ') continue;
    hex.push_back(c);
  }
  if (hex.size() != 12) return std::nullopt;

  unsigned long long addr = 0;
  for (char c : hex) {
    int v;
    if (c >= '0' && c <= '9') v = c - '0';
    else if (c >= 'a' && c <= 'f') v = c - 'a' + 10;
    else if (c >= 'A' && c <= 'F') v = c - 'A' + 10;
    else return std::nullopt;
    addr = (addr << 4) | static_cast<unsigned long long>(v);
  }
  return addr;
}

bool ThermalPrinterFlutterPlugin::IsBluetoothRadioPresent() const {
  BLUETOOTH_FIND_RADIO_PARAMS params{};
  params.dwSize = sizeof(params);
  HANDLE hRadio = nullptr;
  HBLUETOOTH_RADIO_FIND hFind = BluetoothFindFirstRadio(&params, &hRadio);
  if (hFind == nullptr) return false;
  CloseHandle(hRadio);
  BluetoothFindRadioClose(hFind);
  return true;
}

flutter::EncodableList
ThermalPrinterFlutterPlugin::GetPairedBluetoothDevices() {
  flutter::EncodableList list;

  BLUETOOTH_DEVICE_SEARCH_PARAMS params{};
  params.dwSize               = sizeof(params);
  params.fReturnAuthenticated = TRUE;   // paired devices
  params.fReturnRemembered    = TRUE;
  params.fReturnConnected     = TRUE;
  params.fReturnUnknown       = FALSE;
  params.fIssueInquiry        = FALSE;  // no active scan — only known devices
  params.cTimeoutMultiplier   = 0;
  params.hRadio               = nullptr;  // search all radios

  BLUETOOTH_DEVICE_INFO info{};
  info.dwSize = sizeof(info);

  HBLUETOOTH_DEVICE_FIND hFind = BluetoothFindFirstDevice(&params, &info);
  if (hFind == nullptr) return list;

  do {
    flutter::EncodableMap entry;
    entry[flutter::EncodableValue("name")] =
        flutter::EncodableValue(WideStringToString(info.szName));
    entry[flutter::EncodableValue("bleAddress")] =
        flutter::EncodableValue(FormatBluetoothAddress(info.Address.ullLong));
    entry[flutter::EncodableValue("type")] =
        flutter::EncodableValue(std::string("bluetooth"));
    entry[flutter::EncodableValue("isConnected")] =
        flutter::EncodableValue(info.fConnected == TRUE);
    list.push_back(flutter::EncodableValue(entry));
  } while (BluetoothFindNextDevice(hFind, &info));

  BluetoothFindDeviceClose(hFind);
  return list;
}

// Opens one RFCOMM socket and tries to connect. When [useServiceClass] is true
// the channel is resolved via SDP from the SPP service class; otherwise it
// connects to the explicit RFCOMM [channel]. Returns the connected socket or
// INVALID_SOCKET (with *outErr set to WSAGetLastError()).
static SOCKET TryRfcommConnect(unsigned long long btAddr,
                               bool useServiceClass,
                               int channel,
                               int* outErr) {
  SOCKET s = socket(AF_BTH, SOCK_STREAM, BTHPROTO_RFCOMM);
  if (s == INVALID_SOCKET) {
    *outErr = WSAGetLastError();
    return INVALID_SOCKET;
  }

  SOCKADDR_BTH sa{};
  sa.addressFamily = AF_BTH;
  sa.btAddr        = static_cast<BTH_ADDR>(btAddr);
  if (useServiceClass) {
    // SPP service class UUID 00001101-0000-1000-8000-00805F9B34FB — Windows
    // resolves the RFCOMM channel via SDP (like Android's
    // createRfcommSocketToServiceRecord). Some printers don't publish it.
    sa.serviceClassId = GUID{0x00001101, 0x0000, 0x1000,
                             {0x80, 0x00, 0x00, 0x80, 0x5F, 0x9B, 0x34, 0xFB}};
    sa.port = 0;
  } else {
    sa.port = static_cast<ULONG>(channel);
  }

  if (connect(s, reinterpret_cast<SOCKADDR*>(&sa),
              static_cast<int>(sizeof(sa))) != 0) {
    *outErr = WSAGetLastError();
    closesocket(s);
    return INVALID_SOCKET;
  }
  return s;
}

bool ThermalPrinterFlutterPlugin::BluetoothConnect(const std::string& address) {
  last_bt_error_ = 0;
  if (!EnsureWinsock()) {
    last_bt_error_ = WSAGetLastError();
    return false;
  }

  auto addrOpt = ParseBluetoothAddress(address);
  if (!addrOpt.has_value()) {
    last_bt_error_ = -1;  // bad address string
    return false;
  }
  const unsigned long long btAddr = addrOpt.value();

  BluetoothDisconnect();  // one connection at a time

  int err = 0;
  // First try SDP service-class resolution (works when the printer publishes
  // the SPP record). If that fails (common — e.g. WSAEADDRNOTAVAIL 10049),
  // fall back to scanning the usual RFCOMM channels; ESC/POS printers almost
  // always listen on channel 1. A failed attempt returns quickly.
  SOCKET s = TryRfcommConnect(btAddr, /*useServiceClass=*/true, 0, &err);
  for (int channel = 1; s == INVALID_SOCKET && channel <= 10; ++channel) {
    s = TryRfcommConnect(btAddr, /*useServiceClass=*/false, channel, &err);
  }

  if (s == INVALID_SOCKET) {
    last_bt_error_ = err;
    return false;
  }

  bt_socket_ = s;
  return true;
}

bool ThermalPrinterFlutterPlugin::BluetoothWrite(
    const std::vector<uint8_t>& bytes) {
  if (bt_socket_ == INVALID_SOCKET) return false;
  if (bytes.empty()) return true;

  // Single logical write of the whole payload (send may split internally; the
  // loop only covers partial sends). No artificial chunking — matches Android.
  const char* src = reinterpret_cast<const char*>(bytes.data());
  int remaining   = static_cast<int>(bytes.size());
  while (remaining > 0) {
    int sent = send(bt_socket_, src, remaining, 0);
    if (sent == SOCKET_ERROR || sent == 0) {
      BluetoothDisconnect();
      return false;
    }
    src       += sent;
    remaining -= sent;
  }
  return true;
}

void ThermalPrinterFlutterPlugin::BluetoothDisconnect() {
  if (bt_socket_ != INVALID_SOCKET) {
    shutdown(bt_socket_, SD_BOTH);
    closesocket(bt_socket_);
    bt_socket_ = INVALID_SOCKET;
  }
}

bool ThermalPrinterFlutterPlugin::BluetoothIsConnected() const {
  return bt_socket_ != INVALID_SOCKET;
}

// ─────────────────────────────────────────────
// HandleMethodCall — dispatch Flutter MethodChannel calls
// ─────────────────────────────────────────────

void ThermalPrinterFlutterPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue> &method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {

  const std::string& method = method_call.method_name();

  // ── getPlatformVersion ──────────────────────────────────────────────────
  if (method == "getPlatformVersion") {
    std::ostringstream version;
    version << "Windows ";
    if (IsWindows10OrGreater())    version << "10+";
    else if (IsWindows8OrGreater()) version << "8";
    else if (IsWindows7OrGreater()) version << "7";
    result->Success(flutter::EncodableValue(version.str()));
    return;
  }

  // ── Bluetooth: capability / state ───────────────────────────────────────
  // Windows has no per-app runtime Bluetooth permission, so permissions are
  // always granted; "enabled" maps to "a radio exists".
  if (method == "checkBluetoothPermissions") {
    result->Success(flutter::EncodableValue(true));
    return;
  }
  if (method == "isBluetoothEnabled" || method == "enableBluetooth") {
    result->Success(flutter::EncodableValue(IsBluetoothRadioPresent()));
    return;
  }

  // ── pairedbluetooths ────────────────────────────────────────────────────
  if (method == "pairedbluetooths") {
    result->Success(flutter::EncodableValue(GetPairedBluetoothDevices()));
    return;
  }

  // ── connect (arg: "XX:XX:XX:XX:XX:XX" address string) ───────────────────
  if (method == "connect") {
    const auto* address = std::get_if<std::string>(method_call.arguments());
    if (!address || address->empty()) {
      result->Error("invalid_arguments", "connect requires a Bluetooth address string");
      return;
    }
    if (BluetoothConnect(*address)) {
      result->Success(flutter::EncodableValue(true));
    } else {
      result->Error("connect_failed",
                    "RFCOMM connect failed (WSA error " +
                        std::to_string(last_bt_error_) + ")");
    }
    return;
  }

  // ── disconnect ──────────────────────────────────────────────────────────
  if (method == "disconnect") {
    BluetoothDisconnect();
    result->Success(flutter::EncodableValue(true));
    return;
  }

  // ── isConnected ─────────────────────────────────────────────────────────
  if (method == "isConnected") {
    result->Success(flutter::EncodableValue(BluetoothIsConnected()));
    return;
  }

  // ── usbprinters ────────────────────────────────────────────────────────
  if (method == "usbprinters") {
    flutter::EncodableList list;
    for (const auto& name : GetPrinters()) {
      flutter::EncodableMap entry;
      entry[flutter::EncodableValue("name")]        = flutter::EncodableValue(name);
      entry[flutter::EncodableValue("type")]        = flutter::EncodableValue(std::string("usb"));
      entry[flutter::EncodableValue("isConnected")] = flutter::EncodableValue(true);
      list.push_back(flutter::EncodableValue(entry));
    }
    result->Success(flutter::EncodableValue(list));
    return;
  }

  // ── writebytes ─────────────────────────────────────────────────────────
  // Two wire contracts share this method, distinguished by the argument shape:
  //   • Bluetooth: a bare Uint8List / List<int> → stream to the active RFCOMM
  //     socket (the BluetoothPrinterRepository sends raw bytes, no map).
  //   • USB/spooler: Map {"bytes": Uint8List, "printerName": String}.
  if (method == "writebytes") {
    const flutter::EncodableValue* args_value = method_call.arguments();

    // Bluetooth path: anything that isn't a Map is treated as a raw payload.
    if (args_value != nullptr &&
        !std::holds_alternative<flutter::EncodableMap>(*args_value)) {
      auto bytesOpt = ExtractBytes(*args_value);
      if (!bytesOpt.has_value()) {
        result->Error("invalid_arguments", "bytes must be Uint8List or List<int>");
        return;
      }
      if (BluetoothWrite(bytesOpt.value())) {
        result->Success(flutter::EncodableValue(true));
      } else {
        result->Error("print_failed",
                      "Bluetooth write failed (not connected or link dropped).");
      }
      return;
    }

    const auto* args = std::get_if<flutter::EncodableMap>(args_value);
    if (!args) {
      result->Error("invalid_arguments", "Expected a Map argument for writebytes");
      return;
    }

    const auto bytes_it   = args->find(flutter::EncodableValue("bytes"));
    const auto printer_it = args->find(flutter::EncodableValue("printerName"));

    if (bytes_it == args->end() || printer_it == args->end()) {
      result->Error("invalid_arguments",
                    "writebytes requires 'bytes' and 'printerName'");
      return;
    }

    const auto* printerName = std::get_if<std::string>(&printer_it->second);
    if (!printerName || printerName->empty()) {
      result->Error("invalid_arguments", "printerName must be a non-empty string");
      return;
    }

    auto bytesOpt = ExtractBytes(bytes_it->second);
    if (!bytesOpt.has_value()) {
      result->Error("invalid_arguments",
                    "bytes must be Uint8List or List<int>");
      return;
    }

    const bool ok = PrintBytes(bytesOpt.value(), *printerName);
    if (ok) {
      result->Success(flutter::EncodableValue(true));
    } else {
      result->Error("print_failed",
                    "Failed to send bytes to printer. Check printer name and connectivity.");
    }
    return;
  }

  // ── getPrinterStatus ───────────────────────────────────────────────────
  // Argument may be a Map {"printerName": String} or a bare String.
  if (method == "getPrinterStatus") {
    std::string printerName;
    if (const auto* args = std::get_if<flutter::EncodableMap>(method_call.arguments())) {
      const auto it = args->find(flutter::EncodableValue("printerName"));
      if (it != args->end()) {
        if (const auto* value = std::get_if<std::string>(&it->second)) {
          printerName = *value;
        }
      }
    } else if (const auto* directName = std::get_if<std::string>(method_call.arguments())) {
      printerName = *directName;
    }

    if (printerName.empty()) {
      result->Error("invalid_arguments",
                    "printerName is required for getPrinterStatus");
      return;
    }

    auto statusMap = BuildPrinterStatusMap(printerName);
    result->Success(flutter::EncodableValue(statusMap));
    return;
  }

  // ── not implemented ────────────────────────────────────────────────────
  result->NotImplemented();
}

}  // namespace thermal_printer_flutter
