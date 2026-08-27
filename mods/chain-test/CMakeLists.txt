cmake_minimum_required(VERSION 3.20)
project(ChainTestMod LANGUAGES C)

# Modelled on ModernGekko's mod-template, minus MOD_PATCH_ADDRESS: this mod
# registers hooks rather than a patch, so it needs no single patch address.
set(MODERNGEKKO_SOURCE_DIR "" CACHE PATH "ModernGekko checkout")
set(MOD_GAME_ID     ""            CACHE STRING "Target disc ID")
set(MOD_ID          "chain_test"  CACHE STRING "Mod ID")
set(MOD_VERSION     "1.0.0"       CACHE STRING "Mod version")
set(MOD_DISPLAY_NAME "Chain Test" CACHE STRING "Mod display name")

if(NOT IS_DIRECTORY "${MODERNGEKKO_SOURCE_DIR}/include/moderngekko")
    message(FATAL_ERROR "Set MODERNGEKKO_SOURCE_DIR to the ModernGekko checkout")
endif()
if(MOD_GAME_ID STREQUAL "")
    message(FATAL_ERROR "Set MOD_GAME_ID to the target disc ID")
endif()

add_library(mod SHARED mod.c)
target_include_directories(mod PRIVATE "${MODERNGEKKO_SOURCE_DIR}/include")
target_compile_definitions(mod PRIVATE
    MOD_GAME_ID="${MOD_GAME_ID}"
    MOD_ID="${MOD_ID}"
    MOD_VERSION="${MOD_VERSION}"
    MOD_DISPLAY_NAME="${MOD_DISPLAY_NAME}"
)

# A .mgm package is a DIRECTORY named <id>.mgm containing the platform library
# under the exact name "mod" -- DiscoverModSources() looks for
# <package>/mod<suffix> and reports "package has no platform mod library"
# otherwise. PREFIX is cleared so MinGW does not emit libmod.dll.
set_target_properties(mod PROPERTIES
    PREFIX ""
    OUTPUT_NAME "mod"
    LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/${MOD_ID}.mgm"
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/${MOD_ID}.mgm"
)
