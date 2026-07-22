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

    std::ifstream oldMain(outputRoot / "scene.gltf", std::ios::binary);
    std::string oldText;
    oldMain >> oldText;
    oldMain.close();
    Require(oldText == "old-main", "Refused commit must preserve the original output.");

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
        TestJobPlanning(root);
        TestOutputTransaction(root);
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
