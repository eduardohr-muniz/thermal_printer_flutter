#include "thermal_printer_flutter_plugin.h"

// Inclusões necessárias para o Windows
#include <windows.h>
#include <winspool.h>
#include <VersionHelpers.h>

// Inclusões do Flutter
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <sstream>
#include <vector>
#include <string>

namespace thermal_printer_flutter {

// =====================================================
// Método original do plugin para registrar o canal
// =====================================================
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

// =====================================================
// Construtor e destrutor padrão
// =====================================================
ThermalPrinterFlutterPlugin::ThermalPrinterFlutterPlugin() {}
ThermalPrinterFlutterPlugin::~ThermalPrinterFlutterPlugin() {}

// =====================================================
// Método auxiliar para converter string wide para string normal
// =====================================================
std::string WideStringToString(LPCWSTR wideStr) {
  if (wideStr == nullptr) return std::string();
  
  int size_needed = WideCharToMultiByte(CP_UTF8, 0, wideStr, -1, nullptr, 0, nullptr, nullptr);
  if (size_needed == 0) return std::string();
  
  std::string result(size_needed, '\0');
  WideCharToMultiByte(CP_UTF8, 0, wideStr, -1, &result[0], size_needed, nullptr, nullptr);
  
  // Remove o caractere nulo final
  if (!result.empty() && result.back() == '\0') {
    result.pop_back();
  }
  
  return result;
}

// =====================================================
// Método para obter lista de impressoras disponíveis
// =====================================================
std::vector<std::string> ThermalPrinterFlutterPlugin::GetPrinters() {
  std::vector<std::string> printers;
  DWORD needed = 0;
  DWORD returned = 0;
  
  // Primeiro chamada para obter o tamanho necessário
  EnumPrinters(PRINTER_ENUM_LOCAL | PRINTER_ENUM_CONNECTIONS, NULL, 2, NULL, 0, &needed, &returned);
  
  if (needed > 0) {
    std::vector<BYTE> buffer(needed);
    if (EnumPrinters(PRINTER_ENUM_LOCAL | PRINTER_ENUM_CONNECTIONS, NULL, 2, buffer.data(), needed, &needed, &returned)) {
      PRINTER_INFO_2* printerInfo = reinterpret_cast<PRINTER_INFO_2*>(buffer.data());
      for (DWORD i = 0; i < returned; i++) {
        printers.push_back(WideStringToString(printerInfo[i].pPrinterName));
      }
    }
  }
  
  return printers;
}

// =====================================================
// Método principal para imprimir bytes na impressora
// Implementação baseada no exemplo do win32
// =====================================================
void ThermalPrinterFlutterPlugin::PrintBytes(const std::vector<uint8_t>& bytes, const std::string& printerName) {
    HANDLE hPrinter;
    DOC_INFO_1 docInfo = { 0 };
    DWORD bytesWritten;

    // Converte o nome da impressora para string wide (Unicode)
    // Necessário porque o Windows usa strings Unicode internamente
    int wchars_num = MultiByteToWideChar(CP_UTF8, 0, printerName.c_str(), -1, NULL, 0);
    wchar_t* wstr = new wchar_t[wchars_num];
    MultiByteToWideChar(CP_UTF8, 0, printerName.c_str(), -1, wstr, wchars_num);

    // Converte o nome do documento para string wide
    const char* docName = "ESC/POS Print Job";
    int doc_wchars_num = MultiByteToWideChar(CP_UTF8, 0, docName, -1, NULL, 0);
    wchar_t* doc_wstr = new wchar_t[doc_wchars_num];
    MultiByteToWideChar(CP_UTF8, 0, docName, -1, doc_wstr, doc_wchars_num);

    // Configura as informações do documento
    docInfo.pDocName = doc_wstr;
    docInfo.pOutputFile = NULL;
    docInfo.pDatatype = NULL;

    // Abre a impressora
    if (OpenPrinter(wstr, &hPrinter, NULL)) {
        // Inicia o documento
        if (StartDocPrinter(hPrinter, 1, (LPBYTE)&docInfo)) {
            // Inicia a página
            StartPagePrinter(hPrinter);
            
            // Escreve os bytes na impressora
            // Cast explícito necessário para os tipos esperados pela API do Windows
            WritePrinter(hPrinter, (LPVOID)bytes.data(), (DWORD)bytes.size(), &bytesWritten);
            
            // Finaliza a página e o documento
            EndPagePrinter(hPrinter);
            EndDocPrinter(hPrinter);
        }
        // Fecha a impressora
        ClosePrinter(hPrinter);
    }

    // Limpa a memória alocada
    delete[] wstr;
    delete[] doc_wstr;
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
    if (isPaperOut) description << "Sem papel. ";
    if (isPaperJam) description << "Papel encravado. ";
    if (isDoorOpen) description << "Tampa aberta. ";
    if (needsUserAction) description << "Requer intervenção do usuário. ";
  }

