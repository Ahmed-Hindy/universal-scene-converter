#include "internal.h"

#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

namespace fs = std::filesystem;

void Require(bool condition, const std::string& message) {
    if (!condition) {
        throw std::runtime_error(message);
    }
}

void WriteText(const fs::path& path, const std::string& content) {
    fs::create_directories(path.parent_path());
    std::ofstream stream(path, std::ios::binary);
    stream << content;
    if (!stream) {
        throw std::runtime_error("Could not write test file: " + path.string());
    }
}

std::string ReadText(const fs::path& path) {
    std::ifstream stream(path, std::ios::binary);
    return std::string((std::istreambuf_iterator<char>(stream)), std::istreambuf_iterator<char>());
}

fs::path MakeTestRoot() {
    std::error_code errorCode;
    const fs::path root = fs::temp_directory_path() / "universal-scene-converter-core-tests";
    fs::remove_all(root, errorCode);
    fs::create_directories(root, errorCode);
    Require(!errorCode, "Could not create the test root.");
    return root;
}

void TestArgumentParsing() {
    const scene_converter::ParseResult result = scene_converter::ParseArguments(
        {L"asset.fbx", L"--output-dir", L"converted", L"--output-format", L"usdc", L"--json", L"--quiet"});
    Require(result.exitCode == scene_converter::ExitCode::success, "Expected batch arguments to parse.");
    Require(result.commandLine.outputMode == scene_converter::OutputMode::json, "Expected JSON output mode.");
    Require(result.commandLine.quiet, "Expected quiet mode.");
    Require(result.commandLine.batchRequested, "Expected batch mode.");
    Require(result.commandLine.outputExtension == L".usdc", "Expected normalized output extension.");

    const scene_converter::ParseResult positional = scene_converter::ParseArguments({L"asset.fbx", L"asset.usdc"});
    Require(positional.exitCode == scene_converter::ExitCode::success && positional.commandLine.hasExplicitOutput,
            "Two positional paths must retain input/output semantics.");

    const scene_converter::ParseResult duplicateJson =
        scene_converter::ParseArguments({L"asset.fbx", L"--json", L"--json"});
    Require(duplicateJson.exitCode == scene_converter::ExitCode::usageError, "Duplicate --json must fail.");

    Require(scene_converter::internal::ContainsOptionBeforeEndOfOptions({L"--json", L"--", L"--quiet"}, L"--json"),
            "Options before -- must be detected.");
    Require(!scene_converter::internal::ContainsOptionBeforeEndOfOptions({L"--", L"--json"}, L"--json"),
            "Arguments after -- must not change output mode.");
    Require(!scene_converter::internal::ContainsOptionBeforeEndOfOptions({L"-o", L"--json"}, L"--json"),
            "An option value must not be mistaken for a standalone flag.");
    Require(scene_converter::internal::ContainsOptionBeforeEndOfOptions({L"-o", L"--", L"--json"}, L"--json"),
            "An end-of-options token used as a value must not stop option detection.");
}

void TestPathKeys(const fs::path& root) {
    const fs::path directory = root / "keys";

    Require(scene_converter::internal::GetPathKey(directory) ==
                scene_converter::internal::GetPathKey(directory.wstring() + L"\\"),
            "A trailing separator must not change a path key.");
    Require(scene_converter::internal::GetPathKey(directory) ==
                scene_converter::internal::GetPathKey(directory / L"."),
            "A trailing '.' must not change a path key.");
    Require(scene_converter::internal::GetPathKey(directory) ==
                scene_converter::internal::GetPathKey(directory / L"sub" / L".."),
            "A trailing '..' must not change a path key.");
    Require(scene_converter::internal::GetPathKey(directory) !=
                scene_converter::internal::GetPathKey(root / "keys2"),
            "Distinct sibling directories must not share a path key.");

    // Unlike GetPathKey, GetAbsolutePath must NOT drop a trailing separator: on an
    // -o value it signals a directory, which ConvertFile rejects via empty filename().
    std::error_code errorCode;
    const fs::path resolved = scene_converter::internal::GetAbsolutePath(directory.wstring() + L"\\", errorCode);
    Require(!errorCode && resolved.filename().empty(),
            "GetAbsolutePath must preserve a trailing separator.");

    const std::wstring driveRootKey = scene_converter::internal::GetPathKey(L"C:\\");
    Require(!driveRootKey.empty() && driveRootKey.back() == L'\\',
            "A drive root must keep its trailing separator.");

    Require(scene_converter::internal::GetPathKey(L"C:\\dir\\\u00C4sset.fbx") ==
                scene_converter::internal::GetPathKey(L"C:\\dir\\\u00E4sset.fbx"),
            "Path keys must fold Latin-1 case.");
    Require(scene_converter::internal::GetPathKey(L"C:\\dir\\\u0416.fbx") ==
                scene_converter::internal::GetPathKey(L"C:\\dir\\\u0436.fbx"),
            "Path keys must fold Cyrillic case.");
    Require(scene_converter::internal::GetPathKey(L"C:\\dir\\ASSET.FBX") ==
                scene_converter::internal::GetPathKey(L"C:\\dir\\asset.fbx"),
            "Path keys must fold ASCII case.");

    Require(scene_converter::internal::IsPathWithin(directory.wstring() + L"\\", directory),
            "A trailing separator must not defeat a containment check.");
    Require(scene_converter::internal::IsPathWithin(directory / "child", directory),
            "A nested path must be reported as contained.");
    Require(!scene_converter::internal::IsPathWithin(directory, directory / "child"),
            "A parent must not be reported as contained in its child.");
}

