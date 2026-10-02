/* The S2 bridge: a real `extern "C"` surface over the upstream C++ types.
 *
 * Every declaration here is a thin, named wrapper around one upstream call on
 * one real S2 type.  Nothing in this file computes a cell, a Hilbert position,
 * a great-circle angle or a spherical area: `S2CellId::FromLatLng`,
 * `S2CellId::FromToken`, `S2CellId::ToToken`, `S2Cell::ExactArea`,
 * `S2Loop::GetArea`, `S2Polygon::InitToUnion`, `S2RegionCoverer::GetCovering`
 * and every other answer this package publishes come from the compiled
 * upstream C++ in `src/s2`, reached through `zig/bridge.cc`.
 *
 * Why a bridge at all: `addTranslateC` translates C, and the upstream library
 * is C++17 with classes, virtual `S2Region` dispatch and `absl::string_view`.
 * Translating a C++ header is not something Zig 0.16 does, so the C surface a
 * Zig caller needs is written once, here, as a header the translator can read
 * and a translation unit the compiler can compile.  This header is therefore
 * plain C99 with `extern "C"` guards: it must stay parseable by a C
 * translator, not only by a C++ compiler.
 *
 * Conventions
 * -----------
 *  * Status.  Every entry point returns `S2BridgeStatus`.  `S2BRIDGE_OK` is
 *    zero, and no other value is a success.
 *  * Validation.  Arguments are checked here, before the upstream call, with
    ordinary comparisons, and a rejected argument is
    `S2BRIDGE_INVALID_ARGUMENT`.  Nothing is `assert`ed: an `assert` is
    removed in ReleaseFast, so a bound check that vanishes is a bound check
    that lies.
  * Unit-length vertices.  A loop or polygon vertex is a point on the unit
    sphere, and upstream says so: "All points should be unit length"
    (`s2/s2loop.h:126-130`), checked by `S2::IsUnitLength`
    (`s2/s2pointutil.cc:32-40`).  It also says where that check is too late to
    be one: `S2Loop::Init` reaches the exact predicate, whose triage
    debug-asserts `a.Norm2() <= 2` (`s2/s2predicates.h:394`) and dies when it
    is not (`s2/s2loop.cc:225-230`).  So `s2br_loop_create`,
    `s2br_polygon_create` and `s2br_polygon_create_loops` apply upstream's own
    predicate to every vertex before the first one reaches `Init`, and a
    vertex that is not a direction is a rejected argument rather than a loop
    to be validated later.
 *  * Invalid geometry.  The vertices are the caller's, so a chain that breaks
 *    a loop precondition -- a repeated vertex, a self-intersection -- is
 *    constructed anyway, and `s2br_loop_is_valid` / `s2br_polygon_is_valid`
 *    are how the caller hears about it.  Upstream's own default is fatal
 *    instead: `S2Loop::InitIndex` runs `ABSL_CHECK(IsValid())`
 *    (`s2/s2loop.cc:353-359`) and `S2Polygon::InitIndex` does the same
 *    (`s2/s2polygon.cc:353-360`) whenever the global `--s2debug` flag is on,
 *    which it is by default in any build that does not define `NDEBUG`
 *    (`s2/s2debug.h:18-25`).  Every geometry handle built here therefore
 *    carries `S2Debug::DISABLE` (`s2/s2debug.h:64-69`), the per-object
 *    opt-out upstream documents for exactly a caller that validates
 *    explicitly (`s2/s2debug.h:30-40`, `s2/s2loop.h:111-124`,
 *    `s2/s2loop.h:159-174`, `s2/s2polygon.h:126-148`,
 *    `s2/s2polygon.h:210-223`).  The flag's default, `IsValid` itself, and
 *    the errors it reports are left exactly as they are: this bridge does not
 *    decide what a valid loop is, it only stops the constructor from aborting
 *    before the caller can ask.
 *    What those two answer is the *topology* of a chain built from
 *    directions: a repeated vertex, a self-intersection, a shell that is not
 *    simple.  A vertex that is not a direction is not a chain at all and never
 *    reaches the validator, so it is refused at construction as an argument
 *    (see `Unit-length vertices` above).  The deferral does not extend to what
 *    an operation does with an invalid operand either: `s2br_polygon_union`
 *    and `s2br_polygon_intersection` require valid operands and report an
 *    invalid one as `S2BRIDGE_INVALID_ARGUMENT`.
 *  * Exceptions.  `std::bad_alloc` from an upstream allocation becomes
 *    `S2BRIDGE_OUT_OF_MEMORY`.  Every other exception is *not* caught: the
 *    contract is that this bridge reports allocation failure honestly and does
 *    not swallow anything else.
 *  * Buffers.  Every output buffer belongs to the caller and is borrowed for
 *    the duration of the call.  A list-returning entry point is two-pass: pass
 *    `NULL` -- or a buffer with `cap == 0` -- to learn the required count in
 *    `*out_count`, write nothing, and get `S2BRIDGE_OK`.  That is the sizing
 *    call, and it is the only one that succeeds without room: a positive `cap`
 *    too short for the result is `S2BRIDGE_BUFFER_TOO_SMALL`, with the
 *    required count still in `*out_count` and the buffer itself untouched.
 *  * Owned objects.  `S2BridgeLoop` and `S2BridgePolygon` are opaque handles
 *    whose storage is allocated and freed by C++ here, never by a caller and
 *    never by Zig.  `s2br_*_destroy` is the matching free; the Zig facade's
 *    `deinit` calls exactly that.
 *  * Allocation.  A scalar or buffer call allocates nothing beyond what the
 *    upstream function itself must allocate; see `s2br_coverer_covering_*`,
 *    where the covering vector is upstream's and is destroyed before return, or
 *    `s2br_cell_children`, whose count and fill both come from upstream's own
 *    range and `next()` and need no vector at all.
 *
 * Line references are to files under `src/s2` of this repository at the pinned
 * upstream tag, and name the file each time so a reader never has to guess.
 */

