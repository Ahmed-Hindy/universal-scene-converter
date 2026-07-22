#pragma once

#include "converter_core.h"

#include <string>
#include <string_view>
#include <system_error>
#include <unordered_set>
#include <utility>
#include <vector>

namespace scene_converter::internal {

struct InputItem {
    fs::path inputPath;
    fs::path sourceRoot;
};

struct StagedFile {
    fs::path sourcePath;
    fs::path targetPath;
    fs::path relativePath;
};

struct CommitResult {
    ExitCode exitCode = ExitCode::success;
    std::string message;
    std::vector<fs::path> generatedFiles;
};

std::string ToUtf8(std::wstring_view value);
std::wstring ToLower(std::wstring value);
bool ContainsOptionBeforeEndOfOptions(const std::vector<std::wstring>& arguments, std::wstring_view option);
fs::path GetAbsolutePath(const fs::path& path, std::error_code& errorCode);
std::wstring GetPathKey(const fs::path& path);
bool IsPathWithin(const fs::path& path, const fs::path& parentPath);
bool PathsReferToSameFile(const fs::path& firstPath, const fs::path& secondPath);
const std::unordered_set<std::wstring>& GetSupportedExtensions();
bool IsSupportedInputPath(const fs::path& path);
bool NormalizeOutputExtension(std::wstring value, std::wstring& normalizedExtension);
fs::path BuildDefaultOutputPath(const fs::path& inputPath, const fs::path& outputParent,
                                const std::wstring& outputExtension);
fs::path CreateUniqueDirectory(const fs::path& parentPath, std::wstring_view label, std::error_code& errorCode);
void RemoveTree(const fs::path& path);
CommitResult CommitStagedFiles(const fs::path& stagingRoot, const fs::path& outputParent, bool forceOverwrite);
JobResult ConvertFile(const ConversionJob& job, bool forceOverwrite);

}  // namespace scene_converter::internal
