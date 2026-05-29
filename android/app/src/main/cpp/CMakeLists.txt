cmake_minimum_required(VERSION 3.10)
project(game_texture)

add_library(
    game_texture
    SHARED
    game_texture_android.cpp
    ../../../../../native/game_texture/src/game_texture_upload.cc
    emulator_loop_android.cpp
    ../../../../../native/emulator_loop/src/emulator_loop.cpp
)

target_include_directories(
    game_texture
    PRIVATE
    ../../../../../native/game_texture/include
    ../../../../../native/emulator_loop/include
)

target_compile_options(game_texture PRIVATE -std=c++17)

find_library(log-lib log)
find_library(android-lib android)

target_link_libraries(
    game_texture
    ${log-lib}
    ${android-lib}
)
