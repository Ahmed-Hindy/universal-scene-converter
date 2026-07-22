#pragma once

#include <cstddef>
#include <filesystem>
#include <string>
#include <vector>

namespace scene_converter {

namespace fs = std::filesystem;

enum class ExitCode : int {
    success = 0,
    usageError = 2,
    runtimeError = 3,
    inputError = 4,
    outputError = 5,
    batchError = 6,
};

enum class OutputMode {
    human,
    json,
};

struct CommandLine {
    std::vector<fs::path> inputArguments;
    fs::path explicitOutputPath;
    fs::path outputDirectory;
    std::wstring outputExtension;
    bool hasExplicitOutput = false;
    bool hasOutputDirectory = false;
    bool hasOutputExtension = false;
    bool recursive = false;
    bool forceOverwrite = false;
    bool batchRequested = false;
    bool quiet = false;
    OutputMode outputMode = OutputMode::human;
};

struct ParseResult {
    CommandLine commandLine;
    ExitCode exitCode = ExitCode::success;
    std::string message;
};

struct ConversionJob {
    fs::path inputPath;
    fs::path outputPath;
};

struct JobPlan {
    std::vector<ConversionJob> jobs;
    ExitCode exitCode = ExitCode::success;
    std::string message;
    bool batchMode = false;
};

struct JobResult {
    fs::path inputPath;
    fs::path outputPath;
    std::vector<fs::path> generatedFiles;
    ExitCode exitCode = ExitCode::success;
    std::string message;
};

struct ExecutionResult {
    std::vector<JobResult> jobs;
    ExitCode exitCode = ExitCode::success;
    std::string message;
    std::size_t succeededCount = 0;
    std::size_t failedCount = 0;
};

int ToInt(ExitCode exitCode);
std::string PathToUtf8(const fs::path& path);
std::string GetUsageText();
std::string GetVersionText();
ParseResult ParseArguments(const std::vector<std::wstring>& arguments);
JobPlan BuildJobPlan(const CommandLine& commandLine);
ExecutionResult InitializeRuntime(const fs::path& executablePath);
ExecutionResult ExecutePlan(const JobPlan& plan, bool forceOverwrite);
std::string RenderJson(const ExecutionResult& result);
void PrintHumanResult(const ExecutionResult& result, bool quiet, bool batchMode);

}  // namespace scene_converter
