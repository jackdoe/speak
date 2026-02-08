cmake_minimum_required(VERSION 3.16)
project(speak LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_program(NVCC nvcc)
if(NVCC)
    message(STATUS "CUDA found — building with GGML_CUDA=ON")
    set(GGML_CUDA ON CACHE BOOL "" FORCE)
else()
    message(STATUS "CUDA not found — CPU-only build")
    set(GGML_CUDA OFF CACHE BOOL "" FORCE)
endif()

set(WHISPER_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/../whisper.cpp ${CMAKE_BINARY_DIR}/whisper.cpp)

find_package(PkgConfig REQUIRED)
pkg_check_modules(PULSE REQUIRED IMPORTED_TARGET libpulse-simple libpulse)
pkg_check_modules(X11 REQUIRED IMPORTED_TARGET x11)

find_package(CURL REQUIRED)
find_package(Threads REQUIRED)

find_package(nlohmann_json QUIET)
if(NOT nlohmann_json_FOUND)
    include(FetchContent)
    FetchContent_Declare(json URL https://github.com/nlohmann/json/releases/download/v3.11.3/json.tar.xz)
    FetchContent_MakeAvailable(json)
endif()

add_executable(speak
    src/main.cpp
    src/audio_engine.cpp
    src/vad.cpp
    src/whisper_context.cpp
    src/transcription_pipeline.cpp
    src/hotkey_manager.cpp
    src/text_output.cpp
    src/overlay.cpp
    src/control.cpp
    src/settings.cpp
    src/model_manager.cpp
    src/model_downloader.cpp
    src/benchmark.cpp
)

target_include_directories(speak PRIVATE src)

target_link_libraries(speak PRIVATE
    whisper
    PkgConfig::PULSE
    PkgConfig::X11
    CURL::libcurl
    Threads::Threads
    nlohmann_json::nlohmann_json
)
