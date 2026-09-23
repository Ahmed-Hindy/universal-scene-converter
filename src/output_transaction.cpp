#include "internal.h"

#include <windows.h>

#include <algorithm>
#include <iostream>

namespace scene_converter::internal {
namespace {

std::vector<StagedFile> CollectStagedFiles(const fs::path& stagingRoot, const fs::path& outputParent,
                                           std::string& errorMessage) {
    std::vector<StagedFile> stagedFiles;
    std::unordered_set<std::wstring> targetKeys;
    std::error_code errorCode;

    for (fs::recursive_directory_iterator iterator(stagingRoot, errorCode), end; iterator != end && !errorCode;
         iterator.increment(errorCode)) {
        if (!iterator->is_regular_file(errorCode)) {
            if (errorCode) {
                break;
            }
            continue;
        }

        const fs::path relativePath = fs::relative(iterator->path(), stagingRoot, errorCode);
        if (errorCode) {
            break;
        }

        const fs::path targetPath = outputParent / relativePath;
        if (!targetKeys.insert(GetPathKey(targetPath)).second) {
            errorMessage = "The staged export produced duplicate output paths: " + PathToUtf8(targetPath);
            return {};
        }
        stagedFiles.push_back({iterator->path(), targetPath, relativePath});
    }

    if (errorCode) {
        errorMessage = "Could not inspect staged output files: " + errorCode.message();
        return {};
    }
    if (stagedFiles.empty()) {
        errorMessage = "The export produced no output files.";
        return stagedFiles;
    }

    std::sort(stagedFiles.begin(), stagedFiles.end(), [](const StagedFile& first, const StagedFile& second) {
        return GetPathKey(first.relativePath) < GetPathKey(second.relativePath);
    });
    return stagedFiles;
}

// Best-effort undo of a partial commit: remove any files already moved into
// place, then restore backed-up originals. Every step is attempted regardless of
// earlier failures, since giving back as many originals as possible is better
// than stopping at the first error. A failure here is the one case that can lose
// a user's data -- an original that cannot be restored is stranded under the
// backup directory -- so unlike the routine cleanup elsewhere it is reported
// rather than swallowed, and the caller is told where the backups still live.
bool RollBackCommittedFiles(const std::vector<fs::path>& movedTargets,
                            const std::vector<std::pair<fs::path, fs::path>>& backups) {
    bool fullyRestored = true;
    std::error_code errorCode;
    for (auto iterator = movedTargets.rbegin(); iterator != movedTargets.rend(); ++iterator) {
        fs::remove(*iterator, errorCode);
        if (errorCode) {
            std::cerr << "Warning: could not remove partially committed output " << PathToUtf8(*iterator) << ": "
                      << errorCode.message() << '\n';
            fullyRestored = false;
        }
        errorCode.clear();
    }
    for (auto iterator = backups.rbegin(); iterator != backups.rend(); ++iterator) {
        const fs::path& originalPath = iterator->first;
        const fs::path& backupPath = iterator->second;
        fs::create_directories(originalPath.parent_path(), errorCode);
        errorCode.clear();
        fs::rename(backupPath, originalPath, errorCode);
        if (errorCode) {
            std::cerr << "Warning: could not restore original output " << PathToUtf8(originalPath)
                      << " from backup " << PathToUtf8(backupPath) << ": " << errorCode.message() << '\n';
            fullyRestored = false;
        }
        errorCode.clear();
    }
    return fullyRestored;
}

}  // namespace

fs::path CreateUniqueDirectory(const fs::path& parentPath, std::wstring_view label, std::error_code& errorCode) {
    static unsigned long directoryCounter = 0;
    for (unsigned int attempt = 0; attempt < 100; ++attempt) {
        const std::wstring name = std::wstring(label) + L"-" + std::to_wstring(GetCurrentProcessId()) + L"-" +
                                  std::to_wstring(GetTickCount64()) + L"-" + std::to_wstring(directoryCounter++);
        const fs::path candidatePath = parentPath / name;
        if (fs::create_directory(candidatePath, errorCode)) {
            return candidatePath;
        }
        if (errorCode) {
            return {};
        }
    }

    errorCode = std::make_error_code(std::errc::file_exists);
    return {};
}

void RemoveTree(const fs::path& path) {
    if (path.empty()) {
        return;
    }
    std::error_code ignoredError;
    fs::remove_all(path, ignoredError);
}

CommitResult CommitStagedFiles(const fs::path& stagingRoot, const fs::path& outputParent, bool forceOverwrite) {
    std::string collectionError;
    std::vector<StagedFile> stagedFiles = CollectStagedFiles(stagingRoot, outputParent, collectionError);
    if (stagedFiles.empty()) {
        return {ExitCode::outputError, collectionError, {}};
    }

    std::vector<StagedFile*> existingTargets;
    std::error_code errorCode;
    for (StagedFile& stagedFile : stagedFiles) {
        const bool targetExists = fs::exists(stagedFile.targetPath, errorCode);
        if (errorCode) {
            return {ExitCode::outputError,
                    "Could not inspect output path " + PathToUtf8(stagedFile.targetPath) + ": " + errorCode.message(),
                    {}};
        }
        if (!targetExists) {
            continue;
        }
        if (!forceOverwrite) {
            return {ExitCode::usageError,
                    "Output already exists: " + PathToUtf8(stagedFile.targetPath) + ". Use --force to replace it.",
                    {}};
        }
        if (!fs::is_regular_file(stagedFile.targetPath, errorCode) || errorCode) {
            return {ExitCode::outputError,
                    "Existing output is not a regular file: " + PathToUtf8(stagedFile.targetPath), {}};
        }
        existingTargets.push_back(&stagedFile);
    }

    fs::path backupRoot;
    std::vector<std::pair<fs::path, fs::path>> backups;
    if (!existingTargets.empty()) {
        backupRoot = CreateUniqueDirectory(outputParent, L".usdconvert-backup", errorCode);
        if (backupRoot.empty()) {
            return {ExitCode::outputError, "Could not create an output backup directory: " + errorCode.message(), {}};
        }

        for (const StagedFile* stagedFile : existingTargets) {
            const fs::path backupPath = backupRoot / stagedFile->relativePath;
            fs::create_directories(backupPath.parent_path(), errorCode);
            if (errorCode) {
                if (RollBackCommittedFiles({}, backups)) {
                    RemoveTree(backupRoot);
                }
                return {ExitCode::outputError, "Could not create a backup path: " + errorCode.message(), {}};
            }
            fs::rename(stagedFile->targetPath, backupPath, errorCode);
            if (errorCode) {
                if (RollBackCommittedFiles({}, backups)) {
                    RemoveTree(backupRoot);
                }
                return {ExitCode::outputError,
                        "Could not back up existing output " + PathToUtf8(stagedFile->targetPath) + ": " +
                            errorCode.message(),
                        {}};
            }
            backups.emplace_back(stagedFile->targetPath, backupPath);
        }
    }

    std::vector<fs::path> movedTargets;
    for (const StagedFile& stagedFile : stagedFiles) {
        fs::create_directories(stagedFile.targetPath.parent_path(), errorCode);
        if (!errorCode) {
            fs::rename(stagedFile.sourcePath, stagedFile.targetPath, errorCode);
        }
        if (errorCode) {
            const bool fullyRestored = RollBackCommittedFiles(movedTargets, backups);
            RemoveTree(stagingRoot);
            if (fullyRestored) {
                RemoveTree(backupRoot);
            } else {
                std::cerr << "Warning: original outputs were preserved under " << PathToUtf8(backupRoot)
                          << " because the rollback could not fully restore them.\n";
            }
            return {ExitCode::outputError,
                    "Could not commit output " + PathToUtf8(stagedFile.targetPath) + ": " + errorCode.message(), {}};
        }
        movedTargets.push_back(stagedFile.targetPath);
    }

    RemoveTree(stagingRoot);
    RemoveTree(backupRoot);
    return {ExitCode::success, {}, std::move(movedTargets)};
}

}  // namespace scene_converter::internal
