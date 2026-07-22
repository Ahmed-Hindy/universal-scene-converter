#include "internal.h"

#include <pxr/base/plug/registry.h>

namespace scene_converter {
namespace {

bool RegisterPluginTree(const fs::path& plugInfoPath, std::string_view label, std::string& errorMessage) {
    std::error_code errorCode;
    const bool isRegistryFile = fs::is_regular_file(plugInfoPath, errorCode);
    if (errorCode) {
        errorMessage = "Could not inspect " + std::string(label) + " plugin registry " + PathToUtf8(plugInfoPath) +
                       ": " + errorCode.message();
        return false;
    }
    if (!isRegistryFile) {
        errorMessage = "Missing " + std::string(label) + " plugin registry: " + PathToUtf8(plugInfoPath);
        return false;
    }

    const std::string registryPath = PathToUtf8(plugInfoPath);
    if (registryPath.empty()) {
        errorMessage = "Could not convert the " + std::string(label) + " plugin registry path to UTF-8.";
        return false;
    }

    pxr::PlugRegistry::GetInstance().RegisterPlugins(registryPath);
    return true;
}

}  // namespace

ExecutionResult InitializeRuntime(const fs::path& executablePath) {
    ExecutionResult result;
    if (executablePath.empty()) {
        result.exitCode = ExitCode::runtimeError;
        result.message = "Could not determine the usdconvert executable path.";
        return result;
    }

    const fs::path binaryDirectory = executablePath.parent_path();
    const fs::path runtimeRoot = binaryDirectory.parent_path();
    if (!RegisterPluginTree(binaryDirectory / "usd" / "plugInfo.json", "OpenUSD core", result.message) ||
        !RegisterPluginTree(runtimeRoot / "plugin" / "usd" / "plugInfo.json", "Adobe file-format", result.message)) {
        result.exitCode = ExitCode::runtimeError;
    }
    return result;
}

}  // namespace scene_converter
