#include "internal.h"

#include <pxr/usd/sdf/fileFormat.h>
#include <pxr/usd/sdf/layer.h>

namespace scene_converter::internal {

JobResult ConvertFile(const ConversionJob& job, bool forceOverwrite) {
    JobResult result;
    result.inputPath = job.inputPath;
    result.outputPath = job.outputPath;

    if (PathsReferToSameFile(job.inputPath, job.outputPath)) {
        result.exitCode = ExitCode::usageError;
        result.message = "Input and output must be different files.";
        return result;
    }

    const fs::path outputParent = job.outputPath.parent_path();
    if (outputParent.empty() || job.outputPath.filename().empty()) {
        result.exitCode = ExitCode::usageError;
        result.message = "Could not resolve the output path.";
        return result;
    }

    std::error_code errorCode;
    const bool outputExists = fs::exists(job.outputPath, errorCode);
    if (errorCode) {
        result.exitCode = ExitCode::outputError;
        result.message = "Could not inspect output path " + PathToUtf8(job.outputPath) + ": " + errorCode.message();
        return result;
    }
    if (outputExists && !forceOverwrite) {
        result.exitCode = ExitCode::usageError;
        result.message = "Output already exists: " + PathToUtf8(job.outputPath) + ". Use --force to replace it.";
        return result;
    }

    const std::string inputPath = PathToUtf8(job.inputPath);
    const std::string outputPath = PathToUtf8(job.outputPath);
    if (inputPath.empty() || outputPath.empty()) {
        result.exitCode = ExitCode::usageError;
        result.message = "Input or output path could not be converted to UTF-8.";
        return result;
    }

    if (!pxr::SdfFileFormat::FindByExtension(outputPath)) {
        result.exitCode = ExitCode::outputError;
        result.message = "No registered file format supports the output path: " + outputPath;
        return result;
    }

    const pxr::SdfLayerRefPtr inputLayer = pxr::SdfLayer::FindOrOpen(inputPath);
    if (!inputLayer) {
        result.exitCode = ExitCode::inputError;
        result.message = "Could not open input layer: " + inputPath;
        return result;
    }

    fs::create_directories(outputParent, errorCode);
    if (errorCode) {
        result.exitCode = ExitCode::outputError;
        result.message = "Could not create output directory " + PathToUtf8(outputParent) + ": " + errorCode.message();
        return result;
    }

    const fs::path stagingRoot = CreateUniqueDirectory(outputParent, L".usdconvert-stage", errorCode);
    if (stagingRoot.empty()) {
        result.exitCode = ExitCode::outputError;
        result.message = "Could not create an output staging directory: " + errorCode.message();
        return result;
    }

    const fs::path stagedOutputPath = stagingRoot / job.outputPath.filename();
    const std::string stagedOutputPathUtf8 = PathToUtf8(stagedOutputPath);
    if (stagedOutputPathUtf8.empty() || !inputLayer->Export(stagedOutputPathUtf8)) {
        RemoveTree(stagingRoot);
        result.exitCode = ExitCode::outputError;
        result.message = "Could not export output layer: " + outputPath;
        return result;
    }

    if (!fs::is_regular_file(stagedOutputPath, errorCode) || errorCode) {
        RemoveTree(stagingRoot);
        result.exitCode = ExitCode::outputError;
        result.message = "The export did not create the expected output file: " + outputPath;
        return result;
    }

    CommitResult commitResult = CommitStagedFiles(stagingRoot, outputParent, forceOverwrite);
    if (commitResult.exitCode != ExitCode::success) {
        RemoveTree(stagingRoot);
        result.exitCode = commitResult.exitCode;
        result.message = std::move(commitResult.message);
        return result;
    }

    result.generatedFiles = std::move(commitResult.generatedFiles);
    return result;
}

}  // namespace scene_converter::internal

namespace scene_converter {

ExecutionResult ExecutePlan(const JobPlan& plan, bool forceOverwrite) {
    ExecutionResult result;
    result.jobs.reserve(plan.jobs.size());

    for (const ConversionJob& job : plan.jobs) {
        JobResult jobResult = internal::ConvertFile(job, forceOverwrite);
        if (jobResult.exitCode == ExitCode::success) {
            ++result.succeededCount;
        } else {
            ++result.failedCount;
        }
        result.jobs.push_back(std::move(jobResult));
    }

    if (result.failedCount == 0) {
        result.exitCode = ExitCode::success;
    } else if (plan.batchMode) {
        result.exitCode = ExitCode::batchError;
        result.message = "One or more batch items failed.";
    } else {
        result.exitCode = result.jobs.front().exitCode;
        result.message = result.jobs.front().message;
    }
    return result;
}

}  // namespace scene_converter
