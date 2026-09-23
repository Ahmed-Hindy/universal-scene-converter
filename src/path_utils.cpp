#include "internal.h"

#include <windows.h>

#include <algorithm>
#include <cwctype>

namespace scene_converter {

int ToInt(ExitCode exitCode) {
    return static_cast<int>(exitCode);
}

std::string PathToUtf8(const fs::path& path) {
    return internal::ToUtf8(path.wstring());
}

namespace internal {

std::string ToUtf8(std::wstring_view value) {
    if (value.empty()) {
        return {};
    }

    const int requiredSize = WideCharToMultiByte(
        CP_UTF8, WC_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
    if (requiredSize <= 0) {
        return {};
    }

    std::string result(static_cast<std::size_t>(requiredSize), '\0');
    const int convertedSize = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
                                                  static_cast<int>(value.size()), result.data(), requiredSize,
                                                  nullptr, nullptr);
    if (convertedSize != requiredSize) {
        return {};
    }
    return result;
}

std::wstring ToLower(std::wstring value) {
    std::transform(value.begin(), value.end(), value.begin(),
                   [](wchar_t character) { return static_cast<wchar_t>(std::towlower(character)); });
    return value;
}

namespace {

std::wstring GetAbsolutePathWide(const std::wstring& path) {
    const DWORD requiredSize = GetFullPathNameW(path.c_str(), 0, nullptr, nullptr);
    if (requiredSize == 0) {
        return {};
    }

    std::wstring result(requiredSize, L'\0');
    const DWORD writtenSize = GetFullPathNameW(path.c_str(), requiredSize, result.data(), nullptr);
    if (writtenSize == 0 || writtenSize >= requiredSize) {
        return {};
    }
    result.resize(writtenSize);
    return result;
}

// Folds case the way the file system does, so that path keys compare equal for
// any pair of names it considers identical. ToLower() is deliberately not reused
// here: it relies on std::towlower, which only folds ASCII in the default
// locale, so a pair of names differing only in the case of a non-ASCII character
// (for example U+00C4 against U+00E4) would otherwise yield two distinct keys
// for one file. Uppercase is the correct direction for case-insensitive
// comparison, matching the file system's own upcasing and the case-insensitive
// mode of CompareStringOrdinal that PathsReferToSameFile relies on.
std::wstring FoldPathCase(const std::wstring& value) {
    if (value.empty()) {
        return {};
    }

    const int sourceSize = static_cast<int>(value.size());
    const int requiredSize = LCMapStringEx(LOCALE_NAME_INVARIANT, LCMAP_UPPERCASE, value.c_str(), sourceSize, nullptr,
                                           0, nullptr, nullptr, 0);
    if (requiredSize <= 0) {
        return value;  // Unreachable for a non-empty string and constant flags.
    }

    std::wstring folded(static_cast<std::size_t>(requiredSize), L'\0');
    const int mappedSize = LCMapStringEx(LOCALE_NAME_INVARIANT, LCMAP_UPPERCASE, value.c_str(), sourceSize,
                                         folded.data(), requiredSize, nullptr, nullptr, 0);
    if (mappedSize <= 0) {
        return value;
    }
    folded.resize(static_cast<std::size_t>(mappedSize));
    return folded;
}

// Gives one location one spelling. A trailing separator shows up as an empty
// filename component, and dropping it matters because leaving "assets" and
// "assets\" distinct let a trailing separator slip past the "--output-dir must
// differ from a directory input" check and past the recursive enumeration guard
// that stops a nested output tree being re-ingested as input. A root keeps its
// separator, since a drive root and a bare drive letter denote different places.
fs::path DropRedundantTrailingSeparator(fs::path path) {
    if (!path.has_filename() && path.has_relative_path()) {
        return path.parent_path();
    }
    return path;
}

}  // namespace

// Deliberately preserves a trailing separator. Resolving a path is not the same
// as canonicalising it for comparison: GetPathKey does the latter, and callers
// here still need the distinction. A trailing separator on an -o value signals
// that the user meant a directory, and ConvertFile reports that as a usage error
// before doing any work rather than exporting to a file of that name.
fs::path GetAbsolutePath(const fs::path& path, std::error_code& errorCode) {
    return fs::absolute(path, errorCode).lexically_normal();
}

std::wstring GetPathKey(const fs::path& path) {
    fs::path absolutePath = GetAbsolutePathWide(path.wstring());
    if (absolutePath.empty()) {
        absolutePath = path.lexically_normal();
    }
    return FoldPathCase(DropRedundantTrailingSeparator(std::move(absolutePath)).wstring());
}

bool IsPathWithin(const fs::path& path, const fs::path& parentPath) {
    const std::wstring pathKey = GetPathKey(path);
    std::wstring parentKey = GetPathKey(parentPath);
    if (pathKey == parentKey) {
        return true;
    }
    if (parentKey.empty()) {
        return false;
    }
    if (parentKey.back() != L'\\' && parentKey.back() != L'/') {
        parentKey.push_back(L'\\');
    }
    return pathKey.size() > parentKey.size() && pathKey.compare(0, parentKey.size(), parentKey) == 0;
}

bool PathsReferToSameFile(const fs::path& firstPath, const fs::path& secondPath) {
    std::error_code errorCode;
    if (fs::exists(firstPath, errorCode) && !errorCode && fs::exists(secondPath, errorCode) && !errorCode &&
        fs::equivalent(firstPath, secondPath, errorCode) && !errorCode) {
        return true;
    }

    const std::wstring firstAbsolutePath = GetAbsolutePathWide(firstPath.wstring());
    const std::wstring secondAbsolutePath = GetAbsolutePathWide(secondPath.wstring());
    if (firstAbsolutePath.empty() || secondAbsolutePath.empty()) {
        return false;
    }
    return CompareStringOrdinal(firstAbsolutePath.c_str(), -1, secondAbsolutePath.c_str(), -1, TRUE) == CSTR_EQUAL;
}

const std::unordered_set<std::wstring>& GetSupportedExtensions() {
    static const std::unordered_set<std::wstring> extensions = {
        L".usd", L".usda", L".usdc", L".usdz", L".fbx", L".obj", L".stl", L".gltf", L".glb",
    };
    return extensions;
}

bool IsSupportedInputPath(const fs::path& path) {
    return GetSupportedExtensions().count(ToLower(path.extension().wstring())) != 0;
}

bool NormalizeOutputExtension(std::wstring value, std::wstring& normalizedExtension) {
    while (!value.empty() && value.front() == L'.') {
        value.erase(value.begin());
    }
    value = ToLower(std::move(value));
    if (value.empty()) {
        return false;
    }
    normalizedExtension = L"." + value;
    return GetSupportedExtensions().count(normalizedExtension) != 0;
}

fs::path BuildDefaultOutputPath(const fs::path& inputPath, const fs::path& outputParent,
                                const std::wstring& outputExtension) {
    const std::wstring stem = inputPath.stem().wstring();
    if (stem.empty() || outputExtension.empty()) {
        return {};
    }
    return outputParent / fs::path(stem + L"_converted" + outputExtension);
}

}  // namespace internal
}  // namespace scene_converter
