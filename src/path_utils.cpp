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

// Folds case the way the platform does, so that path keys compare equal for any
// pair of names the file system considers identical. ToLower() is deliberately
// not reused here: it relies on std::towlower, which only folds ASCII in the
// default locale, so a pair of names differing only in the case of a non-ASCII
// character (for example U+00C4 against U+00E4) would otherwise produce two
// distinct keys for a single file. Uppercase folding mirrors the file system's
// own canonicalisation and the case-insensitive mode of CompareStringOrdinal,
// which PathsReferToSameFile already relies on.
std::wstring FoldPathCase(const std::wstring& value) {
    if (value.empty()) {
        return {};
    }

    const int sourceSize = static_cast<int>(value.size());
    const int requiredSize = LCMapStringEx(LOCALE_NAME_INVARIANT, LCMAP_UPPERCASE, value.c_str(), sourceSize, nullptr,
                                           0, nullptr, nullptr, 0);
    if (requiredSize > 0) {
        std::wstring folded(static_cast<std::size_t>(requiredSize), L'\0');
        const int mappedSize = LCMapStringEx(LOCALE_NAME_INVARIANT, LCMAP_UPPERCASE, value.c_str(), sourceSize,
                                             folded.data(), requiredSize, nullptr, nullptr, 0);
        if (mappedSize > 0) {
            folded.resize(static_cast<std::size_t>(mappedSize));
            return folded;
        }
    }

    std::wstring fallback = value;
    std::transform(fallback.begin(), fallback.end(), fallback.begin(),
                   [](wchar_t character) { return static_cast<wchar_t>(std::towupper(character)); });
    return fallback;
}

// Gives every path key one spelling for one location. Separators are unified and
// redundant trailing separators are dropped, because a directory named with and
// without a trailing separator is the same directory; leaving the two spellings
// distinct let a trailing separator slip past the "--output-dir must differ from
// a directory input" check and past the recursive enumeration guard that keeps a
// nested output tree from being re-ingested as input. The root separator is kept,
// since a drive root and a bare drive letter denote different locations.
std::wstring CanonicalizePathKeyShape(std::wstring value) {
    std::replace(value.begin(), value.end(), L'/', L'\\');

    const std::size_t rootLength = fs::path(value).root_path().wstring().size();
    while (value.size() > rootLength && value.back() == L'\\') {
        value.pop_back();
    }
    return value;
}

}  // namespace

fs::path GetAbsolutePath(const fs::path& path, std::error_code& errorCode) {
    return fs::absolute(path, errorCode).lexically_normal();
}

std::wstring GetPathKey(const fs::path& path) {
    std::wstring absolutePath = GetAbsolutePathWide(path.wstring());
    if (absolutePath.empty()) {
        absolutePath = path.lexically_normal().wstring();
    }
    return FoldPathCase(CanonicalizePathKeyShape(std::move(absolutePath)));
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
