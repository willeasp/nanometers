# Wraps the prebuilt nanometers.clap into an AUv2 .component for Logic Pro.
#
# Build flow:
#   1. cargo xtask bundle nanometers --release   (from workspace root, produces target/bundled/nanometers.clap)
#   2. cmake -B auv2/build -S auv2 -G Ninja
#   3. cmake --build auv2/build
#
# Output: auv2/build/nanometers.component (an AU bundle, copy to ~/Library/Audio/Plug-Ins/Components/).

cmake_minimum_required(VERSION 3.21)
project(nanometers_auv2 VERSION 0.0.1 LANGUAGES C CXX OBJC OBJCXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
# Logic ships back to 11.0 (Big Sur); 10.13 is the AU host minimum.
set(CMAKE_OSX_DEPLOYMENT_TARGET 10.13 CACHE STRING "macOS deployment target")

# Let clap-wrapper fetch the CLAP SDK (and AudioUnit SDK) itself, so we don't have to
# manage those as submodules or system installs.
set(CLAP_WRAPPER_DOWNLOAD_DEPENDENCIES TRUE CACHE BOOL "Let clap-wrapper download missing SDKs")
set(CLAP_WRAPPER_BUILD_AUV2 ON CACHE BOOL "Build AUv2 wrapper")

# clap-wrapper pulled via FetchContent. Pinned to a known-good ref via CLAP_WRAPPER_GIT_TAG —
# bump when there's a reason to.
set(CLAP_WRAPPER_GIT_TAG "main" CACHE STRING "clap-wrapper git ref")

include(FetchContent)
FetchContent_Declare(
  clap-wrapper
  GIT_REPOSITORY https://github.com/free-audio/clap-wrapper.git
  GIT_TAG ${CLAP_WRAPPER_GIT_TAG}
)
FetchContent_MakeAvailable(clap-wrapper)

# The MODULE library target is required by clap-wrapper — it adds sources/links to it.
add_library(nanometers_auv2 MODULE)

# Path to the prebuilt CLAP. Bundled into the .component at build time.
set(NANOMETERS_CLAP_PATH "${CMAKE_SOURCE_DIR}/../target/bundled/nanometers.clap"
    CACHE PATH "Path to prebuilt nanometers.clap bundle")

if(NOT EXISTS "${NANOMETERS_CLAP_PATH}")
  message(FATAL_ERROR
    "Could not find prebuilt CLAP at '${NANOMETERS_CLAP_PATH}'.\n"
    "Run `cargo xtask bundle nanometers --release` from the workspace root first.")
endif()

target_add_auv2_wrapper(
  TARGET           nanometers_auv2
  OUTPUT_NAME      "nanometers"
  BUNDLE_IDENTIFIER "com.willeasp.nanometers.auv2"
  BUNDLE_VERSION   "${PROJECT_VERSION}"

  # Use the values configured here instead of probing the embedded CLAP.
  PREFER_CMAKE_AUV2_CONFIGURATION TRUE

  MANUFACTURER_NAME "willeasp"
  MANUFACTURER_CODE "Wlsp"   # 4 ASCII chars, first uppercase. Picked once; never change — auval caches it.
  SUBTYPE_CODE      "Nano"   # 4 ASCII chars, unique within this manufacturer.
  INSTRUMENT_TYPE   "aufx"   # 'aufx' = Audio Effect (the right slot for meters/analyzers).

  MACOS_EMBEDDED_CLAP_LOCATION "${NANOMETERS_CLAP_PATH}"
)
