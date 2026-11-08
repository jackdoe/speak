cmake_minimum_required(VERSION 3.24)
project(speak LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release)
endif()

include(FetchContent)

FetchContent_Declare(onnxruntime
    URL https://github.com/microsoft/onnxruntime/releases/download/v1.31.1/onnxruntime-linux-x64-gpu_cuda12-1.31.1.tgz
    URL_HASH SHA256=57cd51f677eca19a269cdba31b0c16c15d73a8feea41f170aa8b750447ab1f70)
FetchContent_Declare(kaldi_native_fbank
    URL https://github.com/csukuangfj/kaldi-native-fbank/archive/refs/tags/v1.23.0.tar.gz
    URL_HASH SHA256=97e75ad01f486c45d6b0169a305e1e057f660fe84eb65db1aab773b732335062)
FetchContent_Declare(cudart
    URL https://files.pythonhosted.org/packages/bc/46/a92db19b8309581092a3add7e6fceb4c301a3fd233969856a8cbf042cd3c/nvidia_cuda_runtime_cu12-12.9.79-py3-none-manylinux2014_x86_64.manylinux_2_17_x86_64.whl
    URL_HASH SHA256=25bba2dfb01d48a9b59ca474a1ac43c6ebf7011f1b0b8cc44f54eb6ac48a96c3
    DOWNLOAD_NAME cudart.zip)
FetchContent_Declare(cublas
    URL https://files.pythonhosted.org/packages/7b/ea/9b6c36aef90766eebb4763aded157039e797ae9789c9c216e960d1d3cd47/nvidia_cublas_cu12-12.9.3.13-py3-none-manylinux_2_27_x86_64.whl
    URL_HASH SHA256=d7d51055f161b317c7105ddaae90e71eda059026074ffef93cf7cde2886bfe72
    DOWNLOAD_NAME cublas.zip)
set(KALDI_NATIVE_FBANK_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(KALDI_NATIVE_FBANK_BUILD_PYTHON OFF CACHE BOOL "" FORCE)
FetchContent_MakeAvailable(onnxruntime kaldi_native_fbank cudart cublas)

set(ORT_LIB ${onnxruntime_SOURCE_DIR}/lib)
set(CUDART_LIB ${cudart_SOURCE_DIR}/nvidia/cuda_runtime/lib)
set(CUBLAS_LIB ${cublas_SOURCE_DIR}/nvidia/cublas/lib)

set(LINKED_LIBS
    ${ORT_LIB}/libonnxruntime.so.1
    ${CUDART_LIB}/libcudart.so.12
    ${CUBLAS_LIB}/libcublas.so.12
    ${CUBLAS_LIB}/libcublasLt.so.12)
set(LOADED_LIBS
    ${ORT_LIB}/libonnxruntime_providers_shared.so
    ${ORT_LIB}/libonnxruntime_providers_cuda.so)

find_package(PkgConfig REQUIRED)
pkg_check_modules(DEPS REQUIRED IMPORTED_TARGET wayland-client xkbcommon libpulse-simple libpulse)
find_program(WAYLAND_SCANNER wayland-scanner REQUIRED)
find_package(Threads REQUIRED)

set(PROTOCOLS
    ${CMAKE_CURRENT_SOURCE_DIR}/protocols/virtual-keyboard-unstable-v1.xml
    ${CMAKE_CURRENT_SOURCE_DIR}/protocols/hyprland-global-shortcuts-v1.xml)

set(PROTOCOL_DIR ${CMAKE_CURRENT_BINARY_DIR}/protocols)
file(MAKE_DIRECTORY ${PROTOCOL_DIR})
foreach(xml ${PROTOCOLS})
    get_filename_component(name ${xml} NAME_WE)
    add_custom_command(
        OUTPUT ${PROTOCOL_DIR}/${name}.h ${PROTOCOL_DIR}/${name}.c
        COMMAND ${WAYLAND_SCANNER} client-header ${xml} ${PROTOCOL_DIR}/${name}.h
        COMMAND ${WAYLAND_SCANNER} private-code ${xml} ${PROTOCOL_DIR}/${name}.c
        DEPENDS ${xml}
        VERBATIM)
    list(APPEND PROTOCOL_SOURCES ${PROTOCOL_DIR}/${name}.c ${PROTOCOL_DIR}/${name}.h)
endforeach()

add_executable(speak
    src/main.cpp
    src/microphone.cpp
    src/recognizer.cpp
    src/wayland.cpp
    src/status.cpp
    src/keyboard.cpp
    ${PROTOCOL_SOURCES})

target_include_directories(speak PRIVATE src ${PROTOCOL_DIR})
target_include_directories(speak SYSTEM PRIVATE ${onnxruntime_SOURCE_DIR}/include ${kaldi_native_fbank_SOURCE_DIR})
target_compile_options(speak PRIVATE -Wall -Wextra)
target_link_libraries(speak PRIVATE
    PkgConfig::DEPS
    Threads::Threads
    kaldi-native-fbank-core
    -Wl,--no-as-needed ${LINKED_LIBS} -Wl,--as-needed)

set_target_properties(speak PROPERTIES
    BUILD_RPATH "${ORT_LIB};${CUDART_LIB};${CUBLAS_LIB}"
    INSTALL_RPATH "$ORIGIN/../lib/speak")

install(TARGETS speak RUNTIME DESTINATION bin COMPONENT speak)
foreach(lib ${LINKED_LIBS} ${LOADED_LIBS})
    get_filename_component(name ${lib} NAME)
    file(REAL_PATH ${lib} real)
    install(FILES ${real} DESTINATION lib/speak RENAME ${name} COMPONENT speak)
endforeach()
