cmake_minimum_required(VERSION 3.18)
project(macVNC VERSION 0.1.0 LANGUAGES C)

set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
if(CMAKE_GENERATOR MATCHES "Unix Makefiles|Ninja")
# some LSP servers expect compile_commands.json in the project root
add_custom_target(
    macvnc-copy-compile-commands ALL
    ${CMAKE_COMMAND} -E copy_if_different
        ${CMAKE_BINARY_DIR}/compile_commands.json
        ${CMAKE_CURRENT_SOURCE_DIR}
    )
endif(CMAKE_GENERATOR MATCHES "Unix Makefiles|Ninja")

#
# Dependencies
#
find_package(LibVNCServer REQUIRED)
find_package(Threads REQUIRED)
find_library(CARBON_LIBRARY         Carbon           REQUIRED)
find_library(IOKIT_LIBRARY          IOKit            REQUIRED)
find_library(SCREEN_CAPTURE_KIT     ScreenCaptureKit REQUIRED)
find_library(CORE_MEDIA             CoreMedia)
find_library(CORE_VIDEO             CoreVideo)
find_library(FOUNDATION             Foundation)
find_library(APPKIT_LIBRARY         AppKit           REQUIRED)
find_library(SERVICE_MANAGEMENT     ServiceManagement REQUIRED)

#
# Sources
#
set(SOURCE_FILES
    src/mac.h
    src/mac.m
    src/ScreenCapturer.h
    src/ScreenCapturer.m
    src/AppDelegate.h
    src/AppDelegate.m
    src/main.m
    src/icon.icns
)

#
# Bundle metadata
#
set(MACOSX_BUNDLE_COPYRIGHT          "© 2024 Christian Beier (macvnc@christianbeier.net)")
set(MACOSX_BUNDLE_SHORT_VERSION_STRING ${PROJECT_VERSION})
set(MACOSX_BUNDLE_ICON_FILE          icon.icns)
set(MACOSX_BUNDLE_GUI_IDENTIFIER     net.christianbeier.macVNC)

set_source_files_properties(src/icon.icns
    PROPERTIES MACOSX_PACKAGE_LOCATION Resources)

#
# Build bundle
#
add_executable(${PROJECT_NAME} MACOSX_BUNDLE ${SOURCE_FILES})

# Use our custom Info.plist (adds LSUIElement + CFBundleIdentifier).
set_target_properties(${PROJECT_NAME} PROPERTIES
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/src/Info.plist.in"
)

target_link_libraries(${PROJECT_NAME}
    LibVNCServer::vncserver
    ${CMAKE_THREAD_LIBS_INIT}
    ${CARBON_LIBRARY}
    ${IOKIT_LIBRARY}
    ${SCREEN_CAPTURE_KIT}
    ${CORE_MEDIA}
    ${CORE_VIDEO}
    ${FOUNDATION}
    ${APPKIT_LIBRARY}
    ${SERVICE_MANAGEMENT}
)

#
# Install — finalise bundle (fix up embedded libraries)
#
set(APP  ${CMAKE_CURRENT_BINARY_DIR}/${PROJECT_NAME}.app)
set(DIRS "")
INSTALL(CODE "
set(BU_CHMOD_BUNDLE_ITEMS ON) # as per https://cmake.org/Bug/view.php?id=13833
include(BundleUtilities)
fixup_bundle(\"${APP}\"   \"\"   \"${DIRS}\")
   " COMPONENT Runtime)
INSTALL(FILES README.md DESTINATION ${APP})

#
# Code-signing (ad-hoc) — required for SMAppService (Start at Login) to work.
# The app must be signed even if not distributed through the Mac App Store.
#
if(APPLE)
    add_custom_command(TARGET ${PROJECT_NAME} POST_BUILD
        COMMAND codesign --force --sign - "$<TARGET_BUNDLE_DIR:${PROJECT_NAME}>"
        COMMENT "Ad-hoc code-signing macVNC.app (needed for SMAppService / Start at Login)"
    )
endif()