void TestOutputDirectoryGuard(const fs::path& root) {
    const fs::path sourceRoot = root / "guard";
    WriteText(sourceRoot / "hero.fbx", "fixture");

    // A trailing separator (as shell completion appends) must not let --output-dir
    // alias one of its own inputs.
    const scene_converter::ParseResult parsed =
        scene_converter::ParseArguments({sourceRoot.wstring() + L"\\", L"--output-dir", sourceRoot.wstring(),
                                         L"--recursive", L"--output-format", L"usdc"});
    Require(parsed.exitCode == scene_converter::ExitCode::success, "Guard fixture arguments should parse.");

    const scene_converter::JobPlan plan = scene_converter::BuildJobPlan(parsed.commandLine);
    Require(plan.exitCode == scene_converter::ExitCode::usageError,
            "A trailing separator must not bypass the --output-dir guard.");
}

void TestJobPlanning(const fs::path& root) {
    const fs::path sourceRoot = root / "assets";
    WriteText(sourceRoot / "hero.fbx", "fixture");
    WriteText(sourceRoot / "nested" / "prop.obj", "fixture");

    const scene_converter::ParseResult parsed = scene_converter::ParseArguments(
        {sourceRoot.wstring(), L"--recursive", L"--output-dir", (root / "converted").wstring(),
         L"--output-format", L"usdc"});
    Require(parsed.exitCode == scene_converter::ExitCode::success, "Recursive arguments should parse.");

    const scene_converter::JobPlan plan = scene_converter::BuildJobPlan(parsed.commandLine);
    Require(plan.exitCode == scene_converter::ExitCode::success, "Recursive plan should succeed.");
    Require(plan.jobs.size() == 2, "Recursive plan should contain two jobs.");
    Require(plan.jobs[0].outputPath.filename() == L"hero_converted.usdc", "Expected converted hero name.");
    Require(plan.jobs[1].outputPath.parent_path().filename() == L"nested", "Expected preserved nested layout.");

    const scene_converter::ParseResult duplicateParsed = scene_converter::ParseArguments(
        {(sourceRoot / "hero.fbx").wstring(), (sourceRoot / "hero.fbx").wstring(), L"--output-format", L"usdc"});
    const scene_converter::JobPlan duplicatePlan = scene_converter::BuildJobPlan(duplicateParsed.commandLine);
    Require(duplicatePlan.exitCode == scene_converter::ExitCode::success && duplicatePlan.jobs.size() == 1,
            "Duplicate inputs should collapse to one job.");

    WriteText(root / "collision" / "asset.usda", "fixture");
    WriteText(root / "collision" / "asset_converted.usda", "fixture");
    const scene_converter::ParseResult collisionParsed = scene_converter::ParseArguments(
        {(root / "collision" / "asset.usda").wstring(), (root / "collision" / "asset_converted.usda").wstring(),
         L"--output-format", L"usda"});
    const scene_converter::JobPlan collisionPlan = scene_converter::BuildJobPlan(collisionParsed.commandLine);
    Require(collisionPlan.exitCode == scene_converter::ExitCode::usageError,
            "A planned output that collides with an input must fail.");
}

