#include "internal.h"

#include <windows.h>

#include <iostream>
#include <utility>
#include <vector>

namespace {

scene_converter::fs::path GetExecutablePath() {
    std::wstring buffer(32768, L'\0');
    const DWORD length = GetModuleFileNameW(nullptr, buffer.data(), static_cast<DWORD>(buffer.size()));
    if (length == 0 || static_cast<std::size_t>(length) >= buffer.size()) {
        return {};
    }
    buffer.resize(length);
    return scene_converter::fs::path(buffer);
}

int EmitResult(const scene_converter::ExecutionResult& result, scene_converter::OutputMode outputMode, bool quiet,
               bool batchMode) {
    if (outputMode == scene_converter::OutputMode::json) {
        std::cout << scene_converter::RenderJson(result) << '\n';
    } else {
        scene_converter::PrintHumanResult(result, quiet, batchMode);
    }
    return scene_converter::ToInt(result.exitCode);
}

}  // namespace

int wmain(int argumentCount, wchar_t* arguments[]) {
    std::vector<std::wstring> commandArguments;
    commandArguments.reserve(argumentCount > 1 ? static_cast<std::size_t>(argumentCount - 1) : 0);
    for (int argumentIndex = 1; argumentIndex < argumentCount; ++argumentIndex) {
        commandArguments.emplace_back(arguments[argumentIndex]);
    }

    if (commandArguments.size() == 1 && (commandArguments[0] == L"--help" || commandArguments[0] == L"-h")) {
        std::cout << scene_converter::GetUsageText();
        return scene_converter::ToInt(scene_converter::ExitCode::success);
    }
    if (commandArguments.size() == 1 && commandArguments[0] == L"--version") {
        std::cout << scene_converter::GetVersionText() << '\n';
        return scene_converter::ToInt(scene_converter::ExitCode::success);
    }

    const bool requestedJson =
        scene_converter::internal::ContainsOptionBeforeEndOfOptions(commandArguments, L"--json");
    const bool requestedQuiet =
        scene_converter::internal::ContainsOptionBeforeEndOfOptions(commandArguments, L"--quiet");
    scene_converter::ParseResult parseResult = scene_converter::ParseArguments(commandArguments);
    if (parseResult.exitCode != scene_converter::ExitCode::success) {
        scene_converter::ExecutionResult result;
        result.exitCode = parseResult.exitCode;
        result.message = std::move(parseResult.message);
        if (requestedJson) {
            return EmitResult(result, scene_converter::OutputMode::json, requestedQuiet, false);
        }
        std::cerr << result.message << '\n' << scene_converter::GetUsageText();
        return scene_converter::ToInt(result.exitCode);
    }

    const scene_converter::CommandLine& commandLine = parseResult.commandLine;
    const scene_converter::JobPlan plan = scene_converter::BuildJobPlan(commandLine);
    if (plan.exitCode != scene_converter::ExitCode::success) {
        scene_converter::ExecutionResult result;
        result.exitCode = plan.exitCode;
        result.message = plan.message;
        return EmitResult(result, commandLine.outputMode, commandLine.quiet, plan.batchMode);
    }

    const scene_converter::ExecutionResult runtimeResult = scene_converter::InitializeRuntime(GetExecutablePath());
    if (runtimeResult.exitCode != scene_converter::ExitCode::success) {
        return EmitResult(runtimeResult, commandLine.outputMode, commandLine.quiet, plan.batchMode);
    }

    const scene_converter::ExecutionResult executionResult =
        scene_converter::ExecutePlan(plan, commandLine.forceOverwrite);
    return EmitResult(executionResult, commandLine.outputMode, commandLine.quiet, plan.batchMode);
}
