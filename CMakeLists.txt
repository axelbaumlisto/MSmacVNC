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
# 0.9.15 reverted detached client threads; rfbShutdownServer(..., TRUE)
# synchronously joins client/listener threads before rfbScreen cleanup.
find_package(LibVNCServer 0.9.15 REQUIRED)
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
    src/RFBKeySym.h
    src/RFBKeySym.c
    src/DisplayLayout.h
    src/DisplayLayout.c
    src/CompositeFramebuffer.h
    src/CompositeFramebuffer.c
    src/PointerState.h
    src/PointerState.c
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

include(CTest)
if(BUILD_TESTING)
    add_executable(test_keysym tests/test_keysym.c src/RFBKeySym.c)
    target_include_directories(test_keysym PRIVATE src)
    add_test(NAME keysym_mapping COMMAND test_keysym)

    add_executable(test_display_layout tests/test_display_layout.c src/DisplayLayout.c)
    target_include_directories(test_display_layout PRIVATE src)
    add_test(NAME display_layout COMMAND test_display_layout)

    add_executable(test_compositor tests/test_compositor.c src/CompositeFramebuffer.c)
    target_include_directories(test_compositor PRIVATE src)
    add_test(NAME compositor COMMAND test_compositor)

    add_executable(test_pointer_state tests/test_pointer_state.c src/PointerState.c)
    target_include_directories(test_pointer_state PRIVATE src)
    add_test(NAME pointer_state COMMAND test_pointer_state)

    foreach(test_target test_keysym test_display_layout test_compositor test_pointer_state)
        target_compile_options(${test_target} PRIVATE -UNDEBUG)
    endforeach()
endif()
