//! The Abseil translation units this fork compiles, and nothing else.
//!
//! Provenance
//! ----------
//! Every path below is copied out of an `absl_cc_library(... SRCS ...)` block
//! of the vendored Abseil tree at `vendor/abseil-cpp`, which is the
//! `20250814.1` release selected by s2geometry's own `CMakeLists.txt`
//! (`FetchContent_Declare(absl URL .../20250814.1.zip)`).  The tag commit is
//! `d38452e1ee03523a208362186fd42248ff2609f6`.
//!
//! Three different Abseil versions are named inside the v0.14.0 s2geometry
//! tag: this CMake `20250814.1`, `README.md` `20250814`, and
//! `src/MODULE.bazel` `20260107.1`.  The CMake pin is the one used here,
//! because that is the build definition this fork replaces; see UPSTREAM.md.
//!
//! Why the list is enumerated rather than globbed
//! ---------------------------------------------
//! A glob over `vendor/abseil-cpp/absl/**/*.cc` would pick up 231
//! `*_test.cc` files, every `*_benchmark.cc`, and fourteen Abseil
//! "test helper" translation units that are declared `TESTONLY` or carry a
//! `GTest::` dependency in their own `DEPS`.  Those need GoogleTest, which
//! this package deliberately does not require (`zig build` must not download
//! or demand a test framework).  Enumerating the upstream `SRCS` lists is
//! what makes "the library, without its tests" a decision recorded in this
//! repository rather than an accident of a file-name pattern.
//!
//! `absl/base/internal/atomic_hook_test_helper.cc`,
//! `absl/base/internal/exception_safety_testing.cc`,
//! `absl/base/spinlock_test_common.cc`,
//! `absl/container/internal/hash_generator_testing.cc`,
//! `absl/container/internal/test_instance_tracker.cc`,
//! `absl/debugging/internal/stack_consumption.cc`,
//! `absl/log/internal/test_actions.cc`,
//! `absl/log/internal/test_helpers.cc`,
//! `absl/log/internal/test_matchers.cc`,
//! `absl/log/scoped_mock_log.cc`,
//! `absl/status/internal/status_matchers.cc`,
//! `absl/strings/internal/pow10_helper.cc`,
//! `absl/synchronization/internal/per_thread_sem_test.cc` and
//! `absl/time/internal/test_util.cc`
//! are the fourteen excluded on that basis. `absl/random`'s
//! `chi_square.cc` and `distribution_test_util.cc` are *not* among them:
//! upstream declares them in `absl_cc_library(random_internal_distribution_test_util)`
//! with no `TESTONLY` marker and no `GTest::` dependency, so they are library
//! translation units here.
//!
//! Platform variants
//! -----------------
//! Upstream's CMake also compiles every platform variant of a given unit and
//! lets the source's own `#ifdef` pick one, so this list is target
//! independent: `crc_memcpy_fallback.cc` and
//! `crc_memcpy_x86_arm_combined.cc`, `time_zone_libc.cc` and
//! `time_zone_posix.cc`, and all five `*_waiter.cc` files are each listed by
//! their upstream `absl_cc_library` block unconditionally.  Adding one of
//! them "for this target only" would be a new build decision that upstream
//! does not make.  The genuinely target-selected Abseil settings are
//! compiler flags, not source files; see `platform_flags.zig`.

/// Abseil release whose sources are vendored at `vendor/abseil-cpp`.
pub const version = "20250814.1";

/// Commit of the vendored Abseil tree.
pub const commit = "d38452e1ee03523a208362186fd42248ff2609f6";

/// Directory of the vendored Abseil tree, relative to the package root.
///
/// This is the include root: sources spell their headers `absl/base/config.h`.
pub const include_dir = "vendor/abseil-cpp";

/// Directory of the vendored Abseil headers, relative to the package root.
///
/// This is the include root's `absl/` child, and it is what gets installed
/// under `include/absl`.  Installing the include root instead would install
/// `include/absl/absl/base/config.h` and break every `absl/...` include in the
/// tree, exactly as installing `src` instead of `src/s2` would for S2.
pub const header_dir = "vendor/abseil-cpp/absl";

/// File extensions installed from the vendored Abseil tree.
///
/// `.inc` is not optional. Abseil headers `#include` implementation fragments
/// by name -- `stacktrace_x86-inl.inc`, `spinlock_linux.inc`,
/// `symbolize_elf.inc`, `spinlock_win32.inc` -- so a header-only filter would
/// install a tree whose own headers cannot be compiled.
pub const header_extensions = [_][]const u8{ ".h", ".inc" };