#ifndef S2GEOMETRY_BRIDGE_H_
#define S2GEOMETRY_BRIDGE_H_

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Result of every entry point. */
typedef enum S2BridgeStatus {
  /* The call succeeded. */
  S2BRIDGE_OK = 0,
  /* An argument was out of range, NULL, or a token/level that the upstream
   * type rejects.  No usable result was produced, which is not the same
   * promise as every output being left byte-for-byte alone: a constructor
   * clears its handle to NULL before it validates anything, and a count
   * request initialises `*out_count` before it does.  What a particular entry
   * point does with its own outputs on this status is stated there. */
  S2BRIDGE_INVALID_ARGUMENT = 1,
  /* A caller-owned output buffer was too small. `*out_count`, where the entry
   * point has one, holds the required length. */
  S2BRIDGE_BUFFER_TOO_SMALL = 2,
  /* An upstream C++ allocation failed. */
  S2BRIDGE_OUT_OF_MEMORY = 3,
  /* An upstream call reported failure through its own status type. */
  S2BRIDGE_INTERNAL_ERROR = 4
} S2BridgeStatus;

/* The largest valid cell level, `S2CellId::kMaxLevel`
 * (`s2/s2cell_id.h:99-100`), which is `S2::kMaxCellLevel`
 * (`s2/s2coords.h:131`, `kMaxCellLevel = 30`). */
#define S2BRIDGE_MAX_LEVEL 30

/* An opaque, C++-owned S2Loop. Declare a pointer, never the object. */
typedef struct S2BridgeLoop S2BridgeLoop;

/* An opaque, C++-owned S2Polygon. Declare a pointer, never the object. */
typedef struct S2BridgePolygon S2BridgePolygon;

/* ---------------------------------------------------------------------------
 * CellId
 *
 * S2CellId is a 64-bit unsigned integer whose whole content is that integer
 * (`s2/s2cell_id.h:118-124`), so every entry point here takes and returns a
 * `uint64_t` and constructs the `S2CellId` around it. Nothing about the face
 * and Hilbert-position layout is interpreted on this side of the bridge.
 * ------------------------------------------------------------------------- */

/* `S2CellId(const S2LatLng&)`: the leaf cell containing a normalized point
 * (`s2/s2cell_id.h:119-122`, `s2/s2cell_id.cc:317`). */
S2BridgeStatus s2br_cell_from_lat_lng_deg(double lat_deg, double lng_deg,
                                          uint64_t* out);

/* `S2CellId(const S2Point&)`: the leaf cell containing a direction vector,
 * which need not be unit length (`s2/s2cell_id.h:107-117`,
 * `s2/s2cell_id.cc:309-315`). */
S2BridgeStatus s2br_cell_from_point(double x, double y, double z,
                                    uint64_t* out);

/* `S2CellId::FromFace` (`s2/s2cell_id.h:165`, `s2/s2cell_id.h:543-545`).
 * `face` must be in 0..7: 0..5 are the six cube faces, and 6 and 7 are the
 * two values upstream's own tests use to build an *invalid* cell id
 * (`s2/s2cell_id_test.cc:335-336`). */
S2BridgeStatus s2br_cell_from_face(int face, uint64_t* out);

/* `S2CellId::FromFacePosLevel` (`s2/s2cell_id.h:173`,
 * `s2/s2cell_id.h:547-550`). `face` must be 0..5 as documented at :167.
 * Rejected inputs leave `*out` unchanged. */
S2BridgeStatus s2br_cell_from_face_pos_level(int face, uint64_t pos, int level,
                                              uint64_t* out);

/* `S2CellId::FromFaceIJ` (`s2/s2cell_id.h:484`). `i` and `j` are the cell
 * centre in i/j space, so both must be in 0 .. 2^30 - 1. */
S2BridgeStatus s2br_cell_from_face_ij(int face, int i, int j, uint64_t* out);

/* `S2CellId::FromToken` (`s2/s2cell_id.h:422`, `s2/s2cell_id.cc:235-254`).
 * A malformed token is `S2CellId::None()`, i.e. id 0, so a rejected token is
 * reported as `S2BRIDGE_INVALID_ARGUMENT` rather than as a valid zero id: the
 * two are different facts and a caller must not have to know that the
 * upstream API conflates them. */
S2BridgeStatus s2br_cell_from_token(const char* token, size_t len,
                                    uint64_t* out);

/* `S2CellId::ToToken` (`s2/s2cell_id.h:421`, `s2/s2cell_id.cc:217-233`).
 * Writes at most 16 characters plus a NUL. `*out_len` always receives the
 * token length excluding the NUL, so a NULL buffer sizes the call. */
S2BridgeStatus s2br_cell_to_token(uint64_t id, char* buf, size_t cap,
                                  size_t* out_len);

/* `S2CellId::is_valid` (`s2/s2cell_id.h:236`). Total function, so it returns
 * the answer directly and never a status. */
int s2br_cell_is_valid(uint64_t id);

/* `S2CellId::level` (`s2/s2cell_id.h:259`, `s2/s2cell_id.h:596-601`). Rejected
 * for an id that is not valid: upstream computes the level from the lowest set
 * bit and has no defined answer for id 0. */
