#include "converter_core.h"

#include <pxr/pxr.h>

#include <iomanip>
#include <iostream>
#include <sstream>
#include <string_view>

namespace scene_converter {
namespace {

std::string EscapeJson(std::string_view value) {
    std::ostringstream output;
    for (const unsigned char character : value) {
        switch (character) {
            case '"':
                output << "\\\"";
                break;
            case '\\':
                output << "\\\\";
                break;
            case '\b':
                output << "\\b";
                break;
            case '\f':
                output << "\\f";
                break;
            case '\n':
                output << "\\n";
                break;
            case '\r':
                output << "\\r";
                break;
            case '\t':
                output << "\\t";
                break;
            default:
                if (character < 0x20) {
                    output << "\\u" << std::hex << std::setw(4) << std::setfill('0')
                           << static_cast<unsigned int>(character) << std::dec;
                } else {
                    output << static_cast<char>(character);
                }
        }
    }
    return output.str();
}

std::string JsonString(std::string_view value) {
    return "\"" + EscapeJson(value) + "\"";
}

std::string StatusName(ExitCode exitCode) {
    return exitCode == ExitCode::success ? "success" : "failed";
}

}  // namespace

std::string GetUsageText() {
    return "Universal Scene Converter\n\n"
           "Single file:\n"
           "  usdconvert <input> [--force] [--json] [--quiet]\n"
           "  usdconvert <input> -o <output> [--force] [--json] [--quiet]\n"
           "  usdconvert <input> <output> [--force] [--json] [--quiet]\n\n"
           "Batch:\n"
           "  usdconvert <input> [<input> ...] [--output-dir <directory>]\n"
           "             [--output-format <extension>] [--recursive] [--force]\n"
           "             [--json] [--quiet]\n\n"
           "Directory inputs require --output-dir. Use --recursive to include subdirectories.\n"
           "Batch outputs use <name>_converted<extension>; directory layouts are preserved.\n"
           "Two bare positional paths retain the single-file <input> <output> form.\n"
           "Existing outputs are preserved unless --force is provided.\n"
           "--json writes one machine-readable result object to stdout.\n"
           "--quiet suppresses successful human-readable output while retaining errors.\n"
           "Use -- before an input path that begins with a hyphen.\n"
           "Supported formats: USD, USDA, USDC, USDZ, OBJ, STL, glTF, GLB, and FBX.\n";
}

std::string GetVersionText() {
    std::ostringstream output;
    output << "usdconvert " << SCENE_CONVERTER_VERSION << " (OpenUSD " << PXR_MAJOR_VERSION << '.' << PXR_MINOR_VERSION << '.'
           << PXR_PATCH_VERSION << ')';
    return output.str();
}

std::string RenderJson(const ExecutionResult& result) {
    std::ostringstream output;
    output << '{'
           << "\"schema_version\":1,"
           << "\"tool\":\"usdconvert\","
           << "\"version\":" << JsonString(SCENE_CONVERTER_VERSION) << ','
           << "\"openusd_version\":"
           << JsonString(std::to_string(PXR_MAJOR_VERSION) + "." + std::to_string(PXR_MINOR_VERSION) + "." +
                         std::to_string(PXR_PATCH_VERSION))
           << ','
           << "\"success\":" << (result.exitCode == ExitCode::success ? "true" : "false") << ','
           << "\"exit_code\":" << ToInt(result.exitCode) << ','
           << "\"message\":" << JsonString(result.message) << ','
           << "\"jobs\":[";

    for (std::size_t jobIndex = 0; jobIndex < result.jobs.size(); ++jobIndex) {
        if (jobIndex != 0) {
            output << ',';
        }
        const JobResult& job = result.jobs[jobIndex];
        output << '{'
               << "\"input\":" << JsonString(PathToUtf8(job.inputPath)) << ','
               << "\"output\":" << JsonString(PathToUtf8(job.outputPath)) << ','
               << "\"status\":" << JsonString(StatusName(job.exitCode)) << ','
               << "\"exit_code\":" << ToInt(job.exitCode) << ','
               << "\"message\":" << JsonString(job.message) << ','
               << "\"generated_files\":[";
        for (std::size_t fileIndex = 0; fileIndex < job.generatedFiles.size(); ++fileIndex) {
            if (fileIndex != 0) {
                output << ',';
            }
            output << JsonString(PathToUtf8(job.generatedFiles[fileIndex]));
        }
        output << "]}";
    }

    output << "],\"summary\":{"
           << "\"succeeded\":" << result.succeededCount << ','
           << "\"failed\":" << result.failedCount << "}}";
    return output.str();
}

void PrintHumanResult(const ExecutionResult& result, bool quiet, bool batchMode) {
    for (std::size_t jobIndex = 0; jobIndex < result.jobs.size(); ++jobIndex) {
        const JobResult& job = result.jobs[jobIndex];
        if (batchMode && !quiet) {
            std::cout << '[' << (jobIndex + 1) << '/' << result.jobs.size() << "] " << PathToUtf8(job.inputPath) << " -> "
                      << PathToUtf8(job.outputPath) << '\n';
        }
        if (job.exitCode == ExitCode::success) {
            if (!quiet) {
                std::cout << "Wrote: " << PathToUtf8(job.outputPath) << '\n';
            }
        } else {
            std::cerr << job.message << '\n';
            if (batchMode) {
                std::cerr << "Failed with exit code " << ToInt(job.exitCode) << ": " << PathToUtf8(job.inputPath)
                          << '\n';
            }
        }
    }

    if (result.jobs.empty() && !result.message.empty()) {
        std::cerr << result.message << '\n';
    }
    if (batchMode && !quiet && !result.jobs.empty()) {
        std::cout << "Summary: " << result.succeededCount << " succeeded, " << result.failedCount << " failed.\n";
    }
}

}  // namespace scene_converter
