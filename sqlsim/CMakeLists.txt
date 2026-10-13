cmake_minimum_required(VERSION 3.15)
project(sqlsim VERSION 1.0.0 LANGUAGES CXX)

# Set C++ standard
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# Platform-specific settings
if(WIN32)
    # Windows: Link against ODBC32 statically
    set(ODBC_LIBRARIES odbc32.lib)
    set(PLATFORM_SOURCE src/platform_windows.cpp)
    set(PLATFORM_DEFINITION SQLSIM_PLATFORM_WINDOWS=1)
elseif(APPLE)
    # macOS: Experimental source path for future Intel and Apple Silicon
    # validation. macOS builds are not currently tested, supported, or released.
    find_package(ODBC REQUIRED)
    set(PLATFORM_SOURCE src/platform_posix.cpp)
    set(PLATFORM_DEFINITION SQLSIM_PLATFORM_MACOS=1)
elseif(CMAKE_SYSTEM_NAME STREQUAL "Linux")
    # Linux: Use unixODBC
    find_package(ODBC REQUIRED)
    set(PLATFORM_SOURCE src/platform_posix.cpp)
    set(PLATFORM_DEFINITION SQLSIM_PLATFORM_LINUX=1)
else()
    message(FATAL_ERROR "Unsupported platform: ${CMAKE_SYSTEM_NAME}")
endif()

# Include directories
include_directories(${CMAKE_SOURCE_DIR}/include)

# Source files
set(SOURCES
    src/main.cpp
    src/odbc_connection.cpp
    src/workload_simulator.cpp
    src/metrics_collector.cpp
    src/command_line_parser.cpp
    src/xel_replay.cpp
    ${PLATFORM_SOURCE}
)

# Windows version resource
if(WIN32)
    set(SOURCES ${SOURCES} src/version.rc)
endif()

# Create executable
add_executable(sqlsim ${SOURCES})

target_compile_definitions(sqlsim PRIVATE ${PLATFORM_DEFINITION})
if(NOT WIN32)
    target_include_directories(sqlsim PRIVATE ${ODBC_INCLUDE_DIRS})
endif()
if(WIN32)
    target_compile_definitions(sqlsim PRIVATE _CRT_SECURE_NO_WARNINGS)
endif()

# Link libraries
target_link_libraries(sqlsim PRIVATE ${ODBC_LIBRARIES})

# Platform-specific linking
if(UNIX AND NOT APPLE)
    target_link_libraries(sqlsim PRIVATE pthread)
endif()

# Compiler warnings
if(MSVC)
    target_compile_options(sqlsim PRIVATE /W4)
    
    # Phase 1 Optimization: Aggressive compiler optimizations for Release builds
    if(CMAKE_BUILD_TYPE STREQUAL "Release" OR NOT CMAKE_BUILD_TYPE)
        # Maximum optimization
        set(CMAKE_CXX_FLAGS_RELEASE "${CMAKE_CXX_FLAGS_RELEASE} /O2 /Ob2 /Oi /Ot /GL")
        set(CMAKE_EXE_LINKER_FLAGS_RELEASE "${CMAKE_EXE_LINKER_FLAGS_RELEASE} /LTCG")
        
        # Enable AVX2 if available (comment out if unsupported on target CPU)
        # set(CMAKE_CXX_FLAGS_RELEASE "${CMAKE_CXX_FLAGS_RELEASE} /arch:AVX2")
    endif()
    
    # Use static runtime library for portability (no need for VC++ redistributable)
    set_property(TARGET sqlsim PROPERTY
        MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
else()
    target_compile_options(sqlsim PRIVATE -Wall -Wextra -pedantic)
endif()

# Build type
if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release)
endif()

message(STATUS "Build type: ${CMAKE_BUILD_TYPE}")
message(STATUS "C++ Compiler: ${CMAKE_CXX_COMPILER}")
message(STATUS "Platform: ${CMAKE_SYSTEM_NAME}")