S2BridgeStatus s2br_cell_level(uint64_t id, int* out);

/* `S2CellId::face` (`s2/s2cell_id.h:242`). */
S2BridgeStatus s2br_cell_face(uint64_t id, int* out);

/* `S2CellId::pos` (`s2/s2cell_id.h:246`). */
S2BridgeStatus s2br_cell_pos(uint64_t id, uint64_t* out);

/* `S2CellId::FromDebugString` (`s2/s2cell_id.h:454`,
 * `s2/s2cell_id.cc:619-633`): the "face/childpos..." spelling upstream's own
 * neighbour fixtures are written in (`s2/s2cell_id_test.cc:638`,
 * `s2/s2cell_id_test.cc:666`). A string it rejects is `S2CellId::None()`, so it
 * is reported as `S2BRIDGE_INVALID_ARGUMENT` for the same reason a bad token
 * is. */
S2BridgeStatus s2br_cell_from_debug_string(const char* text, size_t len,
                                           uint64_t* out);

/* `S2CellId::ToString` (`s2/s2cell_id.h:447`, `s2/s2cell_id.cc:600-610`):
 * the same "face/childpos..." spelling. `*out_len` always receives the length,
 * so a NULL buffer sizes the call. */
S2BridgeStatus s2br_cell_to_debug_string(uint64_t id, char* buf, size_t cap,
                                         size_t* out_len);

/* `S2CellId::is_leaf` (`s2/s2cell_id.h:268`). */
int s2br_cell_is_leaf(uint64_t id);

/* `S2CellId::is_face` (`s2/s2cell_id.h:274`). */
int s2br_cell_is_face(uint64_t id);

/* `S2CellId::parent(int level)` (`s2/s2cell_id.h:322-325`,
 * `s2/s2cell_id.h:660`). `level` must be in 0 .. `s2br_cell_level(id)`: a
 * level above the cell's own level is the argument upstream documents as a
 * precondition. */
S2BridgeStatus s2br_cell_parent(uint64_t id, int level, uint64_t* out);

/* `S2CellId::child(int position)` (`s2/s2cell_id.h:327-329`). `position` must
 * be in 0..3 and the cell must not be a leaf. */
S2BridgeStatus s2br_cell_child(uint64_t id, int position, uint64_t* out);

/* All descendants of `id` at `level`, by walking `child_begin(level)` to
 * `child_end(level)` (`s2/s2cell_id.h:344-347`); those are upstream's own
 * range convention. Two-pass, and the count is read out of the range rather
 * than out of a list: `distance_from_begin` is upstream's own count of `next()`
 * steps from the first cell of a level (`s2/s2cell_id.h:360-363`), so the
 * difference of the two endpoints is the length of the range in constant time
 * (`s2/s2cell_id.cc:139-142`). That has to be so: a face cell asked for
 * level 30 spans `4^30 = 2^60` cells, and nothing that materialises the range
 * could answer for it.
 *
 * A `NULL` buffer, or `cap == 0`, is the sizing call: it writes the required
 * count into `*out_count`, writes no cells, and returns `S2BRIDGE_OK`.  A
 * positive `cap` shorter than the range is `S2BRIDGE_BUFFER_TOO_SMALL` with
 * the required count left in `*out_count` and the buffer itself untouched,
 * and the fill walks `next()` straight into the caller's buffer. A range too
 * long for a `size_t` to count -- 2^60 on a 32-bit target -- is
 * `S2BRIDGE_INVALID_ARGUMENT` rather than a wrapped count. */
S2BridgeStatus s2br_cell_children(uint64_t id, int level, uint64_t* out,
                                  size_t cap, size_t* out_count);

/* `S2CellId::next` (`s2/s2cell_id.h:355`). */
S2BridgeStatus s2br_cell_next(uint64_t id, uint64_t* out);

/* `S2CellId::prev` (`s2/s2cell_id.h:359`). */
S2BridgeStatus s2br_cell_prev(uint64_t id, uint64_t* out);

/* `S2CellId::contains` (`s2/s2cell_id.h:313`). */
S2BridgeStatus s2br_cell_contains(uint64_t id, uint64_t other, int* out);

/* `S2CellId::intersects` (`s2/s2cell_id.h:317`). */
S2BridgeStatus s2br_cell_intersects(uint64_t id, uint64_t other, int* out);

/* `S2CellId::range_min` and `S2CellId::range_max`
 * (`s2/s2cell_id.h:302-305`). The pair is what `contains` is defined in terms
 * of (`s2/s2cell_id.h:290-295`), so this is the primitive form of the test
 * above, not a second spelling of it. */
S2BridgeStatus s2br_cell_range(uint64_t id, uint64_t* out_min,
                               uint64_t* out_max);

/* `S2CellId::GetEdgeNeighbors` (`s2/s2cell_id.h:455-459`), in the order that
 * comment defines. Always exactly four distinct cells. */
S2BridgeStatus s2br_cell_edge_neighbors(uint64_t id, uint64_t* out4);

/* `S2CellId::AppendVertexNeighbors` (`s2/s2cell_id.h:468`,
 * `s2/s2cell_id.cc:514-554`). Three or four results: the closest vertex may be
 * one of the eight cube vertices, which has only three neighbours
 * (`s2/s2cell_id.cc:548-553`). `level` must be strictly less than this cell's
 * own level (`s2/s2cell_id.cc:516-518`). Two-pass. */
S2BridgeStatus s2br_cell_vertex_neighbors(uint64_t id, int level, uint64_t* out,
                                          size_t cap, size_t* out_count);

