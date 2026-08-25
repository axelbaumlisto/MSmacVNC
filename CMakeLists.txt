cmake_minimum_required(VERSION 3.18)
project(macVNC VERSION 0.3.23 LANGUAGES C)

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
find_library(SECURITY_LIBRARY       Security REQUIRED)
find_library(APPLICATION_SERVICES   ApplicationServices REQUIRED)

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
    src/KeyboardModifierState.h
    src/KeyboardModifierState.c
    src/CaptureRate.h
    src/CaptureRate.c
    src/FrameMailbox.h
    src/FrameMailbox.c
    src/ReadinessPolicy.h
    src/ReadinessPolicy.c
    src/NetworkAccess.h
    src/NetworkAccess.c
    src/NetworkCIDR.h
    src/NetworkCIDR.c
    src/NetworkInventory.h
    src/NetworkInventory.c
    src/NetworkPolicyResolver.h
    src/NetworkPolicyResolver.c
    src/MacVNCDisplayWake.h
    src/MacVNCDisplayWake.m
    src/MacVNCPowerMgmt.h
    src/MacVNCPowerMgmt.m
    src/MacVNCInput.h
    src/MacVNCInput.m
    src/MacVNCDefaultsKeys.h
    src/MacVNCDefaultsKeys.m
    src/MacVNCListenMode.h
    src/MacVNCListenMode.m
    src/MacVNCListenModeNames.h
    src/MacVNCLoginItem.h
    src/MacVNCLoginItem.m
    src/MacVNCStartupConfig.h
    src/MacVNCStartupConfig.m
    src/MacVNCNetworkRows.h
    src/MacVNCNetworkRows.m
    src/MacVNCPreferences.h
    src/MacVNCPreferences.m
    src/MacVNCPermissions.h
    src/MacVNCPermissions.m
    src/MacVNCPassword.h
    src/MacVNCPassword.m
    src/MacVNCPermissionsPanel.h
    src/MacVNCPermissionsPanel.m
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
    ${SECURITY_LIBRARY}
    ${APPLICATION_SERVICES}
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

    add_executable(test_keyboard_modifiers tests/test_keyboard_modifiers.c src/KeyboardModifierState.c)
    target_include_directories(test_keyboard_modifiers PRIVATE src)
    add_test(NAME keyboard_modifiers COMMAND test_keyboard_modifiers)

    add_executable(test_capture_rate tests/test_capture_rate.c src/CaptureRate.c)
    target_include_directories(test_capture_rate PRIVATE src)
    add_test(NAME capture_rate COMMAND test_capture_rate)

    add_executable(test_frame_mailbox tests/test_frame_mailbox.c src/FrameMailbox.c)
    target_include_directories(test_frame_mailbox PRIVATE src)
    target_link_libraries(test_frame_mailbox Threads::Threads)
    add_test(NAME frame_mailbox COMMAND test_frame_mailbox)

    add_executable(test_readiness_policy tests/test_readiness_policy.c src/ReadinessPolicy.c)
    target_include_directories(test_readiness_policy PRIVATE src)
    add_test(NAME readiness_policy COMMAND test_readiness_policy)

    add_executable(test_network_access tests/test_network_access.c src/NetworkAccess.c)
    target_include_directories(test_network_access PRIVATE src)
    add_test(NAME network_access COMMAND test_network_access)

    add_executable(test_network_cidr tests/test_network_cidr.c src/NetworkCIDR.c src/NetworkAccess.c)
    target_include_directories(test_network_cidr PRIVATE src)
    add_test(NAME network_cidr COMMAND test_network_cidr)

    add_executable(test_network_inventory tests/test_network_inventory.c src/NetworkInventory.c src/NetworkCIDR.c src/NetworkAccess.c)
    target_include_directories(test_network_inventory PRIVATE src)
    add_test(NAME network_inventory COMMAND test_network_inventory)

    add_executable(test_network_policy_resolver tests/test_network_policy_resolver.c src/NetworkPolicyResolver.c src/NetworkAccess.c)
    target_include_directories(test_network_policy_resolver PRIVATE src)
    add_test(NAME network_policy_resolver COMMAND test_network_policy_resolver)

    add_executable(test_permissions tests/test_permissions.m src/MacVNCPermissions.m)
    target_include_directories(test_permissions PRIVATE src)
    target_link_libraries(test_permissions ${FOUNDATION} ${APPKIT_LIBRARY} ${APPLICATION_SERVICES})
    add_test(NAME permissions COMMAND test_permissions)

    add_executable(test_listen_mode tests/test_listen_mode.m src/MacVNCListenMode.m)
    target_include_directories(test_listen_mode PRIVATE src)
    target_link_libraries(test_listen_mode ${FOUNDATION})
    add_test(NAME listen_mode COMMAND test_listen_mode)

    add_executable(test_startup_config
        tests/test_startup_config.m
        src/MacVNCStartupConfig.m
        src/MacVNCListenMode.m
        src/MacVNCDefaultsKeys.m
        src/MacVNCPassword.m
        src/CaptureRate.c
        src/NetworkPolicyResolver.c
        src/NetworkAccess.c
        src/NetworkCIDR.c
    )
    target_include_directories(test_startup_config PRIVATE src)
    target_link_libraries(test_startup_config
        LibVNCServer::vncserver
        ${FOUNDATION}
        ${SECURITY_LIBRARY}
    )
    add_test(NAME startup_config COMMAND test_startup_config)

    add_executable(test_input_context
        tests/test_input_context.m
        src/MacVNCInput.m
        src/RFBKeySym.c
        src/DisplayLayout.c
        src/PointerState.c
        src/KeyboardModifierState.c
        src/MacVNCPowerMgmt.m
        src/ReadinessPolicy.c
    )
    target_include_directories(test_input_context PRIVATE src)
    target_link_libraries(test_input_context
        LibVNCServer::vncserver
        ${CMAKE_THREAD_LIBS_INIT}
        ${CARBON_LIBRARY}
        ${IOKIT_LIBRARY}
        ${FOUNDATION}
        ${APPKIT_LIBRARY}
    )
    add_test(NAME input_context COMMAND test_input_context)

    add_executable(test_server_init_failure
        tests/test_server_init_failure.m
        src/mac.m
        src/RFBKeySym.c
        src/DisplayLayout.c
        src/CompositeFramebuffer.c
        src/PointerState.c
        src/KeyboardModifierState.c
        src/CaptureRate.c
        src/FrameMailbox.c
        src/ReadinessPolicy.c
        src/NetworkAccess.c
        src/NetworkCIDR.c
        src/NetworkInventory.c
        src/NetworkPolicyResolver.c
        src/MacVNCDisplayWake.m
        src/MacVNCPowerMgmt.m
        src/MacVNCInput.m
        src/ScreenCapturer.m
    )
    target_include_directories(test_server_init_failure PRIVATE src)
    target_compile_definitions(test_server_init_failure PRIVATE MACVNC_ENABLE_TEST_HOOKS=1)
    target_link_libraries(test_server_init_failure
        LibVNCServer::vncserver
        ${CMAKE_THREAD_LIBS_INIT}
        ${CARBON_LIBRARY}
        ${IOKIT_LIBRARY}
        ${SCREEN_CAPTURE_KIT}
        ${CORE_MEDIA}
        ${CORE_VIDEO}
        ${FOUNDATION}
        ${APPKIT_LIBRARY}
    )
    add_test(NAME server_init_failure COMMAND test_server_init_failure)
    set_tests_properties(server_init_failure PROPERTIES SKIP_RETURN_CODE 77)

    add_test(NAME client_allowlist
        COMMAND python3 ${CMAKE_CURRENT_SOURCE_DIR}/tests/test_client_allowlist.py
                --app $<TARGET_FILE:${PROJECT_NAME}>
    )

    foreach(test_target test_keysym test_display_layout test_compositor test_pointer_state test_keyboard_modifiers test_capture_rate test_frame_mailbox test_readiness_policy test_network_access test_network_cidr test_network_inventory test_network_policy_resolver test_permissions test_listen_mode test_startup_config test_input_context test_server_init_failure)
        target_compile_options(${test_target} PRIVATE -UNDEBUG)
    endforeach()
endif()
