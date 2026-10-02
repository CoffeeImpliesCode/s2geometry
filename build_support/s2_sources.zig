//! The s2geometry translation units this fork compiles, and nothing else.
//!
//! Provenance
//! ----------
//! This list is the `add_library(s2 ...)` block of `CMakeLists.txt` in the
//! pinned tree, in upstream's order and spelling, one entry per line.  It is
//! the library that block names -- not the `S2TestFiles` list below it, not
//! the `s2testing` library, and not the googletest or benchmark downloads that
//! `if (BUILD_TESTS)` pulls in.  Upstream's own `S2_ENABLE_INSTALL` installs
//! only the `s2` target, and this package installs only what it compiles.
//!
//! Count: 108 translation units.  Every path here exists in the tree; the
//! build fails at the missing file rather than at a link error if it ever
//! does not.
//!
//! What is NOT here, and why
//! -------------------------
//! * `src/s2/gmock_matchers.cc`, `s2builderutil_testing.cc`,
//!   `s2shapeutil_testing.cc`, `s2testing.cc`, `thread_testing.cc`
//!   (`add_library(s2testing ...)`, `CMakeLists.txt:329-335`) and
//!   `src/s2/testing/test_main.cc` need GoogleTest and Google Benchmark.
//!   Those are downloaded by upstream's `BUILD_TESTS` path and are not part of
//!   the library this package ships.
//! * `src/s2/*_test.cc` -- upstream's own unit tests.  `zig build test` runs
//!   this fork's behavioural tests instead; the upstream suite is left intact
//!   in the tree and can still be built with upstream's CMake.
//! * `src/python/*.cc` -- the pybind11 bindings, gated behind upstream's
//!   `WITH_PYTHON` option.
//!
//! Headers
//! -------
//! Upstream installs a hand-maintained subset of `src/s2/*.h`, which it
//! acknowledges is "only those transitively included by s2 headers we are
//! exporting".  This package installs the whole `src/s2` header tree instead:
//! the subset is a packaging convenience, the tree is the truth, and a
//! consumer that reaches a header upstream forgot to list should not be told
//! by an install rule.  The relative layout is preserved, so `#include
//! "s2/s2cell_id.h"` resolves identically here and in upstream's install.

/// The s2geometry release this fork pins.
pub const version = "0.14.0";

/// Commit of the pinned s2geometry tree.
pub const commit = "c24b368c67d0b8a2a109c5a75224e73a856bd8b7";

/// Include root for the upstream sources: they spell their headers
/// `s2/s2cell_id.h`, so this is the directory that holds `s2/`.
pub const include_dir = "src";

/// Directory of the s2geometry headers, relative to the package root.
///
/// This is the include root's `s2/` child, and it is what gets installed under
/// `include/s2`, so the relative layout a consumer sees is the same one the
/// upstream sources use.
pub const header_dir = "src/s2";