/* `S2CellId::AppendAllNeighbors` (`s2/s2cell_id.h:477`,
 * `s2/s2cell_id.cc:556-598`). `nbr_level` must be in this cell's own level ..
 * `S2BRIDGE_MAX_LEVEL` inclusive (`s2/s2cell_id.cc:558`, `s2/s2cell_id.h:611-614`).
 * Two-pass. */
S2BridgeStatus s2br_cell_all_neighbors(uint64_t id, int nbr_level,
                                       uint64_t* out, size_t cap,
                                       size_t* out_count);

/* `S2CellId::ToLatLng` (`s2/s2cell_id.h:239`). */
S2BridgeStatus s2br_cell_to_lat_lng_deg(uint64_t id, double* out_lat_deg,
                                        double* out_lng_deg);

/* `S2CellId::ToPoint` (`s2/s2cell_id.h:181`): the unit-length direction of the
 * cell centre. */
S2BridgeStatus s2br_cell_to_point(uint64_t id, double* xyz);

/* `S2CellId::GetSizeST` (`s2/s2cell_id.h:188-192`): the cell's edge length in
 * (s,t)-space. A projection-space length, not an angle. */
S2BridgeStatus s2br_cell_size_st(uint64_t id, double* out);

/* `S2CellId::IJLevelToBoundUV` (`s2/s2cell_id.h:506`): the (u,v) bounds of the
 * cell whose centre is at i/j, written as u_lo, u_hi, v_lo, v_hi. */
S2BridgeStatus s2br_cell_bound_uv(uint64_t id, double* out_uv4);

/* ---------------------------------------------------------------------------
 * LatLng and Point
 *
 * Units are in the name, never implied: `_deg` for degrees of latitude or
 * longitude. Upstream stores both as radians (`s2/s2latlng.h:95-96`) and
 * offers an explicit constructor per unit (`s2/s2latlng.h:71-72`), so every
 * crossing of the unit boundary happens here, once.
 * ------------------------------------------------------------------------- */

/* `S2LatLng::is_valid` (`s2/s2latlng.h:101`). Total function. */
S2BridgeStatus s2br_latlng_is_valid_deg(double lat_deg, double lng_deg,
                                        int* out);

/* `S2LatLng::Normalized` (`s2/s2latlng.h:106`, `s2/s2latlng.h:122-126`):
 * clamps latitude to +/-90 degrees and wraps longitude into [-180, 180].
 * Returns `S2BRIDGE_INVALID_ARGUMENT` for a non-finite input, which is what
 * upstream returns Invalid() for. */
S2BridgeStatus s2br_latlng_normalized_deg(double lat_deg, double lng_deg,
                                          double* out_lat_deg,
                                          double* out_lng_deg);

/* `S2LatLng::ToPoint` (`s2/s2latlng.h:126`). Requires finite coordinates. */
S2BridgeStatus s2br_point_from_lat_lng_deg(double lat_deg, double lng_deg,
                                           double* xyz);

/* `S2LatLng(const S2Point&)` (`s2/s2latlng.h:64-65`). */
S2BridgeStatus s2br_lat_lng_from_point(double x, double y, double z,
                                       double* out_lat_deg,
                                       double* out_lng_deg);

/* `S2Point::Normalize` (`s2/s2point.h:157`). */
S2BridgeStatus s2br_point_normalized(double x, double y, double z,
                                     double* out_xyz);

/* `S2LatLng::GetDistance` (`s2/s2latlng.h:131-137`), in degrees. Both points
 * must be normalized, which is upstream's precondition. */
S2BridgeStatus s2br_lat_lng_distance_deg(double lat1_deg, double lng1_deg,
                                         double lat2_deg, double lng2_deg,
                                         double* out_deg);

/* ---------------------------------------------------------------------------
 * Cell: geometry and area
 * ------------------------------------------------------------------------- */

/* `S2Cell::ApproxArea` (`s2/s2cell.h:232`, `s2/s2cell.cc:124-141`): steradians,
 * within 3%, and within 0.1% at level 5 and finer. */
S2BridgeStatus s2br_cell_approx_area(uint64_t id, double* out_steradians);

/* `S2Cell::ExactArea` (`s2/s2cell.h:237`, `s2/s2cell.cc:143-149`):
 * steradians. */
S2BridgeStatus s2br_cell_exact_area(uint64_t id, double* out_steradians);

/* `S2Cell::AverageArea(int level)` (`s2/s2cell.h:221-226`,
 * `s2/s2cell.cc:120-122`): the mean area of all cells at `level`, in
 * steradians. */
S2BridgeStatus s2br_cell_average_area(int level, double* out_steradians);

/* `S2Cell::GetCenter` (`s2/s2cell.h:217`): the unit-length direction of the
 * point at which the cell divides into four children. */
S2BridgeStatus s2br_cell_center(uint64_t id, double* xyz);

/* `S2Cell::GetVertex` (`s2/s2cell.h:136-141`): vertex `k` in 0..3,
 * counter-clockwise from the lower-left corner of the (u,v) square. */
S2BridgeStatus s2br_cell_vertex(uint64_t id, int k, double* xyz);

/* `S2Cell::GetBoundUV` (`s2/s2cell.h:240`) as u_lo, u_hi, v_lo, v_hi. */
S2BridgeStatus s2br_cell_bound_uv_of_cell(uint64_t id, double* out_uv4);

/* `S2Cell::Contains(const S2Point&)` (`s2/s2cell.h:308`). */
S2BridgeStatus s2br_cell_contains_point(uint64_t id, double x, double y,
                                        double z, int* out);

/* ---------------------------------------------------------------------------
 * Cap and LatLngRect
 * ------------------------------------------------------------------------- */

