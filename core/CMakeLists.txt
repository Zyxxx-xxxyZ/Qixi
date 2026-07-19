cmake_minimum_required(VERSION 3.20)
project(QixiCore LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

set(QIXI_CORE_SOURCES
  src/core_types.cpp
  src/board.cpp
  src/mcts.cpp
  src/request_pool.cpp
  src/oracle_compare.cpp
  src/analysis_api_custom.cpp
)

# Production core: test selection modes are compile-time disabled.
add_library(qixi_core ${QIXI_CORE_SOURCES})
target_include_directories(qixi_core PUBLIC include)
target_compile_definitions(qixi_core PUBLIC QIXI_ALLOW_TEST_SELECTION_MODES=0)

# Test-only core: same code with test selection modes permitted. Link this
# ONLY from correctness / unit-test binaries — never from the app.
add_library(qixi_core_testing ${QIXI_CORE_SOURCES})
target_include_directories(qixi_core_testing PUBLIC include)
target_compile_definitions(qixi_core_testing PUBLIC QIXI_ALLOW_TEST_SELECTION_MODES=1)

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

add_executable(qixi_oracle_scaffold
  tests/qixi_oracle_scaffold.cpp
)

target_link_libraries(qixi_oracle_scaffold PRIVATE qixi_core)

add_executable(qixi_analysis_api_smoke
  tests/qixi_analysis_api_smoke.cpp
)

target_link_libraries(qixi_analysis_api_smoke PRIVATE qixi_core)

add_executable(qixi_min_root_depth_visits
  tests/qixi_min_root_depth_visits.cpp
)

target_link_libraries(qixi_min_root_depth_visits PRIVATE qixi_core)

add_executable(qixi_split_backup
  tests/qixi_split_backup.cpp
)

target_link_libraries(qixi_split_backup PRIVATE qixi_core)

add_executable(qixi_policy_only_selection
  tests/qixi_policy_only_selection.cpp
)

# Must link the testing core so the mode can be enabled.
target_link_libraries(qixi_policy_only_selection PRIVATE qixi_core_testing)

add_executable(qixi_policy_only_selection_prod_guard
  tests/qixi_policy_only_selection_prod_guard.cpp
)

# Production core must refuse to enable the test mode.
target_link_libraries(qixi_policy_only_selection_prod_guard PRIVATE qixi_core)

add_executable(qixi_stream_deserialize
  tests/qixi_stream_deserialize.cpp
)

target_link_libraries(qixi_stream_deserialize PRIVATE qixi_core)

add_executable(qixi_store_persist_strict
  tests/qixi_store_persist_strict.cpp
)

target_link_libraries(qixi_store_persist_strict PRIVATE qixi_core)

add_executable(qixi_memory_pressure_relief
  tests/qixi_memory_pressure_relief.cpp
)

target_link_libraries(qixi_memory_pressure_relief PRIVATE qixi_core)

add_executable(qixi_edge_local_selection
  tests/qixi_edge_local_selection.cpp
)

target_link_libraries(qixi_edge_local_selection PRIVATE qixi_core)

enable_testing()
add_test(NAME qixi_core_smoke COMMAND qixi_core_smoke)
add_test(NAME qixi_core_invariants COMMAND qixi_core_invariants)
add_test(NAME qixi_core_store_bundle COMMAND qixi_core_store_bundle)
add_test(NAME qixi_oracle_scaffold COMMAND qixi_oracle_scaffold)
add_test(NAME qixi_analysis_api_smoke COMMAND qixi_analysis_api_smoke)
add_test(NAME qixi_min_root_depth_visits COMMAND qixi_min_root_depth_visits)
add_test(NAME qixi_split_backup COMMAND qixi_split_backup)
add_test(NAME qixi_policy_only_selection COMMAND qixi_policy_only_selection)
add_test(NAME qixi_policy_only_selection_prod_guard COMMAND qixi_policy_only_selection_prod_guard)
add_test(NAME qixi_stream_deserialize COMMAND qixi_stream_deserialize)
add_test(NAME qixi_store_persist_strict COMMAND qixi_store_persist_strict)
add_test(NAME qixi_memory_pressure_relief COMMAND qixi_memory_pressure_relief)
add_test(NAME qixi_edge_local_selection COMMAND qixi_edge_local_selection)
