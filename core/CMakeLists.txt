cmake_minimum_required(VERSION 3.20)
project(QixiCore LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

add_library(qixi_core
  src/core_types.cpp
  src/board.cpp
  src/mcts.cpp
  src/request_pool.cpp
)

target_include_directories(qixi_core PUBLIC include)

add_executable(qixi_core_smoke
  tests/qixi_core_smoke.cpp
)

target_link_libraries(qixi_core_smoke PRIVATE qixi_core)

add_executable(qixi_core_invariants
  tests/qixi_core_invariants.cpp
)

target_link_libraries(qixi_core_invariants PRIVATE qixi_core)

add_executable(qixi_core_store_bundle
  tests/qixi_core_store_bundle.cpp
)

target_link_libraries(qixi_core_store_bundle PRIVATE qixi_core)

enable_testing()
add_test(NAME qixi_core_smoke COMMAND qixi_core_smoke)
add_test(NAME qixi_core_invariants COMMAND qixi_core_invariants)
add_test(NAME qixi_core_store_bundle COMMAND qixi_core_store_bundle)