/* `S2Cap(center, S1Angle::Degrees(radius_deg))::GetArea` (`s2/s2cap.h:72`,
 * `s2/s2cap.cc:48-50`): steradians. */
S2BridgeStatus s2br_cap_area_deg(double lat_deg, double lng_deg,
                                 double radius_deg, double* out_steradians);

/* `S2Cap::height` (`s2/s2cap.h:105`): the distance from the centre point to the
 * cutting plane, as a plain multiple of the sphere radius. */
S2BridgeStatus s2br_cap_height(double lat_deg, double lng_deg,
                               double radius_deg, double* out_height);

/* `S2Cap::Complement` (`s2/s2cap.h:146`, `s2/s2cap.cc:65-71`), reported as
 * (lat_deg, lng_deg, radius_deg). The complement of a full cap is the empty
 * cap and vice versa (`s2/s2cap.cc:67-68`), so the result's radius is 180
 * degrees for the empty cap and 0 for the full one. */
S2BridgeStatus s2br_cap_complement_deg(double lat_deg, double lng_deg,
                                       double radius_deg, double* out_lat_deg,
                                       double* out_lng_deg,
                                       double* out_radius_deg);

/* `S2Cap::Contains(const S2Point&)` (`s2/s2cap.h:192`). Upstream
 * REQUIRES a unit-length vector and debug-asserts it
 * (`s2/s2cap.cc:296-300`), so `(x, y, z)` is rejected as
 * `S2BRIDGE_INVALID_ARGUMENT` unless it is finite and its squared length is
 * within upstream's own tolerance of 1 (`S2::IsUnitLength`,
 * `s2/s2pointutil.cc:32-40`). Without that check a Debug build would abort on
 * the assert and an optimized build would answer from undefined input. */
S2BridgeStatus s2br_cap_contains_point(double lat_deg, double lng_deg,
                                       double radius_deg, double x, double y,
                                       double z, int* out);

/* `S2LatLngRect(lo, hi)::Area` (`s2/s2latlng_rect.h:72`,
 * `s2/s2latlng_rect.h:184`): steradians on the unit sphere. */
S2BridgeStatus s2br_rect_area_deg(double lat_lo_deg, double lng_lo_deg,
                                  double lat_hi_deg, double lng_hi_deg,
                                  double* out_steradians);

/* `S2LatLngRect::Contains(const S2LatLng&)` (`s2/s2latlng_rect.h:179`). */
S2BridgeStatus s2br_rect_contains_lat_lng_deg(double lat_lo_deg,
                                              double lng_lo_deg,
                                              double lat_hi_deg,
                                              double lng_hi_deg,
                                              double lat_deg, double lng_deg,
                                              int* out);

/* `S2LatLngRect::PolarClosure` (`s2/s2latlng_rect.cc:229-234`): the smallest
 * latitude-longitude rectangle with the same interior, which means widening a
 * rectangle that touches a pole to every longitude. Returns
 * (lat_lo_deg, lng_lo_deg, lat_hi_deg, lng_hi_deg). */
S2BridgeStatus s2br_rect_polar_closure_deg(double lat_lo_deg,
                                           double lng_lo_deg,
                                           double lat_hi_deg,
                                           double lng_hi_deg,
                                           double* out_bounds_deg4);

/* `S2LatLngRect::is_inverted` (`s2/s2latlng_rect.h:145`): true when
 * `lng_lo > lng_hi`, that is, when the rectangle crosses the 180 degree line
 * and is therefore not a box in the ordinary sense. */
S2BridgeStatus s2br_rect_is_inverted_deg(double lat_lo_deg, double lng_lo_deg,
                                         double lat_hi_deg, double lng_hi_deg,
                                         int* out);

/* `S2LatLngRect::is_valid` (`s2/s2latlng_rect.h:129-132`). */
S2BridgeStatus s2br_rect_is_valid_deg(double lat_lo_deg, double lng_lo_deg,
                                      double lat_hi_deg, double lng_hi_deg,
                                      int* out);

/* ---------------------------------------------------------------------------
 * Loop: an owned, opaque S2Loop
 * ------------------------------------------------------------------------- */

/* Allocates an `S2BridgeLoop` holding an `S2Loop` initialised from `n` vertices
 * (`s2/s2loop.h:109`, `s2/s2loop.cc:201-207`).
 * `n` must be at least 3; upstream allows exactly two one-vertex forms, the
 * empty and the full loop (`s2/s2loop.h:139-143`), and those have their own
 * constructors below.
 *
 * `n` must also be a count upstream is able to hold: `S2Loop::Init` assigns
 * `vertices.size()` into `S2Loop::num_vertices_`, which is an `int`
 * (`s2/s2loop.cc:203`, `s2/s2loop.h:647`), so a count above the largest `int`
 * would reach it already narrowed, and the caller's buffer has to be
 * addressable as `3 * n` doubles in the first place. A count past either
 * bound is `S2BRIDGE_INVALID_ARGUMENT`, refused before the buffer is read and
 * before anything is allocated, with `*out` left null.
 *
 * Every vertex must be a unit-length direction within upstream's own
 * tolerance (`S2::IsUnitLength`, `s2/s2pointutil.cc:32-40`), and one that is
 * not is `S2BRIDGE_INVALID_ARGUMENT`; see `Unit-length vertices` in the
 * conventions above for why upstream cannot be asked about it instead.
 *
 * The chain itself need not be a valid loop: the handle is built with
 * `S2Debug::DISABLE` (`s2/s2loop.h:111-124`) so a self-intersecting or
 * repeated-vertex chain is constructed rather than fatal, and
 * `s2br_loop_is_valid` reports it.  See `Invalid geometry` in the conventions
 * above. */