/// Every Abseil library translation unit this fork compiles.
///
/// Comments name the upstream `absl_cc_library` target each group belongs to,
/// so a future Abseil bump can be diffed against upstream's own lists.
pub const sources = [_][]const u8{
    // absl::log_severity
    "absl/base/log_severity.cc",
    // absl::raw_logging_internal
    "absl/base/internal/raw_logging.cc",
    // absl::spinlock_wait
    "absl/base/internal/spinlock_wait.cc",
    // absl::malloc_internal
    "absl/base/internal/low_level_alloc.cc",
    // absl::base
    "absl/base/internal/cycleclock.cc",
    "absl/base/internal/spinlock.cc",
    "absl/base/internal/sysinfo.cc",
    "absl/base/internal/thread_identity.cc",
    "absl/base/internal/unscaledcycleclock.cc",
    // absl::throw_delegate
    "absl/base/internal/throw_delegate.cc",
    // absl::scoped_set_env
    "absl/base/internal/scoped_set_env.cc",
    // absl::strerror
    "absl/base/internal/strerror.cc",
    // absl::poison
    "absl/base/internal/poison.cc",
    // absl::tracing_internal
    "absl/base/internal/tracing.cc",

    // absl::hashtablez_sampler
    "absl/container/internal/hashtablez_sampler.cc",
    "absl/container/internal/hashtablez_sampler_force_weak_definition.cc",
    // absl::raw_hash_set
    "absl/container/internal/raw_hash_set.cc",

    // absl::crc_cpu_detect, absl::crc_internal, absl::crc32c
    "absl/crc/internal/cpu_detect.cc",
    "absl/crc/internal/crc.cc",
    "absl/crc/internal/crc_x86_arm_combined.cc",
    "absl/crc/crc32c.cc",
    "absl/crc/internal/crc_memcpy_fallback.cc",
    "absl/crc/internal/crc_memcpy_x86_arm_combined.cc",
    "absl/crc/internal/crc_non_temporal_memcpy.cc",
    // absl::crc_cord_state
    "absl/crc/internal/crc_cord_state.cc",

    // absl::stacktrace, absl::symbolize, absl::debugging_internal
    "absl/debugging/stacktrace.cc",
    "absl/debugging/symbolize.cc",
    "absl/debugging/internal/examine_stack.cc",
    // absl::failure_signal_handler
    "absl/debugging/failure_signal_handler.cc",
    "absl/debugging/internal/address_is_readable.cc",
    "absl/debugging/internal/elf_mem_image.cc",
    "absl/debugging/internal/vdso_support.cc",
    // absl::demangle_internal
    "absl/debugging/internal/demangle.cc",
    // absl::decode_rust_punycode
    "absl/debugging/internal/decode_rust_punycode.cc",
    // absl::demangle_rust
    "absl/debugging/internal/demangle_rust.cc",
    // absl::utf8_for_code_point
    "absl/debugging/internal/utf8_for_code_point.cc",
    // absl::leak_check
    "absl/debugging/leak_check.cc",

    // absl::flags_program_name, absl::flags_config, absl::flags_marshalling,
    // absl::flags_commandlineflag_internal, absl::flags_commandlineflag,
    // absl::flags_private_handle_accessor, absl::flags_reflection,
    // absl::flags_internal, absl::flags_usage_internal, absl::flags_usage,
    // absl::flags_parse
    "absl/flags/internal/program_name.cc",
    "absl/flags/usage_config.cc",
    "absl/flags/marshalling.cc",
    "absl/flags/internal/commandlineflag.cc",
    "absl/flags/commandlineflag.cc",
    "absl/flags/internal/private_handle_accessor.cc",
    "absl/flags/reflection.cc",
    "absl/flags/internal/flag.cc",
    "absl/flags/internal/usage.cc",
    "absl/flags/usage.cc",
    "absl/flags/parse.cc",

    // absl::hash, absl::city
    "absl/hash/internal/hash.cc",
    "absl/hash/internal/city.cc",

    // absl::log_internal_check_op, absl::log_internal_conditions,
    // absl::log_internal_format, absl::log_internal_globals,
    // absl::log_internal_proto, absl::log_internal_message,
    // absl::log_internal_log_sink_set, absl::log_internal_nullguard
    "absl/log/internal/check_op.cc",
    "absl/log/internal/conditions.cc",
    "absl/log/internal/log_format.cc",
    "absl/log/internal/globals.cc",
    "absl/log/internal/proto.cc",
    "absl/log/internal/log_message.cc",
    "absl/log/internal/log_sink_set.cc",
    "absl/log/internal/nullguard.cc",
    // absl::die_if_null, absl::log_flags, absl::log_globals,
    // absl::log_initialize, absl::log_entry, absl::log_sink,
    // absl::log_internal_structured_proto, absl::vlog_config_internal,
    // absl::log_internal_fnmatch
    "absl/log/die_if_null.cc",
    "absl/log/flags.cc",
    "absl/log/globals.cc",
    "absl/log/initialize.cc",
    "absl/log/log_entry.cc",
    "absl/log/log_sink.cc",
    "absl/log/internal/structured_proto.cc",
    "absl/log/internal/vlog_config.cc",
    "absl/log/internal/fnmatch.cc",

    // absl::int128
    "absl/numeric/int128.cc",

    // absl::exponential_biased, absl::periodic_sampler,
    // absl::profile_builder, absl::hashtable_profiler
    "absl/profiling/internal/exponential_biased.cc",
    "absl/profiling/internal/periodic_sampler.cc",
    "absl/profiling/internal/profile_builder.cc",
    "absl/profiling/hashtable.cc",

    // absl::random_distributions, absl::random_seed_gen_exception,
    // absl::random_seed_sequences, absl::random_internal_seed_material,
    // absl::random_internal_entropy_pool, absl::random_internal_platform,
    // absl::random_internal_randen, absl::random_internal_randen_slow,
    // absl::random_internal_randen_hwaes, absl::random_internal_distribution_test_util
    "absl/random/discrete_distribution.cc",
    "absl/random/gaussian_distribution.cc",
    "absl/random/seed_gen_exception.cc",
    "absl/random/seed_sequences.cc",
    "absl/random/internal/seed_material.cc",
    "absl/random/internal/entropy_pool.cc",
    "absl/random/internal/randen_round_keys.cc",
    "absl/random/internal/randen.cc",
    "absl/random/internal/randen_slow.cc",
    "absl/random/internal/randen_detect.cc",
    "absl/random/internal/randen_hwaes.cc",
    "absl/random/internal/chi_square.cc",
    "absl/random/internal/distribution_test_util.cc",

    // absl::status, absl::statusor
    "absl/status/internal/status_internal.cc",
    "absl/status/status.cc",
    "absl/status/status_payload_printer.cc",
    "absl/status/statusor.cc",

    // absl::string_view, absl::strings
    "absl/strings/string_view.cc",
    "absl/strings/ascii.cc",
    "absl/strings/charconv.cc",
    "absl/strings/escaping.cc",
    "absl/strings/internal/charconv_bigint.cc",
    "absl/strings/internal/charconv_parse.cc",
    "absl/strings/internal/damerau_levenshtein_distance.cc",
    "absl/strings/internal/memutil.cc",
    "absl/strings/internal/stringify_sink.cc",
    "absl/strings/match.cc",
    "absl/strings/numbers.cc",
    "absl/strings/str_cat.cc",
    "absl/strings/str_replace.cc",
    "absl/strings/str_split.cc",
    "absl/strings/substitute.cc",
    // absl::strings_internal
    // CMake compiles this .cc from HDRS together with the SRCS list.
    "absl/strings/internal/escaping.cc",
    "absl/strings/internal/ostringstream.cc",
    "absl/strings/internal/utf8.cc",
    // absl::str_format_internal
    "absl/strings/internal/str_format/arg.cc",
    "absl/strings/internal/str_format/bind.cc",
    "absl/strings/internal/str_format/extension.cc",
    "absl/strings/internal/str_format/float_conversion.cc",
    "absl/strings/internal/str_format/output.cc",
    "absl/strings/internal/str_format/parser.cc",
    // absl::cord_internal, absl::cordz_functions, absl::cordz_handle,
    // absl::cordz_info, absl::cordz_sample_token, absl::cord
    "absl/strings/internal/cord_internal.cc",
    "absl/strings/internal/cord_rep_btree.cc",
    "absl/strings/internal/cord_rep_btree_navigator.cc",
    "absl/strings/internal/cord_rep_btree_reader.cc",
    "absl/strings/internal/cord_rep_crc.cc",
    "absl/strings/internal/cord_rep_consume.cc",
    "absl/strings/internal/cordz_functions.cc",
    "absl/strings/internal/cordz_handle.cc",
    "absl/strings/internal/cordz_info.cc",
    "absl/strings/internal/cordz_sample_token.cc",
    "absl/strings/cord.cc",
    "absl/strings/cord_analysis.cc",

    // absl::graphcycles_internal, absl::kernel_timeout_internal,
    // absl::synchronization
    "absl/synchronization/internal/graphcycles.cc",
    "absl/synchronization/internal/kernel_timeout.cc",
    "absl/synchronization/barrier.cc",
    "absl/synchronization/blocking_counter.cc",
    "absl/synchronization/internal/create_thread_identity.cc",
    "absl/synchronization/internal/futex_waiter.cc",
    "absl/synchronization/internal/per_thread_sem.cc",
    "absl/synchronization/internal/pthread_waiter.cc",
    "absl/synchronization/internal/sem_waiter.cc",
    "absl/synchronization/internal/stdcpp_waiter.cc",
    "absl/synchronization/internal/waiter_base.cc",
    "absl/synchronization/internal/win32_waiter.cc",
    "absl/synchronization/notification.cc",
    "absl/synchronization/mutex.cc",

    // absl::time
    "absl/time/civil_time.cc",
    "absl/time/clock.cc",
    "absl/time/duration.cc",
    "absl/time/format.cc",
    "absl/time/time.cc",
    // absl::civil_time, absl::time_zone
    "absl/time/internal/cctz/src/civil_time_detail.cc",
    "absl/time/internal/cctz/src/time_zone_fixed.cc",
    "absl/time/internal/cctz/src/time_zone_format.cc",
    "absl/time/internal/cctz/src/time_zone_if.cc",
    "absl/time/internal/cctz/src/time_zone_impl.cc",
    "absl/time/internal/cctz/src/time_zone_info.cc",
    "absl/time/internal/cctz/src/time_zone_libc.cc",
    "absl/time/internal/cctz/src/time_zone_lookup.cc",
    "absl/time/internal/cctz/src/time_zone_posix.cc",
    "absl/time/internal/cctz/src/zone_info_source.cc",
};