  if (isOffline && !isPaperOut && !isDoorOpen) {
    description << "Impressora offline. ";
  }

  if (description.str().empty()) {
    description << "Impressora pronta.";
  }

  statusMap[flutter::EncodableValue("description")] = flutter::EncodableValue(description.str());
  return statusMap;
}

// =====================================================
// Método que gerencia as chamadas do Flutter
// =====================================================
void ThermalPrinterFlutterPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue> &method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  // Verifica qual método foi chamado
  if (method_call.method_name().compare("getPlatformVersion") == 0) {
    // Retorna a versão do Windows
    std::ostringstream version_stream;
    version_stream << "Windows ";
    if (IsWindows10OrGreater()) {
      version_stream << "10+";
    } else if (IsWindows8OrGreater()) {
      version_stream << "8";
    } else if (IsWindows7OrGreater()) {
      version_stream << "7";
    }
    result->Success(flutter::EncodableValue(version_stream.str()));
  } else if (method_call.method_name().compare("usbprinters") == 0) {
    // Retorna a lista de impressoras USB
    auto printers = GetPrinters();
    flutter::EncodableList printerList;
    for (const auto& printer : printers) {
      flutter::EncodableMap printerMap;
      printerMap[flutter::EncodableValue("name")] = flutter::EncodableValue(printer);
      printerMap[flutter::EncodableValue("type")] = flutter::EncodableValue("usb");
      printerMap[flutter::EncodableValue("isConnected")] = flutter::EncodableValue(true);
      printerList.push_back(flutter::EncodableValue(printerMap));
    }
    result->Success(flutter::EncodableValue(printerList));
  } else if (method_call.method_name().compare("writebytes") == 0) {
    // Processa a impressão de bytes
    const auto* arguments = std::get_if<flutter::EncodableMap>(method_call.arguments());
    if (arguments) {
      // Busca os argumentos no mapa
      const auto bytes_iter = arguments->find(flutter::EncodableValue("bytes"));
      const auto printer_iter = arguments->find(flutter::EncodableValue("printerName"));
      
      if (bytes_iter != arguments->end() && printer_iter != arguments->end()) {
        // Converte os argumentos para os tipos corretos
        const auto* bytes_list = std::get_if<flutter::EncodableList>(&bytes_iter->second);
        const auto* printer_name = std::get_if<std::string>(&printer_iter->second);
        
        if (bytes_list && printer_name) {
          // Converte a lista de inteiros para bytes
          std::vector<uint8_t> bytes;
          bytes.reserve(bytes_list->size());
          
          for (size_t i = 0; i < bytes_list->size(); ++i) {
            const auto* int_value = std::get_if<int32_t>(&(*bytes_list)[i]);
            if (int_value) {
              bytes.push_back(static_cast<uint8_t>(*int_value));
            }
          }
          
          // Chama o método de impressão
          PrintBytes(bytes, *printer_name);
          result->Success(flutter::EncodableValue(true));
          return;
        }
      }
    }
    result->Error("invalid_arguments", "Invalid arguments for printBytes");
  } else if (method_call.method_name().compare("getPrinterStatus") == 0) {
    std::string printerName;
    const auto* arguments = std::get_if<flutter::EncodableMap>(method_call.arguments());
    if (arguments != nullptr) {
      const auto iter = arguments->find(flutter::EncodableValue("printerName"));
      if (iter != arguments->end()) {
        const auto* value = std::get_if<std::string>(&iter->second);
        if (value != nullptr) {
          printerName = *value;
        }
      }
    } else {
      const auto* directName = std::get_if<std::string>(method_call.arguments());
      if (directName != nullptr) {
        printerName = *directName;
      }
    }

    if (printerName.empty()) {
      result->Error("invalid_arguments", "printerName is required for getPrinterStatus");
      return;
    }

    auto statusMap = BuildPrinterStatusMap(printerName);
    result->Success(flutter::EncodableValue(statusMap));
    return;
  } else {
    result->NotImplemented();
  }
}

}  // namespace thermal_printer_flutter