S2BridgeStatus s2br_loop_create(const double* xyz, size_t n,
                                S2BridgeLoop** out);

/* `S2Loop::kEmpty` (`s2/s2loop.h:139`, `s2/s2loop.h:677-679`): the loop with no
 * edges that contains no points. */
S2BridgeStatus s2br_loop_create_empty(S2BridgeLoop** out);

/* `S2Loop::kFull` (`s2/s2loop.h:143`, `s2/s2loop.h:681-683`): the loop with no
 * edges that contains all points. */
S2BridgeStatus s2br_loop_create_full(S2BridgeLoop** out);

/* Frees a handle from `s2br_loop_create*`. A NULL handle is accepted and does
 * nothing, so `deinit` after a failed construction is safe. */
void s2br_loop_destroy(S2BridgeLoop* loop);

/* `S2Loop::num_vertices` (`s2/s2loop.h:187`). */
S2BridgeStatus s2br_loop_num_vertices(const S2BridgeLoop* loop, int* out);

/* `S2Loop::vertex(i)` (`s2/s2loop.h:193-195`). */
S2BridgeStatus s2br_loop_vertex(const S2BridgeLoop* loop, int i, double* xyz);

/* The vertex `i` as (lat_deg, lng_deg). */
S2BridgeStatus s2br_loop_vertex_lat_lng_deg(const S2BridgeLoop* loop, int i,
                                            double* out_lat_deg,
                                            double* out_lng_deg);

/* `S2Loop::GetArea` (`s2/s2loop.h:265`): steradians of the region on the left
 * of the loop, between 0 and 4*pi. */
S2BridgeStatus s2br_loop_area(const S2BridgeLoop* loop,
                              double* out_steradians);

/* `S2Loop::Contains(const S2Point&)` (`s2/s2loop.h:414`). */
S2BridgeStatus s2br_loop_contains_point(const S2BridgeLoop* loop, double x,
                                        double y, double z, int* out);

/* `S2Loop::IsNormalized` (`s2/s2loop.h:249`). */
S2BridgeStatus s2br_loop_is_normalized(const S2BridgeLoop* loop, int* out);

/* `S2Loop::Normalize` (`s2/s2loop.h:253`): invert if necessary so the enclosed
 * area is at most 2*pi. */
S2BridgeStatus s2br_loop_normalize(S2BridgeLoop* loop);

/* `S2Loop::Invert` (`s2/s2loop.h:260`). */
S2BridgeStatus s2br_loop_invert(S2BridgeLoop* loop);

/* `S2Loop::is_empty` / `S2Loop::is_full` (`s2/s2loop.h:223`,
 * `s2/s2loop.h:226`). */
S2BridgeStatus s2br_loop_is_empty(const S2BridgeLoop* loop, int* out);
S2BridgeStatus s2br_loop_is_full(const S2BridgeLoop* loop, int* out);

/* `S2Loop::IsValid` (`s2/s2loop.h:179`, `s2/s2loop.cc:209-221`): whether the
 * vertex chain satisfies every loop precondition, including having no
 * self-intersection.  This is how invalid geometry reaches the caller: the
 * handle it came from was constructed with `S2Debug::DISABLE`
 * (`s2/s2loop.h:159-174`), so upstream's validator runs here and returns its
 * real answer instead of aborting the process. */
S2BridgeStatus s2br_loop_is_valid(const S2BridgeLoop* loop, int* out);

/* ---------------------------------------------------------------------------
 * Polygon: an owned, opaque S2Polygon
 * ------------------------------------------------------------------------- */

/* A polygon whose interior is the single shell `xyz`. Backed by
 * `S2Polygon::Init(std::unique_ptr<S2Loop>)` (`s2/s2polygon.h:196`,
 * `s2/s2polygon.h:200-202`).
 *
 * `n` carries the same count bound as `s2br_loop_create`: the shell reaches
 * `S2Loop::Init`, whose vertex count is an `int` (`s2/s2loop.h:647`), and
 * `xyz` must be addressable as `3 * n` doubles. A count past either bound is
 * `S2BRIDGE_INVALID_ARGUMENT`, refused before the buffer is read and before
 * anything is allocated, with `*out` left null.
 *
 * Every vertex must be a unit-length direction within upstream's own
 * tolerance (`S2::IsUnitLength`, `s2/s2pointutil.cc:32-40`) and one that is
 * not is `S2BRIDGE_INVALID_ARGUMENT`, because the shell reaches
 * `S2Loop::Init` (`s2/s2polygon.cc:406-414`); see `Unit-length vertices` in
 * the conventions above.
 *
 * The shell need not be a valid loop: the shell and the polygon that adopts
 * it are both built with `S2Debug::DISABLE` (`s2/s2polygon.h:154-159`,
 * `s2/s2polygon.h:210-223`), so `s2br_polygon_is_valid` is reachable for an
 * invalid shell instead of the process aborting first.  See `Invalid
 * geometry` in the conventions above. */
S2BridgeStatus s2br_polygon_create(const double* xyz, size_t n,
                                   S2BridgePolygon** out);

