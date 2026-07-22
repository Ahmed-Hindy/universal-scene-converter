#include "internal.h"

#include <string_view>

namespace scene_converter {
namespace {

constexpr std::wstring_view kEndOptions = L"--";
constexpr std::wstring_view kForceOption = L"--force";
constexpr std::wstring_view kJsonOption = L"--json";
constexpr std::wstring_view kOutputDirectoryOption = L"--output-dir";
constexpr std::wstring_view kOutputFormatOption = L"--output-format";
constexpr std::wstring_view kOutputOption = L"-o";
constexpr std::wstring_view kQuietOption = L"--quiet";
constexpr std::wstring_view kRecursiveOption = L"--recursive";

bool ReadPathOptionValue(std::size_t& argumentIndex, const std::vector<std::wstring>& arguments, fs::path& value,
                         std::string& errorMessage, std::string_view optionName) {
    if (argumentIndex + 1 >= arguments.size()) {
        errorMessage = "Missing value for " + std::string(optionName) + ".";
        return false;
    }
    value = arguments[++argumentIndex];
    if (value.empty()) {
        errorMessage = "Empty value for " + std::string(optionName) + ".";
        return false;
    }
    return true;
}

ParseResult UsageError(CommandLine commandLine, std::string message) {
    return {std::move(commandLine), ExitCode::usageError, std::move(message)};
}

}  // namespace

namespace internal {

bool ContainsOptionBeforeEndOfOptions(const std::vector<std::wstring>& arguments, std::wstring_view option) {
    bool skipOptionValue = false;
    for (const std::wstring& argument : arguments) {
        if (skipOptionValue) {
            skipOptionValue = false;
            continue;
        }
        if (argument == kEndOptions) {
            break;
        }
        if (argument == option) {
            return true;
        }
        skipOptionValue = argument == kOutputOption || argument == kOutputDirectoryOption ||
                          argument == kOutputFormatOption;
    }
    return false;
}

}  // namespace internal

ParseResult ParseArguments(const std::vector<std::wstring>& arguments) {
    CommandLine commandLine;
    std::vector<fs::path> positionalArguments;
    bool parseOptions = true;

    for (std::size_t argumentIndex = 0; argumentIndex < arguments.size(); ++argumentIndex) {
        const std::wstring_view argument(arguments[argumentIndex]);
        if (parseOptions && argument == kEndOptions) {
            parseOptions = false;
            continue;
        }
        if (parseOptions && argument == kForceOption) {
            if (commandLine.forceOverwrite) {
                return UsageError(std::move(commandLine), "--force was provided more than once.");
            }
            commandLine.forceOverwrite = true;
            continue;
        }
        if (parseOptions && argument == kJsonOption) {
            if (commandLine.outputMode == OutputMode::json) {
                return UsageError(std::move(commandLine), "--json was provided more than once.");
            }
            commandLine.outputMode = OutputMode::json;
            continue;
        }
        if (parseOptions && argument == kQuietOption) {
            if (commandLine.quiet) {
                return UsageError(std::move(commandLine), "--quiet was provided more than once.");
            }
            commandLine.quiet = true;
            continue;
        }
        if (parseOptions && argument == kRecursiveOption) {
            if (commandLine.recursive) {
                return UsageError(std::move(commandLine), "--recursive was provided more than once.");
            }
            commandLine.recursive = true;
            continue;
        }
        if (parseOptions && argument == kOutputOption) {
            if (commandLine.hasExplicitOutput) {
                return UsageError(std::move(commandLine), "-o was provided more than once.");
            }
            std::string errorMessage;
            if (!ReadPathOptionValue(argumentIndex, arguments, commandLine.explicitOutputPath, errorMessage, "-o")) {
                return UsageError(std::move(commandLine), std::move(errorMessage));
            }
            commandLine.hasExplicitOutput = true;
            continue;
        }
        if (parseOptions && argument == kOutputDirectoryOption) {
            if (commandLine.hasOutputDirectory) {
                return UsageError(std::move(commandLine), "--output-dir was provided more than once.");
            }
            std::string errorMessage;
            if (!ReadPathOptionValue(argumentIndex, arguments, commandLine.outputDirectory, errorMessage,
                                     "--output-dir")) {
                return UsageError(std::move(commandLine), std::move(errorMessage));
            }
            commandLine.hasOutputDirectory = true;
            continue;
        }
        if (parseOptions && argument == kOutputFormatOption) {
            if (commandLine.hasOutputExtension) {
                return UsageError(std::move(commandLine), "--output-format was provided more than once.");
            }
            if (argumentIndex + 1 >= arguments.size()) {
                return UsageError(std::move(commandLine), "Missing value for --output-format.");
            }
            if (!internal::NormalizeOutputExtension(arguments[++argumentIndex], commandLine.outputExtension)) {
                return UsageError(std::move(commandLine), "Unsupported --output-format value.");
            }
            commandLine.hasOutputExtension = true;
            continue;
        }
        if (parseOptions && !argument.empty() && argument.front() == L'-') {
            return UsageError(std::move(commandLine), "Unknown option: " + internal::ToUtf8(argument));
        }
        positionalArguments.emplace_back(argument);
    }

    if (positionalArguments.empty()) {
        return UsageError(std::move(commandLine), "At least one input path is required.");
    }

    const bool hasBatchOptions = commandLine.hasOutputDirectory || commandLine.hasOutputExtension || commandLine.recursive;
    if (commandLine.hasExplicitOutput) {
        if (positionalArguments.size() != 1 || hasBatchOptions) {
            return UsageError(std::move(commandLine),
                              "-o accepts exactly one input and cannot be combined with batch options.");
        }
        commandLine.inputArguments = std::move(positionalArguments);
        return {std::move(commandLine), ExitCode::success, {}};
    }

    if (positionalArguments.size() == 2 && !hasBatchOptions) {
        commandLine.inputArguments.push_back(positionalArguments[0]);
        commandLine.explicitOutputPath = positionalArguments[1];
        commandLine.hasExplicitOutput = true;
        return {std::move(commandLine), ExitCode::success, {}};
    }

    commandLine.inputArguments = std::move(positionalArguments);
    commandLine.batchRequested = hasBatchOptions || commandLine.inputArguments.size() > 1;
    return {std::move(commandLine), ExitCode::success, {}};
}

}  // namespace scene_converter
