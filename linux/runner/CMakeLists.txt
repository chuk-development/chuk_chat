cmake_minimum_required(VERSION 3.13)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME}
  "main.cc"
  "my_application.cc"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the application ID.
add_definitions(-DAPPLICATION_ID="${APPLICATION_ID}")

# Add dependency libraries. Add any application-specific dependencies here.
# Flutter 3.50 workaround (flutter/flutter#196402): libflutter_linux_gtk.so
# exports the _Unwind_* symbols of its own static libunwind. A C++ exception
# that a plugin throws and catches itself then unwinds through that copy, no
# handler is found and the app aborts ("terminate called after throwing").
# flutter_secure_storage_linux does exactly that when there is no unlocked
# keyring, so the app died right after sign-in on such machines. Linking
# libgcc_s first puts its unwinder ahead of the engine's in the lookup order.
# Remove once the engine hides those symbols again.
target_link_options(${BINARY_NAME} PRIVATE
  "LINKER:--push-state,--no-as-needed,-lgcc_s,--pop-state")
target_link_libraries(${BINARY_NAME} PRIVATE flutter)
target_link_libraries(${BINARY_NAME} PRIVATE PkgConfig::GTK)

target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")
