cmake_minimum_required(VERSION 3.27)

project(universal_scene_converter VERSION 0.6.4 LANGUAGES CXX)

include(CTest)

set(USD_ROOT "" CACHE PATH "Path to the ABI-matched OpenUSD installation")
if(NOT USD_ROOT)
    message(FATAL_ERROR "USD_ROOT must point to the OpenUSD installation.")
endif()

cmake_path(SET USD_ROOT_NORMALIZED NORMALIZE "${USD_ROOT}")
message(STATUS "Using OpenUSD installation: ${USD_ROOT_NORMALIZED}")

find_path(USD_INCLUDE_DIR pxr/pxr.h PATHS "${USD_ROOT_NORMALIZED}/include" NO_DEFAULT_PATH REQUIRED)
find_library(USD_PLUG_LIBRARY NAMES usd_plug plug PATHS "${USD_ROOT_NORMALIZED}/lib" NO_DEFAULT_PATH REQUIRED)
find_library(USD_SDF_LIBRARY NAMES usd_sdf sdf PATHS "${USD_ROOT_NORMALIZED}/lib" NO_DEFAULT_PATH REQUIRED)
find_library(USD_TF_LIBRARY NAMES usd_tf tf PATHS "${USD_ROOT_NORMALIZED}/lib" NO_DEFAULT_PATH REQUIRED)
find_library(TBB_LIBRARY NAMES tbb12 tbb PATHS "${USD_ROOT_NORMALIZED}/lib" NO_DEFAULT_PATH REQUIRED)

set(CONVERTER_CORE_SOURCES
    src/arguments.cpp
    src/converter.cpp
    src/job_plan.cpp
    src/output_transaction.cpp
    src/path_utils.cpp
    src/plugin_runtime.cpp
    src/result_output.cpp
)

add_library(converter_core STATIC ${CONVERTER_CORE_SOURCES})
target_compile_features(converter_core PRIVATE cxx_std_17)
target_include_directories(converter_core PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/src")
target_include_directories(converter_core SYSTEM PRIVATE "${USD_INCLUDE_DIR}")
target_link_libraries(
    converter_core
    PUBLIC
        "${USD_PLUG_LIBRARY}"
        "${USD_SDF_LIBRARY}"
        "${USD_TF_LIBRARY}"
        "${TBB_LIBRARY}"
)
target_compile_definitions(converter_core PRIVATE SCENE_CONVERTER_VERSION="${PROJECT_VERSION}")

add_executable(usdconvert src/usdconvert.cpp)
target_compile_features(usdconvert PRIVATE cxx_std_17)
target_link_libraries(usdconvert PRIVATE converter_core)

function(configure_project_target target_name)
    if(MSVC)
        target_compile_definitions(${target_name} PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN)
        target_compile_options(${target_name} PRIVATE /W4 /permissive- /EHsc /external:W0)
    endif()
endfunction()

configure_project_target(converter_core)
configure_project_target(usdconvert)

if(BUILD_TESTING)
    add_executable(converter_core_tests tests/native/test_core.cpp)
    target_compile_features(converter_core_tests PRIVATE cxx_std_17)
    target_include_directories(converter_core_tests PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/src")
    target_link_libraries(converter_core_tests PRIVATE converter_core)
    configure_project_target(converter_core_tests)
    add_test(NAME converter_core_tests COMMAND converter_core_tests)
endif()

install(TARGETS usdconvert RUNTIME DESTINATION bin)
