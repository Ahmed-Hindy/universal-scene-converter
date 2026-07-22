#include "internal.h"

#include <windows.h>

#include <algorithm>

namespace scene_converter {
namespace {

bool AddDirectoryInputs(const fs::path& directoryPath, const CommandLine& commandLine,
                        const fs::path& resolvedOutputDirectory, std::vector<internal::InputItem>& inputItems,
                        std::string& errorMessage) {
    std::error_code errorCode;
    const bool skipOutputTree = commandLine.hasOutputDirectory &&
                                internal::GetPathKey(directoryPath) != internal::GetPathKey(resolvedOutputDirectory) &&
                                internal::IsPathWithin(resolvedOutputDirectory, directoryPath);

    if (commandLine.recursive) {
        for (fs::recursive_directory_iterator iterator(directoryPath, errorCode), end; iterator != end && !errorCode;
             iterator.increment(errorCode)) {
            const bool isDirectory = iterator->is_directory(errorCode);
            if (errorCode) {
                break;
            }
            if (isDirectory) {
                if (skipOutputTree && internal::IsPathWithin(iterator->path(), resolvedOutputDirectory)) {
                    iterator.disable_recursion_pending();
                }
                continue;
            }

            const bool isRegularFile = iterator->is_regular_file(errorCode);
            if (errorCode) {
                break;
            }
            if (isRegularFile && internal::IsSupportedInputPath(iterator->path())) {
                inputItems.push_back({iterator->path(), directoryPath});
            }
        }
    } else {
        for (fs::directory_iterator iterator(directoryPath, errorCode), end; iterator != end && !errorCode;
             iterator.increment(errorCode)) {
            const bool isRegularFile = iterator->is_regular_file(errorCode);
            if (errorCode) {
                break;
            }
            if (isRegularFile && internal::IsSupportedInputPath(iterator->path())) {
                inputItems.push_back({iterator->path(), directoryPath});
            }
        }
    }

    if (errorCode) {
        errorMessage = "Could not enumerate directory " + PathToUtf8(directoryPath) + ": " + errorCode.message();
        return false;
    }
    return true;
}

JobPlan PlanError(ExitCode exitCode, std::string message, bool batchMode) {
    return {{}, exitCode, std::move(message), batchMode};
}

}  // namespace

JobPlan BuildJobPlan(const CommandLine& commandLine) {
    JobPlan plan;
    plan.batchMode = commandLine.batchRequested;
    std::error_code errorCode;

    if (commandLine.hasExplicitOutput) {
        const fs::path inputPath = internal::GetAbsolutePath(commandLine.inputArguments.front(), errorCode);
        if (errorCode) {
            return PlanError(ExitCode::usageError, "Could not resolve the input path: " + errorCode.message(), false);
        }
        const fs::path outputPath = internal::GetAbsolutePath(commandLine.explicitOutputPath, errorCode);
        if (errorCode) {
            return PlanError(ExitCode::usageError, "Could not resolve the output path: " + errorCode.message(), false);
        }
        plan.jobs.push_back({inputPath, outputPath});
        return plan;
    }

    fs::path resolvedOutputDirectory;
    if (commandLine.hasOutputDirectory) {
        resolvedOutputDirectory = internal::GetAbsolutePath(commandLine.outputDirectory, errorCode);
        if (errorCode) {
            return PlanError(ExitCode::usageError, "Could not resolve --output-dir: " + errorCode.message(), true);
        }
    }

    bool foundDirectoryInput = false;
    std::vector<internal::InputItem> inputItems;
    for (const fs::path& inputArgument : commandLine.inputArguments) {
        const fs::path inputPath = internal::GetAbsolutePath(inputArgument, errorCode);
        if (errorCode) {
            return PlanError(ExitCode::usageError, "Could not resolve input path: " + errorCode.message(), true);
        }

        const fs::file_status inputStatus = fs::status(inputPath, errorCode);
        if (errorCode) {
            const int errorValue = errorCode.value();
            const bool pathIsMissing = errorValue == ERROR_FILE_NOT_FOUND || errorValue == ERROR_PATH_NOT_FOUND;
            if (!pathIsMissing) {
                return PlanError(ExitCode::inputError,
                                 "Could not inspect input path " + PathToUtf8(inputPath) + ": " + errorCode.message(),
                                 true);
            }
            errorCode.clear();
        }

        if (fs::is_directory(inputStatus)) {
            foundDirectoryInput = true;
            plan.batchMode = true;
            if (!commandLine.hasOutputDirectory) {
                return PlanError(ExitCode::usageError, "Directory inputs require --output-dir.", true);
            }
            if (internal::GetPathKey(inputPath) == internal::GetPathKey(resolvedOutputDirectory)) {
                return PlanError(ExitCode::usageError, "--output-dir must differ from a directory input.", true);
            }
            std::string directoryError;
            if (!AddDirectoryInputs(inputPath, commandLine, resolvedOutputDirectory, inputItems, directoryError)) {
                return PlanError(ExitCode::inputError, std::move(directoryError), true);
            }
            continue;
        }

        if (fs::exists(inputStatus) && !fs::is_regular_file(inputStatus)) {
            return PlanError(ExitCode::inputError, "Input is not a regular file: " + PathToUtf8(inputPath), true);
        }
        inputItems.push_back({inputPath, {}});
    }

    if (commandLine.recursive && !foundDirectoryInput) {
        return PlanError(ExitCode::usageError, "--recursive requires at least one directory input.", true);
    }
    if (inputItems.empty()) {
        return PlanError(ExitCode::inputError, "No supported input files were found.", true);
    }

    std::sort(inputItems.begin(), inputItems.end(), [](const internal::InputItem& first, const internal::InputItem& second) {
        return internal::GetPathKey(first.inputPath) < internal::GetPathKey(second.inputPath);
    });
    inputItems.erase(
        std::unique(inputItems.begin(), inputItems.end(), [](const internal::InputItem& first, const internal::InputItem& second) {
            return internal::GetPathKey(first.inputPath) == internal::GetPathKey(second.inputPath);
        }),
        inputItems.end());

    std::unordered_set<std::wstring> inputKeys;
    for (const internal::InputItem& inputItem : inputItems) {
        inputKeys.insert(internal::GetPathKey(inputItem.inputPath));
    }

    std::unordered_set<std::wstring> outputKeys;
    for (const internal::InputItem& inputItem : inputItems) {
        fs::path outputParent = commandLine.hasOutputDirectory ? resolvedOutputDirectory : inputItem.inputPath.parent_path();
        if (commandLine.hasOutputDirectory && !inputItem.sourceRoot.empty()) {
            const fs::path relativeParent = fs::relative(inputItem.inputPath.parent_path(), inputItem.sourceRoot, errorCode);
            if (errorCode) {
                return PlanError(ExitCode::usageError, "Could not preserve the directory layout: " + errorCode.message(),
                                 true);
            }
            if (relativeParent != fs::path(L".")) {
                outputParent /= relativeParent;
            }
        }

        const std::wstring outputExtension = commandLine.hasOutputExtension
                                                 ? commandLine.outputExtension
                                                 : internal::ToLower(inputItem.inputPath.extension().wstring());
        if (internal::GetSupportedExtensions().count(outputExtension) == 0) {
            return PlanError(ExitCode::usageError,
                             "Could not derive a supported output extension for " + PathToUtf8(inputItem.inputPath) +
                                 ". Use --output-format.",
                             true);
        }

        const fs::path outputPath = internal::BuildDefaultOutputPath(inputItem.inputPath, outputParent, outputExtension);
        if (outputPath.empty()) {
            return PlanError(ExitCode::usageError,
                             "Could not build an output path for " + PathToUtf8(inputItem.inputPath), true);
        }

        const std::wstring outputKey = internal::GetPathKey(outputPath);
        if (!outputKeys.insert(outputKey).second) {
            return PlanError(ExitCode::usageError, "Multiple inputs resolve to the same output: " + PathToUtf8(outputPath),
                             true);
        }
        if (inputKeys.count(outputKey) != 0) {
            return PlanError(ExitCode::usageError,
                             "A planned output would overwrite a batch input: " + PathToUtf8(outputPath), true);
        }
        plan.jobs.push_back({inputItem.inputPath, outputPath});
    }

    plan.batchMode = plan.batchMode || foundDirectoryInput || plan.jobs.size() > 1;
    return plan;
}

}  // namespace scene_converter