/// Every s2geometry library translation unit this fork compiles.
pub const sources = [_][]const u8{
    "src/s2/base/malloc_extension.cc",
    "src/s2/encoded_s2cell_id_vector.cc",
    "src/s2/encoded_s2point_vector.cc",
    "src/s2/encoded_s2shape_index.cc",
    "src/s2/encoded_string_vector.cc",
    "src/s2/id_set_lexicon.cc",
    "src/s2/internal/s2incident_edge_tracker.cc",
    "src/s2/internal/s2index_cell_data.cc",
    "src/s2/mutable_s2shape_index.cc",
    "src/s2/r2rect.cc",
    "src/s2/s1angle.cc",
    "src/s2/s1chord_angle.cc",
    "src/s2/s1interval.cc",
    "src/s2/s2boolean_operation.cc",
    "src/s2/s2buffer_operation.cc",
    "src/s2/s2builder.cc",
    "src/s2/s2builder_graph.cc",
    "src/s2/s2builderutil_closed_set_normalizer.cc",
    "src/s2/s2builderutil_find_polygon_degeneracies.cc",
    "src/s2/s2builderutil_get_snapped_winding_delta.cc",
    "src/s2/s2builderutil_lax_polygon_layer.cc",
    "src/s2/s2builderutil_lax_polyline_layer.cc",
    "src/s2/s2builderutil_s2point_vector_layer.cc",
    "src/s2/s2builderutil_s2polygon_layer.cc",
    "src/s2/s2builderutil_s2polyline_layer.cc",
    "src/s2/s2builderutil_s2polyline_vector_layer.cc",
    "src/s2/s2builderutil_snap_functions.cc",
    "src/s2/s2cap.cc",
    "src/s2/s2cell.cc",
    "src/s2/s2cell_id.cc",
    "src/s2/s2cell_index.cc",
    "src/s2/s2cell_union.cc",
    "src/s2/s2centroids.cc",
    "src/s2/s2chain_interpolation_query.cc",
    "src/s2/s2closest_cell_query.cc",
    "src/s2/s2closest_edge_query.cc",
    "src/s2/s2closest_point_query.cc",
    "src/s2/s2contains_vertex_query.cc",
    "src/s2/s2convex_hull_query.cc",
    "src/s2/s2coords.cc",
    "src/s2/s2crossing_edge_query.cc",
    "src/s2/s2debug.cc",
    "src/s2/s2density_tree.cc",
    "src/s2/s2earth.cc",
    "src/s2/s2edge_clipping.cc",
    "src/s2/s2edge_crosser.cc",
    "src/s2/s2edge_crossings.cc",
    "src/s2/s2edge_distances.cc",
    "src/s2/s2edge_tessellator.cc",
    "src/s2/s2error.cc",
    "src/s2/s2fractal.cc",
    "src/s2/s2furthest_edge_query.cc",
    "src/s2/s2hausdorff_distance_query.cc",
    "src/s2/s2latlng.cc",
    "src/s2/s2latlng_rect.cc",
    "src/s2/s2latlng_rect_bounder.cc",
    "src/s2/s2lax_loop_shape.cc",
    "src/s2/s2lax_polygon_shape.cc",
    "src/s2/s2lax_polyline_shape.cc",
    "src/s2/s2loop.cc",
    "src/s2/s2loop_measures.cc",
    "src/s2/s2max_distance_targets.cc",
    "src/s2/s2measures.cc",
    "src/s2/s2memory_tracker.cc",
    "src/s2/s2metrics.cc",
    "src/s2/s2min_distance_targets.cc",
    "src/s2/s2padded_cell.cc",
    "src/s2/s2point_compression.cc",
    "src/s2/s2point_region.cc",
    "src/s2/s2pointutil.cc",
    "src/s2/s2polygon.cc",
    "src/s2/s2polyline.cc",
    "src/s2/s2polyline_alignment.cc",
    "src/s2/s2polyline_measures.cc",
    "src/s2/s2polyline_simplifier.cc",
    "src/s2/s2predicates.cc",
    "src/s2/s2projections.cc",
    "src/s2/s2r2rect.cc",
    "src/s2/s2random.cc",
    "src/s2/s2region_coverer.cc",
    "src/s2/s2region_intersection.cc",
    "src/s2/s2region_sharder.cc",
    "src/s2/s2region_term_indexer.cc",
    "src/s2/s2region_union.cc",
    "src/s2/s2shape_index.cc",
    "src/s2/s2shape_index_buffered_region.cc",
    "src/s2/s2shape_index_measures.cc",
    "src/s2/s2shape_measures.cc",
    "src/s2/s2shape_nesting_query.cc",
    "src/s2/s2shapeutil_build_polygon_boundaries.cc",
    "src/s2/s2shapeutil_coding.cc",
    "src/s2/s2shapeutil_contains_brute_force.cc",
    "src/s2/s2shapeutil_conversion.cc",
    "src/s2/s2shapeutil_count_vertices.cc",
    "src/s2/s2shapeutil_edge_iterator.cc",
    "src/s2/s2shapeutil_edge_wrap.cc",
    "src/s2/s2shapeutil_get_reference_point.cc",
    "src/s2/s2shapeutil_visit_crossing_edge_pairs.cc",
    "src/s2/s2text_format.cc",
    "src/s2/s2wedge_relations.cc",
    "src/s2/s2winding_operation.cc",
    "src/s2/util/bits/bit-interleave.cc",
    "src/s2/util/coding/coder.cc",
    "src/s2/util/coding/varint.cc",
    "src/s2/util/math/exactfloat/bignum.cc",
    "src/s2/util/math/exactfloat/exactfloat.cc",
    "src/s2/util/math/mathutil.cc",
    "src/s2/util/units/length-units.cc",
};

/// Number of translation units in `sources`, asserted here so a truncated
/// list cannot pass unnoticed.
pub const source_count = sources.len;
