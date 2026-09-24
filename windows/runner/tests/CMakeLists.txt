cmake_minimum_required(VERSION 3.14)
project(rtkmanager_windows_tests LANGUAGES CXX)

enable_testing()
add_executable(flutter_dpi_refresh_test
  flutter_dpi_refresh_test.cpp
  ../flutter_dpi_refresh.cpp
)
target_compile_features(flutter_dpi_refresh_test PRIVATE cxx_std_17)
target_compile_definitions(flutter_dpi_refresh_test PRIVATE UNICODE _UNICODE NOMINMAX)
target_compile_options(flutter_dpi_refresh_test PRIVATE /W4 /WX /EHsc)
target_link_libraries(flutter_dpi_refresh_test PRIVATE user32 wtsapi32)
add_test(NAME flutter_dpi_refresh COMMAND flutter_dpi_refresh_test)
