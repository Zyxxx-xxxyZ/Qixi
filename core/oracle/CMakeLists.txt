cmake_minimum_required(VERSION 3.20)
project(QixiOracle LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# Paths (override on command line if needed)
set(QIXI_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../.." CACHE PATH "Qixi repository root")
set(KATAGO_CPP "${QIXI_ROOT}/KataGo/cpp" CACHE PATH "KataGo cpp directory")
set(KATAGO_CORE_LIB "/private/tmp/qixi_katago_eigen/libkatago_core.a" CACHE FILEPATH "libkatago_core.a with Eigen backend")

# qixi_core (+ testing variant for policy-only selection in this harness only)
add_subdirectory("${QIXI_ROOT}/core" qixi_core_build)

add_executable(qixi_oracle_correctness
  correctness_harness.cpp
  host_nn_bridge.cpp
  official_analysis_api.cpp
)

target_include_directories(qixi_oracle_correctness PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}"
  "${QIXI_ROOT}/core/include"
  "${KATAGO_CPP}"
)

target_compile_definitions(qixi_oracle_correctness PRIVATE
  USE_EIGEN_BACKEND
  # TEST-ONLY: allow official/custom policy-only selection in this binary.
  # Production app must never set this. Still requires allow token at runtime.
  QIXI_ALLOW_TEST_SELECTION_MODES=1
  QIXI_ORACLE_ENABLE_POLICY_ONLY=1
)

# ARM Apple Clang needs -fsigned-char like KataGo.
if(CMAKE_SYSTEM_PROCESSOR MATCHES "arm64|aarch64")
  target_compile_options(qixi_oracle_correctness PRIVATE -fsigned-char)
endif()

find_package(Eigen3 REQUIRED)
find_package(ZLIB REQUIRED)
find_package(Threads REQUIRED)

target_link_libraries(qixi_oracle_correctness PRIVATE
  # Testing core: required so enableTestNnPolicyOnlySelection can succeed.
  # Do not link this library into the iOS app.
  qixi_core_testing
  "${KATAGO_CORE_LIB}"
  Eigen3::Eigen
  ZLIB::ZLIB
  Threads::Threads
)

# macOS system frameworks sometimes needed for clock/locale
if(APPLE)
  target_link_libraries(qixi_oracle_correctness PRIVATE "-framework Accelerate")
endif()