/* A polygon from nested loops: `S2Polygon::InitNested`
 * (`s2/s2polygon.h:183`, `s2/s2polygon.h:184-189`).  `xyz` holds
 * `loop_sizes[0] + ... + loop_sizes[num_loops - 1]` vertices laid out loop
 * after loop, so the caller supplies one vertex array and one length per loop
 * rather than an array of pointers.  The interior is the points contained by an
 * odd number of loops, and upstream reorders the loops into a traversal order
 * in which a shell precedes its holes (`s2/s2polygon.h:184-189`).
 *
 * `num_loops` and the lengths in it are counts too, and they are checked before
 * the length list is read: `S2Polygon::num_loops()` narrows `loops_.size()` to
 * an `int` (`s2/s2polygon.h:248`), each length is stored by `S2Loop::Init` in
 * its own `int`, and `S2Polygon::InitLoopProperties` adds the per-loop counts
 * up in one more (`s2/s2polygon.cc:530`, `s2/s2polygon.h:887`). A `num_loops`
 * past the `int` range, a single length past it, or a sum of individually
 * legal lengths past it is `S2BRIDGE_INVALID_ARGUMENT`, as is a length list or
 * vertex array a `size_t` cannot address; each is refused before the input is
 * walked and before anything is allocated, with `*out` left null.
 *
 * Every vertex of every loop must be a unit-length direction, with the same
 * predicate and the same rejection as `s2br_polygon_create`; the loops here
 * are built by `S2Loop::Init` directly (`s2/s2polygon.cc:523-534`).
 *
 * Every loop, and the polygon that adopts them, carries `S2Debug::DISABLE`
 * (`s2/s2polygon.h:126-148`): an invalid loop or an invalid nesting is
 * reported by `s2br_polygon_is_valid`, not by an abort.  See `Invalid
 * geometry` in the conventions above. */
S2BridgeStatus s2br_polygon_create_loops(const double* xyz,
                                         const size_t* loop_sizes,
                                         size_t num_loops,
                                         S2BridgePolygon** out);

/* The empty polygon: `S2Polygon` default-constructed, `num_loops() == 0`
 * (`s2/s2polygon.h:241`). */
S2BridgeStatus s2br_polygon_create_empty(S2BridgePolygon** out);

/* `S2Polygon::MakeFull` (`s2/s2polygon.h:170`). */
S2BridgeStatus s2br_polygon_create_full(S2BridgePolygon** out);

/* Frees a handle from `s2br_polygon_create*`. NULL is accepted. */
void s2br_polygon_destroy(S2BridgePolygon* polygon);

/* `S2Polygon::num_loops` (`s2/s2polygon.h:248`). */
S2BridgeStatus s2br_polygon_num_loops(const S2BridgePolygon* polygon, int* out);

/* `S2Polygon::num_vertices` (`s2/s2polygon.h:252`): the total over all loops. */
S2BridgeStatus s2br_polygon_num_vertices(const S2BridgePolygon* polygon,
                                         int* out);

/* `S2Polygon::loop(k)->num_vertices` (`s2/s2polygon.h:259`). */
S2BridgeStatus s2br_polygon_loop_num_vertices(const S2BridgePolygon* polygon,
                                               int loop_index, int* out);

/* `S2Polygon::loop(k)->vertex(i)` (`s2/s2polygon.h:259`,
 * `s2/s2loop.h:193`). The loop index is the traversal order
 * `s2/s2polygon.h:186-189` produces. */
S2BridgeStatus s2br_polygon_loop_vertex(const S2BridgePolygon* polygon,
                                        int loop_index, int vertex_index,
                                        double* xyz);

/* The same vertex as (lat_deg, lng_deg). */
S2BridgeStatus s2br_polygon_loop_vertex_lat_lng_deg(
    const S2BridgePolygon* polygon, int loop_index, int vertex_index,
    double* out_lat_deg, double* out_lng_deg);

/* `S2Polygon::GetArea` (`s2/s2polygon.h:275`): steradians, between 0 and
 * 4*pi, with holes already subtracted. */
S2BridgeStatus s2br_polygon_area(const S2BridgePolygon* polygon,
                                 double* out_steradians);

/* `S2Polygon::Contains(const S2Point&)` (`s2/s2polygon.h:654`). `(x, y, z)`
 * carries the same unit-length requirement as `s2br_cap_contains_point`,
 * because upstream documents and debug-asserts it here too
 * (`s2/s2polygon.h:653`, `s2/s2polygon.cc:704-706`). */
S2BridgeStatus s2br_polygon_contains_point(const S2BridgePolygon* polygon,
                                           double x, double y, double z,
                                           int* out);

/* `S2Polygon::Contains(const S2Point&)` asked about a normalized S2LatLng
 * (`s2/s2polygon.h:650-654`). `S2LatLng::ToPoint` is the conversion upstream
 * defines for a normalized coordinate (`s2/s2latlng.cc:68-76`), and it is what
 * makes the vector unit length for that overload. */
S2BridgeStatus s2br_polygon_contains_lat_lng_deg(
    const S2BridgePolygon* polygon, double lat_deg, double lng_deg, int* out);

/* `S2Polygon::GetCentroid` (`s2/s2polygon.h:286`) normalized and reported as
 * (lat_deg, lng_deg). */
S2BridgeStatus s2br_polygon_centroid_lat_lng_deg(const S2BridgePolygon* polygon,
                                                  double* out_lat_deg,
                                                  double* out_lng_deg);

/* `S2Polygon::is_empty` / `S2Polygon::is_full` (`s2/s2polygon.h:241`,
 * `s2/s2polygon.h:245`). */
S2BridgeStatus s2br_polygon_is_empty(const S2BridgePolygon* polygon, int* out);
S2BridgeStatus s2br_polygon_is_full(const S2BridgePolygon* polygon, int* out);