void TestOutputTransaction(const fs::path& root) {
    const fs::path outputRoot = root / "transaction";
    const fs::path stagingRoot = outputRoot / ".stage";
    WriteText(stagingRoot / "scene.gltf", "new-main");
    WriteText(stagingRoot / "scene.bin", "new-sidecar");
    WriteText(outputRoot / "scene.gltf", "old-main");

    const scene_converter::internal::CommitResult refused =
        scene_converter::internal::CommitStagedFiles(stagingRoot, outputRoot, false);
    Require(refused.exitCode == scene_converter::ExitCode::usageError,
            "Existing output should be preserved without force.");

    Require(ReadText(outputRoot / "scene.gltf") == "old-main",
            "Refused commit must preserve the original output.");

    const scene_converter::internal::CommitResult committed =
        scene_converter::internal::CommitStagedFiles(stagingRoot, outputRoot, true);
    Require(committed.exitCode == scene_converter::ExitCode::success,
            "Forced transaction should commit: " + committed.message);
    Require(committed.generatedFiles.size() == 2, "Transaction should report the main file and sidecar.");
    Require(committed.generatedFiles[0].filename() == L"scene.bin" &&
                committed.generatedFiles[1].filename() == L"scene.gltf",
            "Generated files should be reported in deterministic path order.");
    Require(fs::is_regular_file(outputRoot / "scene.gltf") && fs::is_regular_file(outputRoot / "scene.bin"),
            "Transaction should commit all staged files.");
}

void TestOutputTransactionRollback(const fs::path& root) {
    const fs::path outputRoot = root / "rollback";
    const fs::path stagingRoot = outputRoot / ".stage";

    // The failure must land inside the commit loop, after "first.gltf" is backed up
    // and committed, so rollback is actually exercised. A non-regular existing
    // target would instead be rejected during preflight, before any rollback. Here
    // the second file commits into "sub/", and a regular file named "sub" makes its
    // create_directories fail once "first.gltf" is already in place.
    WriteText(stagingRoot / "first.gltf", "new-first");
    WriteText(stagingRoot / "sub" / "second.gltf", "new-second");
    WriteText(outputRoot / "first.gltf", "old-first");
    WriteText(outputRoot / "sub", "not a directory");

    const scene_converter::internal::CommitResult result =
        scene_converter::internal::CommitStagedFiles(stagingRoot, outputRoot, true);
    Require(result.exitCode == scene_converter::ExitCode::outputError,
            "A failed mid-commit move must report an output error.");
    Require(result.generatedFiles.empty(), "A rolled-back transaction must report no generated files.");

    Require(fs::is_regular_file(outputRoot / "first.gltf") &&
                ReadText(outputRoot / "first.gltf") == "old-first",
            "Rollback must restore the first output from its backup.");
    Require(ReadText(outputRoot / "sub") == "not a directory",
            "Rollback must not disturb the blocking file.");

    // Staging removal is the signal rollback actually ran: the preflight bail-out
    // path never touches it.
    Require(!fs::exists(stagingRoot), "A completed rollback must remove the staging directory.");
    for (const fs::directory_entry& entry : fs::directory_iterator(outputRoot)) {
        const std::wstring name = entry.path().filename().wstring();
        Require(name.rfind(L".usdconvert-backup", 0) != 0 && name.rfind(L".usdconvert-stage", 0) != 0,
                "A fully restored rollback must leave no temporary directories.");
    }
}

void TestJsonRendering() {
    scene_converter::ExecutionResult result;
    result.exitCode = scene_converter::ExitCode::batchError;
    result.message = "A quoted \"message\"\nwith a newline.";
    result.succeededCount = 1;
    result.failedCount = 1;
    result.jobs.push_back({L"C:/input one.fbx", L"C:/output.usdc", {L"C:/output.usdc"},
                           scene_converter::ExitCode::success, {}});
    result.jobs.push_back({L"C:/bad.fbx", L"C:/bad.usdc", {}, scene_converter::ExitCode::inputError,
                           "Could not open input."});

    const std::string json = scene_converter::RenderJson(result);
    Require(json.find("\"schema_version\":1") != std::string::npos, "JSON must include a schema version.");
    Require(json.find("\\\"message\\\"") != std::string::npos, "JSON must escape quotes.");
    Require(json.find("\\n") != std::string::npos, "JSON must escape newlines.");
    Require(json.find("\"failed\":1") != std::string::npos, "JSON must include summary counts.");
    Require(json.find("\"generated_files\":[\"C:/output.usdc\"]") != std::string::npos,
            "JSON must include generated files.");
}

}  // namespace

int main() {
    try {
        const fs::path root = MakeTestRoot();
        TestArgumentParsing();
        TestPathKeys(root);
        TestOutputDirectoryGuard(root);
        TestJobPlanning(root);
        TestOutputTransaction(root);
        TestOutputTransactionRollback(root);
        TestJsonRendering();
        std::error_code errorCode;
        fs::remove_all(root, errorCode);
        std::cout << "All native core tests passed.\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
