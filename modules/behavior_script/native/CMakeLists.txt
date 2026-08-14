cmake_minimum_required(VERSION 3.20)
project(kadath_behavior_script LANGUAGES C CXX)

set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(LUAU_BUILD_CLI OFF CACHE BOOL "" FORCE)
set(LUAU_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(LUAU_BUILD_WEB OFF CACHE BOOL "" FORCE)
set(LUAU_BUILD_SHARED OFF CACHE BOOL "" FORCE)

add_subdirectory(${CMAKE_CURRENT_LIST_DIR}/../../../third_party/luau-0.732 ${CMAKE_CURRENT_BINARY_DIR}/luau)

set(KADATH_ABI_DIR ${CMAKE_CURRENT_LIST_DIR}/../../../abi)

add_library(kadath_luau_runtime STATIC runtime_bridge.cpp)
target_compile_features(kadath_luau_runtime PRIVATE cxx_std_17)
target_include_directories(kadath_luau_runtime PUBLIC ${CMAKE_CURRENT_LIST_DIR} ${KADATH_ABI_DIR})
target_link_libraries(kadath_luau_runtime PUBLIC Luau.VM)

add_library(kadath_luau_tooling STATIC tooling_bridge.cpp)
target_compile_features(kadath_luau_tooling PRIVATE cxx_std_17)
target_include_directories(kadath_luau_tooling PUBLIC ${CMAKE_CURRENT_LIST_DIR} ${KADATH_ABI_DIR})
target_link_libraries(kadath_luau_tooling PUBLIC Luau.Analysis Luau.Compiler Luau.VM)