/* `S2Polygon::IsValid` (`s2/s2polygon.h:229`), including the validity of
 * every loop it owns.  Reachable for an invalid polygon for the same reason
 * as `s2br_loop_is_valid`: the handle was built with `S2Debug::DISABLE`
 * (`s2/s2polygon.h:210-223`). */
S2BridgeStatus s2br_polygon_is_valid(const S2BridgePolygon* polygon, int* out);

/* `S2Polygon::InitToComplement` (`s2/s2polygon.h:496-497`). Allocates a new
 * handle; the input is untouched. */
S2BridgeStatus s2br_polygon_complement(const S2BridgePolygon* polygon,
                                       S2BridgePolygon** out);

/* `S2Polygon::InitToIntersection` (`s2/s2polygon.h:389`), reached through the
 * overload that reports rather than aborts: the two-argument one is
 * `ABSL_LOG(DFATAL) << ... << error` (`s2/s2polygon.cc:945-951`) and DFATAL
 * dies in every optimize mode, so the `S2Error` overload
 * (`s2/s2polygon.h:388-390`) is the only one whose failure can be a status.
 * Its result is built with the same `S2Debug::DISABLE` as every other handle
 * here, and with the same snap function upstream's own two-argument overload
 * passes, `IdentitySnapFunction(S2::kIntersectionMergeRadius)`
 * (`s2/s2polygon.cc:955-957`).
 *
 * Both operands must be valid polygons, which is upstream's stated
 * precondition: these functions "should never return an error provided that
 * both input polygons are valid" (`s2/s2polygon.h:385-388`). An invalid
 * operand is therefore `S2BRIDGE_INVALID_ARGUMENT`, decided by
 * `S2Polygon::IsValid` before the operation runs, and `*out` is left NULL. A
 * failure reported by upstream for two valid operands is
 * `S2BRIDGE_INTERNAL_ERROR`, with `*out` still NULL: nothing partial is
 * handed back. */
S2BridgeStatus s2br_polygon_intersection(const S2BridgePolygon* a,
                                         const S2BridgePolygon* b,
                                         S2BridgePolygon** out);

/* `S2Polygon::InitToUnion` (`s2/s2polygon.h:396`), with the operands, the
 * snap function, the result policy and the two failure statuses exactly as
 * `s2br_polygon_intersection` above (`s2/s2polygon.cc:981-983`). */
S2BridgeStatus s2br_polygon_union(const S2BridgePolygon* a,
                                  const S2BridgePolygon* b,
                                  S2BridgePolygon** out);

/* ---------------------------------------------------------------------------
 * Region covering
 *
 * One coverer configuration, validated here, shared by the four covering entry
 * points. `min_level` and `max_level` in 0..`S2BRIDGE_MAX_LEVEL` with
 * `min_level <= max_level` (`s2/s2region_coverer.cc:44-47`,
 * `s2/s2region_coverer.cc:60-72`); `level_mod` in 1..3
 * (`s2/s2region_coverer.cc:79-83`); `max_cells >= 1`.
 * ------------------------------------------------------------------------- */
typedef struct S2BridgeCovererOptions {
  int32_t min_level;
  int32_t max_level;
  int32_t level_mod;
  int32_t max_cells;
} S2BridgeCovererOptions;

/* `S2RegionCoverer::GetCovering(const S2Region&, std::vector<S2CellId>*)`
 * (`s2/s2region_coverer.h:193`) for a cap. Two-pass. The vector is upstream's
 * and is destroyed before this returns, so the only heap allocation left
 * behind is the one the caller asked for. */
S2BridgeStatus s2br_coverer_covering_cap(double lat_deg, double lng_deg,
                                         double radius_deg,
                                         const S2BridgeCovererOptions* opts,
                                         uint64_t* out, size_t cap,
                                         size_t* out_count);

/* The same covering for a latitude-longitude rectangle. */
S2BridgeStatus s2br_coverer_covering_rect(double lat_lo_deg, double lng_lo_deg,
                                          double lat_hi_deg, double lng_hi_deg,
                                          const S2BridgeCovererOptions* opts,
                                          uint64_t* out, size_t cap,
                                          size_t* out_count);

/* The same covering for a polygon handle. */
S2BridgeStatus s2br_coverer_covering_polygon(const S2BridgePolygon* polygon,
                                             const S2BridgeCovererOptions* opts,
                                             uint64_t* out, size_t cap,
                                             size_t* out_count);

/* The same covering for a single cell, which `S2Cell` is a region for
 * (`s2/s2cell.h:292-310`). Upstream's own covering of a cell is exactly that
 * one cell (`s2/s2region_coverer_test.cc:84-86`). */
S2BridgeStatus s2br_coverer_covering_cell(uint64_t id,
                                          const S2BridgeCovererOptions* opts,
                                          uint64_t* out, size_t cap,
                                          size_t* out_count);

/* ---------------------------------------------------------------------------
 * Raw loop measurements
 *
 * These exist so a caller can state a geometric fact in the vocabulary
 * upstream states it in, without this bridge reimplementing anything.
 * ------------------------------------------------------------------------- */

/* `S2::GetPerimeter` over the loop's vertices (`s2/s2loop_measures.h:44`), in
 * radians. */
S2BridgeStatus s2br_loop_perimeter_rad(const S2BridgeLoop* loop,
                                       double* out_radians);

/* `S2::GetSignedArea` over the loop's vertices (`s2/s2loop_measures.h:78`), in
 * steradians. Unlike `S2Loop::GetArea` this is signed: negative for a loop
 * whose interior is more than half the sphere. */
S2BridgeStatus s2br_loop_signed_area(const S2BridgeLoop* loop,
                                     double* out_steradians);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* S2GEOMETRY_BRIDGE_H_ */