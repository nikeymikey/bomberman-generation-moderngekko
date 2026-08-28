cmake_minimum_required(VERSION 3.20)
project(StartingBombsMod LANGUAGES C)

# Modelled on ModernGekko's mod-template, minus MOD_PATCH_ADDRESS: this mod
# registers hooks rather than a patch, so it needs no single patch address.
set(MODERNGEKKO_SOURCE_DIR "" CACHE PATH "ModernGekko checkout")
set(MOD_GAME_ID     ""            CACHE STRING "Target disc ID")
set(MOD_ID          "starting_bombs" CACHE STRING "Mod ID")
set(MOD_VERSION     "1.0.0"       CACHE STRING "Mod version")
# ASCII only: ImGui's default font has no glyphs beyond it, so a dash or
# quote outside ASCII renders as a blank box in the launcher list.
set(MOD_DISPLAY_NAME "Battle: Starting Bombs (All Players)" CACHE STRING "Mod display name")
set(MOD_SYMBOL_HEADER ""          CACHE FILEPATH "DolRecomp generated symbol header")

if(NOT IS_DIRECTORY "${MODERNGEKKO_SOURCE_DIR}/include/moderngekko")
    message(FATAL_ERROR "Set MODERNGEKKO_SOURCE_DIR to the ModernGekko checkout")
endif()
if(MOD_GAME_ID STREQUAL "")
    message(FATAL_ERROR "Set MOD_GAME_ID to the target disc ID")
endif()

set(STARTING_BOMBS "2" CACHE STRING "Compile-time fallback when no launcher setting is present")

# Settings this mod exposes in the launcher, semicolon-separated, each
#   <key>|<label>|<choice,choice,...>|<default>
# Build-Mod.ps1 copies these into the package's mod.ini, which is what the
# launcher reads. The chosen value comes back as MGMOD_<MOD-ID>_<KEY>.
set(MOD_SETTINGS "count|Bombs per player at match start|1,2,3,4,5,6,7,8|2"
    CACHE STRING "Launcher-visible settings")

add_library(mod SHARED mod.c)
target_compile_definitions(mod PRIVATE STARTING_BOMBS=${STARTING_BOMBS}u)
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
# Force-included, so DOLRECOMP_SYMBOL_* is visible without the mod source
# having to know where the header lives. Optional by design: the mod still
# builds against raw addresses when no map has been generated.
if(NOT MOD_SYMBOL_HEADER STREQUAL "")
    if(MSVC)
        target_compile_options(mod PRIVATE "/FI${MOD_SYMBOL_HEADER}")
    else()
        target_compile_options(mod PRIVATE "-include${MOD_SYMBOL_HEADER}")
    endif()
endif()

set_target_properties(mod PROPERTIES
    PREFIX ""
    OUTPUT_NAME "mod"
    LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/${MOD_ID}.mgm"
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/${MOD_ID}.mgm"
)
