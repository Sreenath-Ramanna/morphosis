# Project-level configuration.
cmake_minimum_required(VERSION 3.13)
# C is enabled alongside CXX because raw_images_api, built as a subdirectory
# below, is plain C.
project(runner LANGUAGES CXX C)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "morphosis")
# The unique GTK application identifier for this application. See:
# https://wiki.gnome.org/HowDoI/ChooseApplicationID
set(APPLICATION_ID "com.morphosis.morphosis")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(SET CMP0063 NEW)

# Load bundled libraries from the lib/ directory relative to the binary.
set(CMAKE_INSTALL_RPATH "$ORIGIN/lib")

# Root filesystem for cross-building.
if(FLUTTER_TARGET_PLATFORM_SYSROOT)
  set(CMAKE_SYSROOT ${FLUTTER_TARGET_PLATFORM_SYSROOT})
  set(CMAKE_FIND_ROOT_PATH ${CMAKE_SYSROOT})
  set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
  set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
  set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
  set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
endif()

# Define build configuration options.
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE "Debug" CACHE
    STRING "Flutter build mode" FORCE)
  set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
    "Debug" "Profile" "Release")
endif()

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_14)
  target_compile_options(${TARGET} PRIVATE -Wall -Werror)
  target_compile_options(${TARGET} PRIVATE "$<$<NOT:$<CONFIG:Debug>>:-O3>")
  target_compile_definitions(${TARGET} PRIVATE "$<$<NOT:$<CONFIG:Debug>>:NDEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# System-level dependencies.
find_package(PkgConfig REQUIRED)
pkg_check_modules(GTK REQUIRED IMPORTED_TARGET gtk+-3.0)

# === raw_images_api ===
# The RAW decoding and image processing library, developed as its own
# repository. It is built from source here and loaded at runtime through
# dart:ffi from $ORIGIN/lib/libraw_images_api.so — deliberately NOT linked
# into the runner, so a Dart-side change never requires relinking the app,
# and so the worker isolate can open its own handle on it.
#
# The default assumes it sits beside this checkout. To use one elsewhere, set
# the environment variable — `flutter build` drives CMake itself and offers no
# way to pass -D through:
#
#   RAW_IMAGES_API_DIR=/path/to/raw_images_api flutter build linux --release
#
# Configuring CMake directly, -DRAW_IMAGES_API_DIR=... works as usual.
if(DEFINED ENV{RAW_IMAGES_API_DIR})
  set(_raw_images_api_default "$ENV{RAW_IMAGES_API_DIR}")
else()
  set(_raw_images_api_default "${CMAKE_CURRENT_SOURCE_DIR}/../../raw_images_api")
endif()
set(RAW_IMAGES_API_DIR "${_raw_images_api_default}"
    CACHE PATH "Path to the raw_images_api source checkout")

if(NOT EXISTS "${RAW_IMAGES_API_DIR}/CMakeLists.txt")
  message(FATAL_ERROR
    "raw_images_api was not found at ${RAW_IMAGES_API_DIR}.\n"
    "Clone it beside this repository, or configure with "
    "-DRAW_IMAGES_API_DIR=<path>.")
endif()

# The app needs the library alone; its tool, tests and install rules would only
# add build time and clutter the bundle. The legacy raw_* ABI is off: these
# bindings speak the modern ria_* one.
set(RIA_BUILD_EXAMPLES   OFF CACHE BOOL "" FORCE)
set(RIA_BUILD_TESTS      OFF CACHE BOOL "" FORCE)
set(RIA_INSTALL          OFF CACHE BOOL "" FORCE)
set(RIA_BUILD_LEGACY_ABI OFF CACHE BOOL "" FORCE)

add_subdirectory("${RAW_IMAGES_API_DIR}" "${CMAKE_BINARY_DIR}/raw_images_api")

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)

# Ensure the decode library is built whenever the app is.
add_dependencies(${BINARY_NAME} raw_images_api)

# Only the install-generated bundle's copy of the executable will launch
# correctly, since the resources must in the right relative locations. To avoid
# people trying to run the unbundled copy, put it in a subdirectory instead of
# the default top-level location.
set_target_properties(${BINARY_NAME}
  PROPERTIES
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/intermediates_do_not_run"
)


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)


# === Installation ===
# By default, "installing" just makes a relocatable bundle in the build
# directory.
set(BUILD_BUNDLE_DIR "${PROJECT_BINARY_DIR}/bundle")
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

# Start with a clean build bundle directory every time.
install(CODE "
  file(REMOVE_RECURSE \"${BUILD_BUNDLE_DIR}/\")
  " COMPONENT Runtime)

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}/lib")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

# Place libraw_images_api.so in bundle/lib/ so the $ORIGIN/lib RPATH — and
# Ria.resolveLibraryPath on the Dart side, which looks in the same place —
# find it beside the executable rather than on the system library path.
install(TARGETS raw_images_api LIBRARY DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

foreach(bundled_library ${PLUGIN_BUNDLED_LIBRARIES})
  install(FILES "${bundled_library}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endforeach(bundled_library)

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/linux/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
if(NOT CMAKE_BUILD_TYPE MATCHES "Debug")
  install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()
