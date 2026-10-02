// Implementation of the `extern "C"` bridge declared in `zig/bridge.h`.
//
// Every function here is a validation plus one upstream call. Nothing in this
// file knows what a Hilbert curve or a spherical excess is; it converts units,
// checks bounds with ordinary comparisons, and hands the work to the real S2
// C++ compiled from `src/s2`. Where an allocation is unavoidable it is
// upstream's own, and it is released before the function returns.
//
// The `std::bad_alloc` handling is the only exception handling, and it is
// deliberate: an upstream `std::vector` or `unique_ptr` allocation that fails
// is a real, reportable condition, so it becomes `S2BRIDGE_OUT_OF_MEMORY`.
// No other exception is caught, so nothing is silently turned into a success.

#include "bridge.h"

#include <cfloat>
#include <climits>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <memory>
#include <new>
#include <string>
#include <vector>

#include "absl/types/span.h"

#include "s2/s1angle.h"
#include "s2/s2builderutil_snap_functions.h"
#include "s2/s2cap.h"
#include "s2/s2cell.h"
#include "s2/s2cell_id.h"
#include "s2/s2debug.h"
#include "s2/s2edge_crossings.h"
#include "s2/s2error.h"
#include "s2/s2latlng.h"
#include "s2/s2latlng_rect.h"
#include "s2/s2loop.h"
#include "s2/s2loop_measures.h"
#include "s2/s2point.h"
#include "s2/s2point_span.h"
#include "s2/s2polygon.h"
#include "s2/s2region.h"
#include "s2/s2region_coverer.h"

namespace {

// The largest value an i/j coordinate can take: `S2CellId::kMaxSize`
// (`s2/s2cell_id.h:102`, `kMaxSize = 1 << kMaxLevel`).
constexpr int kMaxIJ = (1 << S2BRIDGE_MAX_LEVEL) - 1;

// `S2CellId::FromFacePosLevel` masks the position to `kPosBits`
// (`s2/s2cell_id.h:101-102`, `kPosBits = 2 * kMaxLevel + 1`), so a wider
// position cannot reach the cell it names. Rejecting it here keeps the caller
// from believing it chose the cell it asked for.
constexpr uint64_t kMaxPos = (uint64_t{1} << (2 * S2BRIDGE_MAX_LEVEL + 1)) - 1;

inline bool IsValidLevel(int level) {
  return level >= 0 && level <= S2BRIDGE_MAX_LEVEL;
}

// `S2Point` is a `util::math::Vector3_d` (`s2/s2point.h:63`,
// `s2/util/math/vector.h`), but nothing here relies on its layout: a point is
// built component by component from three doubles, which is exactly what
// `zig/bridge.h` promises the caller's `double xyz[3]` buffer means.
inline S2Point MakePoint(const double* xyz) {
  return S2Point(xyz[0], xyz[1], xyz[2]);
}

inline S2BridgeStatus PutInt(int value, int* out) {
  if (out == nullptr) return S2BRIDGE_INVALID_ARGUMENT;
  *out = value;
  return S2BRIDGE_OK;
}

inline S2BridgeStatus PutDouble(double value, double* out) {
  if (out == nullptr) return S2BRIDGE_INVALID_ARGUMENT;
  *out = value;
  return S2BRIDGE_OK;
}

inline S2BridgeStatus PutUint64(uint64_t value, uint64_t* out) {
  if (out == nullptr) return S2BRIDGE_INVALID_ARGUMENT;
  *out = value;
  return S2BRIDGE_OK;
}

inline S2BridgeStatus PutBool(bool value, int* out) {
  if (out == nullptr) return S2BRIDGE_INVALID_ARGUMENT;
  *out = value ? 1 : 0;
  return S2BRIDGE_OK;
}

inline S2BridgeStatus PutXYZ(const S2Point& p, double* xyz) {
  if (xyz == nullptr) return S2BRIDGE_INVALID_ARGUMENT;
  xyz[0] = p.x();
  xyz[1] = p.y();
  xyz[2] = p.z();
  return S2BRIDGE_OK;
}

inline S2BridgeStatus PutUV(const R2Rect& uv, double* out4) {
  if (out4 == nullptr) return S2BRIDGE_INVALID_ARGUMENT;
  out4[0] = uv.x().lo();
  out4[1] = uv.x().hi();
  out4[2] = uv.y().lo();
  out4[3] = uv.y().hi();
  return S2BRIDGE_OK;
}

inline bool AllFinite(double a, double b) {
  return std::isfinite(a) && std::isfinite(b);
}

// `S2Cap::Contains` and `S2Polygon::Contains` both begin with
// `ABSL_DCHECK(S2::IsUnitLength(p))` (`s2/s2cap.cc:296-300`,
// `s2/s2polygon.cc:704-706`), which terminates the process whenever `NDEBUG`
// is undefined -- that is, in Zig's Debug mode. An unnormalised vector would
// abort a Debug build and give a silently wrong answer in an optimized one, so
// the condition is checked here instead. `S2::IsUnitLength`
// (`s2/s2pointutil.cc:32-40`) accepts `|Norm2() - 1| <= 5 * DBL_EPSILON`;
// a non-finite component makes `Norm2()` non-finite, so one comparison
// rejects both a wrong length and a non-finite coordinate.
inline bool IsUnitPoint(const double* xyz) {
  const double norm2 = xyz[0] * xyz[0] + xyz[1] * xyz[1] + xyz[2] * xyz[2];
  return std::fabs(norm2 - 1.0) <= 5 * DBL_EPSILON;
}

// The caller's vertex array is three doubles per vertex: `MakePoint` reads
// three components and both walks below step it as `xyz + 3 * i`
// (`AllUnitPoints`, `AsOwnedPoints`), so a vertex count is only usable once
// that span is something a `size_t` can address.
constexpr size_t kVertexBytes = 3 * sizeof(double);

// Whether a caller-supplied count is one upstream can be told about at all.
//
// Upstream counts vertices and loops in `int`. `S2Loop::Init` assigns
// `vertices.size()` into `S2Loop::num_vertices_` (`s2/s2loop.cc:203`,
// `s2/s2loop.h:647`), `S2Polygon::InitLoopProperties` sums those per-loop
// counts into `S2Polygon::num_vertices_` (`s2/s2polygon.cc:530`,
// `s2/s2polygon.h:887`), and `S2Polygon::num_loops()` narrows `loops_.size()`
// (`s2/s2polygon.h:248`). A count an `int` cannot hold is a count upstream
// would receive already truncated, so it is a rejected argument and not a
// loop: narrowing is silent, and the caller has no way to see it happen.
//
// The second half is the caller's own buffer. `count` elements of
// `element_bytes` each must be addressable by a `size_t`, which on a 32-bit
// target is the stricter of the two bounds -- `SIZE_MAX / 24` vertices, or
// `SIZE_MAX / sizeof(size_t)` lengths -- and is never the binding one on a
// 64-bit target, where `INT_MAX` is smaller than either. Either way the
// multiplication the walks perform cannot wrap.
inline bool NativeCountFits(size_t count, size_t element_bytes) {
  return count <= static_cast<size_t>(INT_MAX) &&
         count <= SIZE_MAX / element_bytes;
}

// The same unit-length requirement over a whole vertex chain, checked before
// any of it reaches `S2Loop::Init`. Upstream states the requirement -- "All
// points should be unit length" (`s2/s2loop.h:126-130`) -- and states too where
// its own check is too late to be one: `S2Loop::FindValidationErrorNoIndex`
// says "Unfortunately this check happens too late in debug mode, because
// S2Loop construction calls s2pred::Sign which expects vertices to be unit
// length" (`s2/s2loop.cc:225-230`). `Init` computes the loop's origin through
// `InitOriginAndBound` (`s2/s2loop.cc:201-207`, `:271`), which reaches
// `S2::AngleContainsVertex` and from there the exact predicate, where
// `s2pred::TriageSign` debug-asserts `a.Norm2() <= 2`
// (`s2/s2predicates.h:394`) and dies. So a vertex that is not a direction is
// not a malformed loop to be reported by `s2br_loop_is_valid`: it is an
// argument upstream does not accept, and the validator never gets to speak.
// The predicate is the one above, upstream's own `S2::IsUnitLength`
// tolerance and not a bound invented here.
bool AllUnitPoints(const double* xyz, size_t n) {
  for (size_t i = 0; i < n; ++i) {
    if (!IsUnitPoint(xyz + 3 * i)) return false;
  }
  return true;
}

// Copies an upstream string into a caller buffer under the two-pass contract.
// `capacity_including_nul` is what the caller offered; the string plus its NUL
// must fit, so the buffer is reported too small when `capacity <= size`.
inline S2BridgeStatus DrainString(const std::string& text, char* buf,
                                  size_t cap, size_t* out_len) {
  if (out_len == nullptr) return S2BRIDGE_INVALID_ARGUMENT;
  *out_len = text.size();
  if (buf == nullptr || cap == 0) return S2BRIDGE_OK;
  if (cap <= text.size()) return S2BRIDGE_BUFFER_TOO_SMALL;
  std::memcpy(buf, text.data(), text.size());
  buf[text.size()] = '\0';
  return S2BRIDGE_OK;
}

// Applies the two-pass buffer contract to a list of cell ids upstream produced.
// The vector has already been filled; this decides what the caller learns.
S2BridgeStatus DrainIds(const std::vector<S2CellId>& vec, uint64_t* out,
                        size_t cap, size_t* out_count) {
  if (out_count == nullptr) return S2BRIDGE_INVALID_ARGUMENT;
  const size_t required = vec.size();
  *out_count = required;
  if (out == nullptr || cap == 0) return S2BRIDGE_OK;
  if (cap < required) return S2BRIDGE_BUFFER_TOO_SMALL;
  for (size_t i = 0; i < required; ++i) out[i] = vec[i].id();
  return S2BRIDGE_OK;
}

// Turns a caller's `xyz` buffer into the contiguous point vector the S2Loop
// constructors take. `S2Loop::Init` copies it (`s2/s2loop.cc:201-207`), so a
// local vector is safe: nothing upstream keeps a reference to it.
std::vector<S2Point> AsOwnedPoints(const double* xyz, size_t n) {
  std::vector<S2Point> points(n);
  for (size_t i = 0; i < n; ++i) points[i] = MakePoint(xyz + 3 * i);
  return points;
}

// Every geometry handle this bridge builds gets upstream's per-object opt-out
// from the automatic validity check, `S2Debug::DISABLE` (`s2/s2debug.h:64-69`).
//
// Upstream validates a loop or a polygon *inside* its constructor whenever the
// global `--s2debug` flag is set, which is the default in any build that does
// not define `NDEBUG` (`s2/s2debug.h:18-25`) and therefore in Zig's Debug and
// ReleaseSafe modes. A failure there is fatal rather than an error code:
// `S2Loop::InitIndex` runs `ABSL_CHECK(IsValid())` (`s2/s2loop.cc:353-359`) and
// `S2Polygon::InitIndex` does the same (`s2/s2polygon.cc:353-360`).
//
// That default is upstream's, not this bridge's contract. The vertices here are
// the caller's, so a chain that breaks a loop precondition -- a repeated
// vertex, a self-intersection -- is an answer the caller is entitled to, and
// `s2br_loop_is_valid` (`s2/s2loop.h:179`) and `s2br_polygon_is_valid`
// (`s2/s2polygon.h:229`) are how it gets one. `S2Debug::DISABLE` is the
// mechanism upstream documents for precisely that caller
// (`s2/s2debug.h:30-40`, `s2/s2loop.h:111-124`, `s2/s2loop.h:159-174`,
// `s2/s2polygon.h:126-148`, `s2/s2polygon.h:210-223`), and it is per-object:
// the global flag, its default, and `IsValid` itself with the real errors it
// reports are all untouched, and nothing here decides what valid means.
//
// The override has to be in place *before* the call that can run the check,
// which is why it lives in these helpers rather than in a note at each call
// site. Upstream keeps it across `Init` and `Decode` (`s2/s2loop.h:172`,
// `s2/s2polygon.h:221`) and carries it through copy and move construction
// (`s2/s2loop.cc:113,127,143,162`; `s2/s2polygon.cc:143,158,172,192`), so a
// loop built here keeps the policy when the polygon adopts it.
constexpr S2Debug kDeferredValidation = S2Debug::DISABLE;

// Initialises `loop` with the policy above, in the order that policy requires.
void DeferValidation(S2Loop* loop, absl::Span<const S2Point> vertices) {
  loop->set_s2debug_override(kDeferredValidation);
  loop->Init(vertices);
}

// The same, for a loop a polygon is about to own.
std::unique_ptr<S2Loop> MakeDeferredValidationLoop(
    absl::Span<const S2Point> vertices) {
  auto loop = std::make_unique<S2Loop>();
  DeferValidation(loop.get(), vertices);
  return loop;
}

// And for the polygon itself, which needs it as well as its loops: every
// populating call runs `InitIndex` -- `Init` through `InitOneLoop`
// (`s2/s2polygon.cc:406-427`), `InitNested` through `InitLoopProperties`
// (`s2/s2polygon.cc:523-534`) -- and `S2Polygon::IsValid` validates the loops
// too (`s2/s2polygon.h:225-229`). Apply this *after* any assignment from
// another polygon: move assignment copies that object's override
// (`s2/s2polygon.cc:192`) and would otherwise put `S2Debug::ALLOW` back.
void DeferValidation(S2Polygon* polygon) {
  polygon->set_s2debug_override(kDeferredValidation);
}

// An S2LatLngRect built from four degrees, after the finiteness check the
// rectangle's own constructor does not make.
bool MakeRect(double lat_lo_deg, double lng_lo_deg, double lat_hi_deg,
              double lng_hi_deg, S2LatLngRect* out) {
  if (!AllFinite(lat_lo_deg, lng_lo_deg) || !AllFinite(lat_hi_deg, lng_hi_deg)) {
    return false;
  }
  *out = S2LatLngRect(S2LatLng::FromDegrees(lat_lo_deg, lng_lo_deg),
                      S2LatLng::FromDegrees(lat_hi_deg, lng_hi_deg));
  return true;
}

// An S2Cap built from degrees, after the same finiteness check.
bool MakeCap(double lat_deg, double lng_deg, double radius_deg, S2Cap* out) {
  if (!AllFinite(lat_deg, lng_deg) || !std::isfinite(radius_deg)) return false;
  // `S2Cap`'s constructor takes an S1Angle and clamps at 180 degrees
  // (`s2/s2cap.h:247-252`); a larger radius is a full cap, not an error, which
  // is upstream's own choice and is passed through unchanged.
  *out = S2Cap(S2LatLng::FromDegrees(lat_deg, lng_deg).ToPoint(),
               S1Angle::Degrees(radius_deg));
  return true;
}

}  // namespace

// The opaque handle definitions. Both hold the upstream object itself, so every
// access below is a member call on the real thing: there is no shadow copy that
// could drift from it.
struct S2BridgeLoop {
  S2Loop loop;
};

struct S2BridgePolygon {
  S2Polygon polygon;
};

extern "C" {

// --- CellId ----------------------------------------------------------------

S2BridgeStatus s2br_cell_from_lat_lng_deg(double lat_deg, double lng_deg,
                                          uint64_t* out) {
  if (out == nullptr) return S2BRIDGE_INVALID_ARGUMENT;
  if (!AllFinite(lat_deg, lng_deg)) return S2BRIDGE_INVALID_ARGUMENT;
  try {
    // `S2CellId(const S2LatLng&)` REQUIRES finite coordinates
    // (`s2/s2cell_id.h:119-122`), which is the check above.
    *out =
        S2CellId(S2LatLng::FromDegrees(lat_deg, lng_deg)).id();
  } catch (const std::bad_alloc&) {
    return S2BRIDGE_OUT_OF_MEMORY;
  }
  return S2BRIDGE_OK;
}

S2BridgeStatus s2br_cell_from_point(double x, double y, double z,
                                    uint64_t* out) {
  if (out == nullptr) return S2BRIDGE_INVALID_ARGUMENT;
  try {
    *out = S2CellId(S2Point(x, y, z)).id();
  } catch (const std::bad_alloc&) {
    return S2BRIDGE_OUT_OF_MEMORY;
  }
  return S2BRIDGE_OK;
}

S2BridgeStatus s2br_cell_from_face(int face, uint64_t* out) {
  if (out == nullptr) return S2BRIDGE_INVALID_ARGUMENT;
  if (face < 0 || face > 7) return S2BRIDGE_INVALID_ARGUMENT;
  *out = S2CellId::FromFace(face).id();
  return S2BRIDGE_OK;
}

S2BridgeStatus s2br_cell_from_face_pos_level(int face, uint64_t pos, int level,
                                              uint64_t* out) {
  if (out == nullptr) return S2BRIDGE_INVALID_ARGUMENT;
  if (face < 0 || face > 5) return S2BRIDGE_INVALID_ARGUMENT;
  if (!IsValidLevel(level)) return S2BRIDGE_INVALID_ARGUMENT;
  if ((pos & ~kMaxPos) != 0) return S2BRIDGE_INVALID_ARGUMENT;
  *out = S2CellId::FromFacePosLevel(face, pos, level).id();
  return S2BRIDGE_OK;
}

S2BridgeStatus s2br_cell_from_face_ij(int face, int i, int j, uint64_t* out) {
  if (out == nullptr) return S2BRIDGE_INVALID_ARGUMENT;
  if (face < 0 || face > 5) return S2BRIDGE_INVALID_ARGUMENT;
  if (i < 0 || i > kMaxIJ || j < 0 || j > kMaxIJ) {
    return S2BRIDGE_INVALID_ARGUMENT;
  }
  *out = S2CellId::FromFaceIJ(face, i, j).id();
  return S2BRIDGE_OK;
}

S2BridgeStatus s2br_cell_from_token(const char* token, size_t len,
                                    uint64_t* out) {
  if (out == nullptr) return S2BRIDGE_INVALID_ARGUMENT;
  if (token == nullptr) return S2BRIDGE_INVALID_ARGUMENT;
  const S2CellId id = S2CellId::FromToken(absl::string_view(token, len));
  // Upstream answers a malformed token with `S2CellId::None()`
  // (`s2/s2cell_id.h:419-422`, `s2/s2cell_id.cc:249-250`), which is id 0.
  // Reporting that as a successful zero would make an invalid token
  // indistinguishable from a real cell whose id happens to be 0, so it is
  // rejected here instead.
  if (!id.is_valid()) return S2BRIDGE_INVALID_ARGUMENT;
  *out = id.id();
  return S2BRIDGE_OK;
}

S2BridgeStatus s2br_cell_to_token(uint64_t id, char* buf, size_t cap,
                                  size_t* out_len) {
  // Upstream's maximum token length is 16 characters (`s2/s2cell_id.h:415-420`
  // and `s2/s2cell_id.cc:232`, which passes `16 - num_zero_digits`).
  try {
    // `ToToken` builds a `std::string` (`s2/s2cell_id.cc:210-233`), which is
    // where an upstream allocation happens on this path.
    return DrainString(S2CellId(id).ToToken(), buf, cap, out_len);
  } catch (const std::bad_alloc&) {
    return S2BRIDGE_OUT_OF_MEMORY;
  }
}

S2BridgeStatus s2br_cell_from_debug_string(const char* text, size_t len,
                                           uint64_t* out) {
  if (out == nullptr) return S2BRIDGE_INVALID_ARGUMENT;
  if (text == nullptr) return S2BRIDGE_INVALID_ARGUMENT;
  const S2CellId id = S2CellId::FromDebugString(absl::string_view(text, len));
  // A string upstream rejects is `S2CellId::None()`
  // (`s2/s2cell_id.cc:620-630`), so the same reasoning as `from_token` applies.
  if (!id.is_valid()) return S2BRIDGE_INVALID_ARGUMENT;
  *out = id.id();
  return S2BRIDGE_OK;
}

S2BridgeStatus s2br_cell_to_debug_string(uint64_t id, char* buf, size_t cap,
                                         size_t* out_len) {
  try {
    // `ToString` builds a `std::string` (`s2/s2cell_id.cc:600-614`).
    return DrainString(S2CellId(id).ToString(), buf, cap, out_len);
  } catch (const std::bad_alloc&) {
    return S2BRIDGE_OUT_OF_MEMORY;
  }
}

int s2br_cell_is_valid(uint64_t id) {
  return S2CellId(id).is_valid() ? 1 : 0;
}

S2BridgeStatus s2br_cell_level(uint64_t id, int* out) {
  if (!s2br_cell_is_valid(id)) return S2BRIDGE_INVALID_ARGUMENT;
  return PutInt(S2CellId(id).level(), out);
}

S2BridgeStatus s2br_cell_face(uint64_t id, int* out) {
  if (!s2br_cell_is_valid(id)) return S2BRIDGE_INVALID_ARGUMENT;
  return PutInt(S2CellId(id).face(), out);
}

S2BridgeStatus s2br_cell_pos(uint64_t id, uint64_t* out) {
  if (!s2br_cell_is_valid(id)) return S2BRIDGE_INVALID_ARGUMENT;
  return PutUint64(S2CellId(id).pos(), out);
}

int s2br_cell_is_leaf(uint64_t id) {
  return S2CellId(id).is_leaf() ? 1 : 0;
}

int s2br_cell_is_face(uint64_t id) {
  return S2CellId(id).is_face() ? 1 : 0;
}

S2BridgeStatus s2br_cell_parent(uint64_t id, int level, uint64_t* out) {
  if (out == nullptr) return S2BRIDGE_INVALID_ARGUMENT;
  if (!s2br_cell_is_valid(id)) return S2BRIDGE_INVALID_ARGUMENT;
  if (!IsValidLevel(level)) return S2BRIDGE_INVALID_ARGUMENT;
  // `parent(level)` requires `0 <= level <= this->level()`
  // (`s2/s2cell_id.h:322-325`), and `level()` here is the same value that
  // precondition refers to.
  if (level > S2CellId(id).level()) return S2BRIDGE_INVALID_ARGUMENT;
  *out = S2CellId(id).parent(level).id();
  return S2BRIDGE_OK;
}

S2BridgeStatus s2br_cell_child(uint64_t id, int position, uint64_t* out) {
  if (out == nullptr) return S2BRIDGE_INVALID_ARGUMENT;
  if (!s2br_cell_is_valid(id)) return S2BRIDGE_INVALID_ARGUMENT;
  if (position < 0 || position > 3) return S2BRIDGE_INVALID_ARGUMENT;
  if (S2CellId(id).is_leaf()) return S2BRIDGE_INVALID_ARGUMENT;
  *out = S2CellId(id).child(position).id();
  return S2BRIDGE_OK;
}

S2BridgeStatus s2br_cell_children(uint64_t id, int level, uint64_t* out,
                                  size_t cap, size_t* out_count) {
  if (out_count == nullptr) return S2BRIDGE_INVALID_ARGUMENT;
  *out_count = 0;
  if (!s2br_cell_is_valid(id)) return S2BRIDGE_INVALID_ARGUMENT;
  if (!IsValidLevel(level)) return S2BRIDGE_INVALID_ARGUMENT;
  // `child_begin(level)`/`child_end(level)` require a level at or below this
  // cell's own (`s2/s2cell_id.h:344-347`).
  if (level < S2CellId(id).level()) return S2BRIDGE_INVALID_ARGUMENT;
  // Upstream's own half-open iterator convention.
  const S2CellId begin = S2CellId(id).child_begin(level);
  const S2CellId end = S2CellId(id).child_end(level);
  // The range is a run of `next()` steps, and `distance_from_begin` is
  // upstream's own count of those steps from the first cell of the level
  // ("Returns the number of steps that this cell is from Begin(level()) ...
  // May be called for End() as well as valid cell ids",
  // `s2/s2cell_id.h:360-363`), so the difference of the two endpoints is the
  // number of cells in the range, in constant time and with no allocation.
  //
  // That matters because the count cannot be had any other way: the range is
  // as wide as the level allows, and a face cell asked for level 30 spans
  // `4^30 = 2^60` cells, which is not a list any caller can hold and not a walk
  // any machine can finish. `child_end(level)` is one past the last cell of the
  // range -- for the last face it is `S2CellId::End(level)`
  // (`s2/s2cell_id.h:741-743`) -- and both endpoints are the same level, so
  // the difference is the count and never negative.
  const int64_t span = end.distance_from_begin() - begin.distance_from_begin();
  // `*out_count` is a `size_t`, so a span no `size_t` can hold cannot be
  // reported as a length: 2^60 fits a 64-bit one and does not fit a 32-bit
  // one, where such a request is refused here rather than answered with a
  // wrapped count the caller would then size a buffer from. The check is the
  // conversion itself, made in both directions, so it is one ordinary
  // comparison rather than a bound chosen here for a count upstream defines.
  const size_t required = static_cast<size_t>(span);
  if (static_cast<int64_t>(required) != span) return S2BRIDGE_INVALID_ARGUMENT;
  *out_count = required;
  if (out == nullptr || cap == 0) return S2BRIDGE_OK;
  // As `DrainIds` decides for a list upstream has already built: a buffer too
  // short is refused before anything is written into it, and the required
  // count is what the caller is left holding.
  if (cap < required) return S2BRIDGE_BUFFER_TOO_SMALL;
  // The walk is upstream's own: the same `next()` the iterator convention
  // names, writing straight into the caller's buffer with nothing in between.
  S2CellId cell = begin;
  for (size_t i = 0; i < required; ++i) {
    out[i] = cell.id();
    cell = cell.next();
  }
  return S2BRIDGE_OK;
}

S2BridgeStatus s2br_cell_next(uint64_t id, uint64_t* out) {
  if (out == nullptr) return S2BRIDGE_INVALID_ARGUMENT;
  if (!s2br_cell_is_valid(id)) return S2BRIDGE_INVALID_ARGUMENT;
  *out = S2CellId(id).next().id();
  return S2BRIDGE_OK;
}

S2BridgeStatus s2br_cell_prev(uint64_t id, uint64_t* out) {
  if (out == nullptr) return S2BRIDGE_INVALID_ARGUMENT;
  if (!s2br_cell_is_valid(id)) return S2BRIDGE_INVALID_ARGUMENT;
  *out = S2CellId(id).prev().id();
  return S2BRIDGE_OK;
}

S2BridgeStatus s2br_cell_contains(uint64_t id, uint64_t other, int* out) {
  if (!s2br_cell_is_valid(id) || !s2br_cell_is_valid(other)) {
    return S2BRIDGE_INVALID_ARGUMENT;
  }
  return PutBool(S2CellId(id).contains(S2CellId(other)), out);
}

S2BridgeStatus s2br_cell_intersects(uint64_t id, uint64_t other, int* out) {
  if (!s2br_cell_is_valid(id) || !s2br_cell_is_valid(other)) {
    return S2BRIDGE_INVALID_ARGUMENT;
  }
  return PutBool(S2CellId(id).intersects(S2CellId(other)), out);
}

S2BridgeStatus s2br_cell_range(uint64_t id, uint64_t* out_min,
                               uint64_t* out_max) {
  if (out_min == nullptr || out_max == nullptr) {
    return S2BRIDGE_INVALID_ARGUMENT;
  }
  if (!s2br_cell_is_valid(id)) return S2BRIDGE_INVALID_ARGUMENT;
  const S2CellId cell(id);
  *out_min = cell.range_min().id();
  *out_max = cell.range_max().id();
  return S2BRIDGE_OK;
}

S2BridgeStatus s2br_cell_edge_neighbors(uint64_t id, uint64_t* out4) {
  if (out4 == nullptr) return S2BRIDGE_INVALID_ARGUMENT;
  if (!s2br_cell_is_valid(id)) return S2BRIDGE_INVALID_ARGUMENT;
  // `GetEdgeNeighbors` writes exactly four cells into a caller array
  // (`s2/s2cell_id.h:455-459`), so this needs no allocation at all.
  S2CellId neighbors[4];
  S2CellId(id).GetEdgeNeighbors(neighbors);
  for (int i = 0; i < 4; ++i) out4[i] = neighbors[i].id();
  return S2BRIDGE_OK;
}

S2BridgeStatus s2br_cell_vertex_neighbors(uint64_t id, int level, uint64_t* out,
                                          size_t cap, size_t* out_count) {
  if (out_count == nullptr) return S2BRIDGE_INVALID_ARGUMENT;
  *out_count = 0;
  if (!s2br_cell_is_valid(id)) return S2BRIDGE_INVALID_ARGUMENT;
  if (!IsValidLevel(level)) return S2BRIDGE_INVALID_ARGUMENT;
  // `AppendVertexNeighbors` requires `level < this->level()`
  // (`s2/s2cell_id.cc:516-518`).
  if (level >= S2CellId(id).level()) return S2BRIDGE_INVALID_ARGUMENT;
  try {
    std::vector<S2CellId> cells;
    S2CellId(id).AppendVertexNeighbors(level, &cells);
    return DrainIds(cells, out, cap, out_count);
  } catch (const std::bad_alloc&) {
    return S2BRIDGE_OUT_OF_MEMORY;
  }
}

S2BridgeStatus s2br_cell_all_neighbors(uint64_t id, int nbr_level,
                                       uint64_t* out, size_t cap,
                                       size_t* out_count) {
  if (out_count == nullptr) return S2BRIDGE_INVALID_ARGUMENT;
  *out_count = 0;
  if (!s2br_cell_is_valid(id)) return S2BRIDGE_INVALID_ARGUMENT;
  // `0 <= nbr_level <= kMaxLevel`: `GetSizeIJ` checks exactly that
  // (`s2/s2cell_id.h:611-614`) and its shift is already negative past it, so
  // kMaxLevel is a level here rather than one past the top.
  if (!IsValidLevel(nbr_level)) return S2BRIDGE_INVALID_ARGUMENT;
  // `AppendAllNeighbors` requires `nbr_level >= level()`
  // (`s2/s2cell_id.cc:558`) and `GetSizeIJ(nbr_level) <= GetSizeIJ()`
  // (`s2/s2cell_id.cc:570`), which is the same bound because both sizes halve
  // as the level grows.  Nothing upstream caps the level below kMaxLevel: at
  // kMaxLevel the size is 1, so a leaf cell appends the 2 + 4 + 2 cells of its
  // loop and a cell one level up appends 12, while a face cell asked for 30
  // names 4*(2^31+1) of them.  That last figure is a memory question rather
  // than a legality one, so it is left to the caller: this builds the vector,
  // `cap` decides whether the answer fits, and an allocation that cannot be
  // satisfied comes back as `S2BRIDGE_OUT_OF_MEMORY` below rather than as a
  // refusal upstream would not make.
  if (nbr_level < S2CellId(id).level()) return S2BRIDGE_INVALID_ARGUMENT;
  try {
    std::vector<S2CellId> cells;
    S2CellId(id).AppendAllNeighbors(nbr_level, &cells);
    return DrainIds(cells, out, cap, out_count);
  } catch (const std::bad_alloc&) {
    return S2BRIDGE_OUT_OF_MEMORY;
  }
}

S2BridgeStatus s2br_cell_to_lat_lng_deg(uint64_t id, double* out_lat_deg,
                                        double* out_lng_deg) {
  if (out_lat_deg == nullptr || out_lng_deg == nullptr) {
    return S2BRIDGE_INVALID_ARGUMENT;
  }
  if (!s2br_cell_is_valid(id)) return S2BRIDGE_INVALID_ARGUMENT;
  const S2LatLng ll = S2CellId(id).ToLatLng();
  *out_lat_deg = ll.lat().degrees();
  *out_lng_deg = ll.lng().degrees();
  return S2BRIDGE_OK;
}

S2BridgeStatus s2br_cell_to_point(uint64_t id, double* xyz) {
  if (xyz == nullptr) return S2BRIDGE_INVALID_ARGUMENT;
  if (!s2br_cell_is_valid(id)) return S2BRIDGE_INVALID_ARGUMENT;
  return PutXYZ(S2CellId(id).ToPoint(), xyz);
}

S2BridgeStatus s2br_cell_size_st(uint64_t id, double* out) {
  if (!s2br_cell_is_valid(id)) return S2BRIDGE_INVALID_ARGUMENT;
  return PutDouble(S2CellId(id).GetSizeST(), out);
}

S2BridgeStatus s2br_cell_bound_uv(uint64_t id, double* out_uv4) {
  if (!s2br_cell_is_valid(id)) return S2BRIDGE_INVALID_ARGUMENT;
  return PutUV(S2CellId(id).GetBoundUV(), out_uv4);
}

// --- LatLng and Point ------------------------------------------------------

S2BridgeStatus s2br_latlng_is_valid_deg(double lat_deg, double lng_deg,
                                        int* out) {
  return PutBool(S2LatLng::FromDegrees(lat_deg, lng_deg).is_valid(), out);
}

S2BridgeStatus s2br_latlng_normalized_deg(double lat_deg, double lng_deg,
                                          double* out_lat_deg,
                                          double* out_lng_deg) {
  if (out_lat_deg == nullptr || out_lng_deg == nullptr) {
    return S2BRIDGE_INVALID_ARGUMENT;
  }
  if (!AllFinite(lat_deg, lng_deg)) {
    // `Normalized` returns `Invalid()` for non-finite input
    // (`s2/s2latlng.h:122-126`), and Invalid() has no degrees to report.
    return S2BRIDGE_INVALID_ARGUMENT;
  }
  const S2LatLng ll = S2LatLng::FromDegrees(lat_deg, lng_deg).Normalized();
  *out_lat_deg = ll.lat().degrees();
  *out_lng_deg = ll.lng().degrees();
  return S2BRIDGE_OK;
}

S2BridgeStatus s2br_point_from_lat_lng_deg(double lat_deg, double lng_deg,
                                           double* xyz) {
  if (xyz == nullptr) return S2BRIDGE_INVALID_ARGUMENT;
  if (!AllFinite(lat_deg, lng_deg)) {
    // `ToPoint` REQUIRES finite coordinates (`s2/s2latlng.h:120-126`).
    return S2BRIDGE_INVALID_ARGUMENT;
  }
  return PutXYZ(S2LatLng::FromDegrees(lat_deg, lng_deg).ToPoint(), xyz);
}

S2BridgeStatus s2br_lat_lng_from_point(double x, double y, double z,
                                       double* out_lat_deg,
                                       double* out_lng_deg) {
  if (out_lat_deg == nullptr || out_lng_deg == nullptr) {
    return S2BRIDGE_INVALID_ARGUMENT;
  }
  const S2LatLng ll(S2Point(x, y, z));
  *out_lat_deg = ll.lat().degrees();
  *out_lng_deg = ll.lng().degrees();
  return S2BRIDGE_OK;
}

S2BridgeStatus s2br_point_normalized(double x, double y, double z,
                                     double* out_xyz) {
  if (out_xyz == nullptr) return S2BRIDGE_INVALID_ARGUMENT;
  return PutXYZ(S2Point(x, y, z).Normalize(), out_xyz);
}

S2BridgeStatus s2br_lat_lng_distance_deg(double lat1_deg, double lng1_deg,
                                         double lat2_deg, double lng2_deg,
                                         double* out_deg) {
  if (out_deg == nullptr) return S2BRIDGE_INVALID_ARGUMENT;
  if (!AllFinite(lat1_deg, lng1_deg) || !AllFinite(lat2_deg, lng2_deg)) {
    return S2BRIDGE_INVALID_ARGUMENT;
  }
  const S1Angle radians =
      S2LatLng::FromDegrees(lat1_deg, lng1_deg)
          .GetDistance(S2LatLng::FromDegrees(lat2_deg, lng2_deg));
  return PutDouble(radians.degrees(), out_deg);
}

// --- Cell geometry and area ------------------------------------------------

S2BridgeStatus s2br_cell_approx_area(uint64_t id, double* out_steradians) {
  if (!s2br_cell_is_valid(id)) return S2BRIDGE_INVALID_ARGUMENT;
  return PutDouble(S2Cell(S2CellId(id)).ApproxArea(), out_steradians);
}

S2BridgeStatus s2br_cell_exact_area(uint64_t id, double* out_steradians) {
  if (!s2br_cell_is_valid(id)) return S2BRIDGE_INVALID_ARGUMENT;
  return PutDouble(S2Cell(S2CellId(id)).ExactArea(), out_steradians);
}

S2BridgeStatus s2br_cell_average_area(int level, double* out_steradians) {
  if (!IsValidLevel(level)) return S2BRIDGE_INVALID_ARGUMENT;
  return PutDouble(S2Cell::AverageArea(level), out_steradians);
}

S2BridgeStatus s2br_cell_center(uint64_t id, double* xyz) {
  if (!s2br_cell_is_valid(id)) return S2BRIDGE_INVALID_ARGUMENT;
  return PutXYZ(S2Cell(S2CellId(id)).GetCenter(), xyz);
}

S2BridgeStatus s2br_cell_vertex(uint64_t id, int k, double* xyz) {
  if (!s2br_cell_is_valid(id)) return S2BRIDGE_INVALID_ARGUMENT;
  if (k < 0 || k > 3) return S2BRIDGE_INVALID_ARGUMENT;
  return PutXYZ(S2Cell(S2CellId(id)).GetVertex(k), xyz);
}

S2BridgeStatus s2br_cell_bound_uv_of_cell(uint64_t id, double* out_uv4) {
  if (!s2br_cell_is_valid(id)) return S2BRIDGE_INVALID_ARGUMENT;
  return PutUV(S2Cell(S2CellId(id)).GetBoundUV(), out_uv4);
}

S2BridgeStatus s2br_cell_contains_point(uint64_t id, double x, double y,
                                        double z, int* out) {
  if (!s2br_cell_is_valid(id)) return S2BRIDGE_INVALID_ARGUMENT;
  return PutBool(S2Cell(S2CellId(id)).Contains(S2Point(x, y, z)), out);
}

// --- Cap and LatLngRect ----------------------------------------------------

S2BridgeStatus s2br_cap_area_deg(double lat_deg, double lng_deg,
                                 double radius_deg, double* out_steradians) {
  S2Cap cap;
  if (!MakeCap(lat_deg, lng_deg, radius_deg, &cap)) {
    return S2BRIDGE_INVALID_ARGUMENT;
  }
  return PutDouble(cap.GetArea(), out_steradians);
}

S2BridgeStatus s2br_cap_height(double lat_deg, double lng_deg,
                               double radius_deg, double* out_height) {
  S2Cap cap;
  if (!MakeCap(lat_deg, lng_deg, radius_deg, &cap)) {
    return S2BRIDGE_INVALID_ARGUMENT;
  }
  return PutDouble(cap.height(), out_height);
}

S2BridgeStatus s2br_cap_complement_deg(double lat_deg, double lng_deg,
                                       double radius_deg, double* out_lat_deg,
                                       double* out_lng_deg,
                                       double* out_radius_deg) {
  if (out_lat_deg == nullptr || out_lng_deg == nullptr ||
      out_radius_deg == nullptr) {
    return S2BRIDGE_INVALID_ARGUMENT;
  }
  S2Cap cap;
  if (!MakeCap(lat_deg, lng_deg, radius_deg, &cap)) {
    return S2BRIDGE_INVALID_ARGUMENT;
  }
  const S2Cap complement = cap.Complement();
  const S2LatLng centre = S2LatLng(complement.center());
  *out_lat_deg = centre.lat().degrees();
  *out_lng_deg = centre.lng().degrees();
  *out_radius_deg = complement.GetRadius().degrees();
  return S2BRIDGE_OK;
}

S2BridgeStatus s2br_cap_contains_point(double lat_deg, double lng_deg,
                                       double radius_deg, double x, double y,
                                       double z, int* out) {
  S2Cap cap;
  if (!MakeCap(lat_deg, lng_deg, radius_deg, &cap)) {
    return S2BRIDGE_INVALID_ARGUMENT;
  }
  const double xyz[3] = {x, y, z};
  if (!IsUnitPoint(xyz)) return S2BRIDGE_INVALID_ARGUMENT;
  return PutBool(cap.Contains(S2Point(x, y, z)), out);
}

S2BridgeStatus s2br_rect_area_deg(double lat_lo_deg, double lng_lo_deg,
                                  double lat_hi_deg, double lng_hi_deg,
                                  double* out_steradians) {
  S2LatLngRect rect;
  if (!MakeRect(lat_lo_deg, lng_lo_deg, lat_hi_deg, lng_hi_deg, &rect)) {
    return S2BRIDGE_INVALID_ARGUMENT;
  }
  return PutDouble(rect.Area(), out_steradians);
}

S2BridgeStatus s2br_rect_contains_lat_lng_deg(double lat_lo_deg,
                                              double lng_lo_deg,
                                              double lat_hi_deg,
                                              double lng_hi_deg,
                                              double lat_deg, double lng_deg,
                                              int* out) {
  S2LatLngRect rect;
  if (!MakeRect(lat_lo_deg, lng_lo_deg, lat_hi_deg, lng_hi_deg, &rect) ||
      !AllFinite(lat_deg, lng_deg)) {
    return S2BRIDGE_INVALID_ARGUMENT;
  }
  return PutBool(rect.Contains(S2LatLng::FromDegrees(lat_deg, lng_deg)), out);
}

S2BridgeStatus s2br_rect_polar_closure_deg(double lat_lo_deg,
                                           double lng_lo_deg,
                                           double lat_hi_deg,
                                           double lng_hi_deg,
                                           double* out_bounds_deg4) {
  if (out_bounds_deg4 == nullptr) return S2BRIDGE_INVALID_ARGUMENT;
  S2LatLngRect rect;
  if (!MakeRect(lat_lo_deg, lng_lo_deg, lat_hi_deg, lng_hi_deg, &rect)) {
    return S2BRIDGE_INVALID_ARGUMENT;
  }
  const S2LatLngRect closed = rect.PolarClosure();
  out_bounds_deg4[0] = closed.lo().lat().degrees();
  out_bounds_deg4[1] = closed.lo().lng().degrees();
  out_bounds_deg4[2] = closed.hi().lat().degrees();
  out_bounds_deg4[3] = closed.hi().lng().degrees();
  return S2BRIDGE_OK;
}

S2BridgeStatus s2br_rect_is_inverted_deg(double lat_lo_deg, double lng_lo_deg,
                                         double lat_hi_deg, double lng_hi_deg,
                                         int* out) {
  S2LatLngRect rect;
  if (!MakeRect(lat_lo_deg, lng_lo_deg, lat_hi_deg, lng_hi_deg, &rect)) {
    return S2BRIDGE_INVALID_ARGUMENT;
  }
  return PutBool(rect.is_inverted(), out);
}

S2BridgeStatus s2br_rect_is_valid_deg(double lat_lo_deg, double lng_lo_deg,
                                      double lat_hi_deg, double lng_hi_deg,
                                      int* out) {
  S2LatLngRect rect;
  if (!MakeRect(lat_lo_deg, lng_lo_deg, lat_hi_deg, lng_hi_deg, &rect)) {
    return S2BRIDGE_INVALID_ARGUMENT;
  }
  return PutBool(rect.is_valid(), out);
}

// --- Loop ------------------------------------------------------------------

S2BridgeStatus s2br_loop_create(const double* xyz, size_t n,
                                S2BridgeLoop** out) {
  if (out == nullptr) return S2BRIDGE_INVALID_ARGUMENT;
  *out = nullptr;
  if (xyz == nullptr) return S2BRIDGE_INVALID_ARGUMENT;
  if (n < 3) return S2BRIDGE_INVALID_ARGUMENT;
  // A count `S2Loop::num_vertices_` cannot hold is refused before the first
  // vertex is read or anything is allocated; see `NativeCountFits`.
  if (!NativeCountFits(n, kVertexBytes)) return S2BRIDGE_INVALID_ARGUMENT;
  // A vertex that is not a direction is an argument upstream cannot answer
  // for; see `AllUnitPoints`.
  if (!AllUnitPoints(xyz, n)) return S2BRIDGE_INVALID_ARGUMENT;
  try {
    const std::vector<S2Point> vertices = AsOwnedPoints(xyz, n);
    auto handle = std::make_unique<S2BridgeLoop>();
    DeferValidation(&handle->loop,
                    absl::MakeConstSpan(vertices.data(), vertices.size()));
    *out = handle.release();
  } catch (const std::bad_alloc&) {
    return S2BRIDGE_OUT_OF_MEMORY;
  }
  return S2BRIDGE_OK;
}

S2BridgeStatus s2br_loop_create_empty(S2BridgeLoop** out) {
  if (out == nullptr) return S2BRIDGE_INVALID_ARGUMENT;
  *out = nullptr;
  try {
    auto handle = std::make_unique<S2BridgeLoop>();
    DeferValidation(&handle->loop, S2Loop::kEmpty());
    *out = handle.release();
  } catch (const std::bad_alloc&) {
    return S2BRIDGE_OUT_OF_MEMORY;
  }
  return S2BRIDGE_OK;
}

S2BridgeStatus s2br_loop_create_full(S2BridgeLoop** out) {
  if (out == nullptr) return S2BRIDGE_INVALID_ARGUMENT;
  *out = nullptr;
  try {
    auto handle = std::make_unique<S2BridgeLoop>();
    DeferValidation(&handle->loop, S2Loop::kFull());
    *out = handle.release();
  } catch (const std::bad_alloc&) {
    return S2BRIDGE_OUT_OF_MEMORY;
  }
  return S2BRIDGE_OK;
}

void s2br_loop_destroy(S2BridgeLoop* loop) { delete loop; }

S2BridgeStatus s2br_loop_num_vertices(const S2BridgeLoop* loop, int* out) {
  if (loop == nullptr) return S2BRIDGE_INVALID_ARGUMENT;
  return PutInt(loop->loop.num_vertices(), out);
}

S2BridgeStatus s2br_loop_vertex(const S2BridgeLoop* loop, int i, double* xyz) {
  if (loop == nullptr) return S2BRIDGE_INVALID_ARGUMENT;
  if (i < 0 || i >= loop->loop.num_vertices()) {
    return S2BRIDGE_INVALID_ARGUMENT;
  }
  return PutXYZ(loop->loop.vertex(i), xyz);
}

S2BridgeStatus s2br_loop_vertex_lat_lng_deg(const S2BridgeLoop* loop, int i,
                                            double* out_lat_deg,
                                            double* out_lng_deg) {
  if (loop == nullptr) return S2BRIDGE_INVALID_ARGUMENT;
  if (out_lat_deg == nullptr || out_lng_deg == nullptr) {
    return S2BRIDGE_INVALID_ARGUMENT;
  }
  if (i < 0 || i >= loop->loop.num_vertices()) {
    return S2BRIDGE_INVALID_ARGUMENT;
  }
  const S2LatLng ll(loop->loop.vertex(i));
  *out_lat_deg = ll.lat().degrees();
  *out_lng_deg = ll.lng().degrees();
  return S2BRIDGE_OK;
}

S2BridgeStatus s2br_loop_area(const S2BridgeLoop* loop,
                              double* out_steradians) {
  if (loop == nullptr) return S2BRIDGE_INVALID_ARGUMENT;
  try {
    // `S2::GetArea` reaches `GetCurvature` (`s2/s2loop_measures.cc:135-136`),
    // which copies the vertices into a `std::vector` to prune degeneracies
    // (`s2/s2loop_measures.cc:211-212`).
    return PutDouble(loop->loop.GetArea(), out_steradians);
  } catch (const std::bad_alloc&) {
    return S2BRIDGE_OUT_OF_MEMORY;
  }
}

S2BridgeStatus s2br_loop_contains_point(const S2BridgeLoop* loop, double x,
                                        double y, double z, int* out) {
  if (loop == nullptr) return S2BRIDGE_INVALID_ARGUMENT;
  try {
    // Above the brute-force threshold `S2Loop::Contains` creates a shape-index
    // iterator, which builds the loop's `MutableS2ShapeIndex`
    // (`s2/s2loop.cc:599-602`), and that allocates.
    return PutBool(loop->loop.Contains(S2Point(x, y, z)), out);
  } catch (const std::bad_alloc&) {
    return S2BRIDGE_OUT_OF_MEMORY;
  }
}

S2BridgeStatus s2br_loop_is_normalized(const S2BridgeLoop* loop, int* out) {
  if (loop == nullptr) return S2BRIDGE_INVALID_ARGUMENT;
  return PutBool(loop->loop.IsNormalized(), out);
}

S2BridgeStatus s2br_loop_normalize(S2BridgeLoop* loop) {
  if (loop == nullptr) return S2BRIDGE_INVALID_ARGUMENT;
  loop->loop.Normalize();
  return S2BRIDGE_OK;
}

S2BridgeStatus s2br_loop_invert(S2BridgeLoop* loop) {
  if (loop == nullptr) return S2BRIDGE_INVALID_ARGUMENT;
  loop->loop.Invert();
  return S2BRIDGE_OK;
}

S2BridgeStatus s2br_loop_is_empty(const S2BridgeLoop* loop, int* out) {
  if (loop == nullptr) return S2BRIDGE_INVALID_ARGUMENT;
  return PutBool(loop->loop.is_empty(), out);
}

S2BridgeStatus s2br_loop_is_full(const S2BridgeLoop* loop, int* out) {
  if (loop == nullptr) return S2BRIDGE_INVALID_ARGUMENT;
  return PutBool(loop->loop.is_full(), out);
}

S2BridgeStatus s2br_loop_is_valid(const S2BridgeLoop* loop, int* out) {
  if (loop == nullptr) return S2BRIDGE_INVALID_ARGUMENT;
  try {
    // A validation failure builds its message with `absl::StrFormat` into a
    // `std::string` (`s2/s2loop.cc:234`) and logs it through `absl::StrCat`.
    return PutBool(loop->loop.IsValid(), out);
  } catch (const std::bad_alloc&) {
    return S2BRIDGE_OUT_OF_MEMORY;
  }
}

// --- Polygon ---------------------------------------------------------------

S2BridgeStatus s2br_polygon_create(const double* xyz, size_t n,
                                   S2BridgePolygon** out) {
  if (out == nullptr) return S2BRIDGE_INVALID_ARGUMENT;
  *out = nullptr;
  if (xyz == nullptr) return S2BRIDGE_INVALID_ARGUMENT;
  if (n < 3) return S2BRIDGE_INVALID_ARGUMENT;
  // The shell is a loop before it is a polygon, so it inherits that count
  // bound; see `NativeCountFits`.
  if (!NativeCountFits(n, kVertexBytes)) return S2BRIDGE_INVALID_ARGUMENT;
  // A vertex that is not a direction is an argument upstream cannot answer
  // for; see `AllUnitPoints`.
  if (!AllUnitPoints(xyz, n)) return S2BRIDGE_INVALID_ARGUMENT;
  try {
    const std::vector<S2Point> vertices = AsOwnedPoints(xyz, n);
    auto loop = MakeDeferredValidationLoop(
        absl::MakeConstSpan(vertices.data(), vertices.size()));
    auto handle = std::make_unique<S2BridgePolygon>();
    DeferValidation(&handle->polygon);
    handle->polygon.Init(std::move(loop));
    *out = handle.release();
  } catch (const std::bad_alloc&) {
    return S2BRIDGE_OUT_OF_MEMORY;
  }
  return S2BRIDGE_OK;
}

S2BridgeStatus s2br_polygon_create_loops(const double* xyz,
                                         const size_t* loop_sizes,
                                         size_t num_loops,
                                         S2BridgePolygon** out) {
  if (out == nullptr) return S2BRIDGE_INVALID_ARGUMENT;
  *out = nullptr;
  if (num_loops == 0) return S2BRIDGE_INVALID_ARGUMENT;
  // `S2Polygon::num_loops()` narrows `loops_.size()` to an `int`
  // (`s2/s2polygon.h:248`), and the whole length list is read before anything
  // else happens, so a loop count that is not representable is refused before
  // the first read of it; see `NativeCountFits`.
  if (!NativeCountFits(num_loops, sizeof(size_t))) {
    return S2BRIDGE_INVALID_ARGUMENT;
  }
  if (xyz == nullptr || loop_sizes == nullptr) {
    return S2BRIDGE_INVALID_ARGUMENT;
  }
  // Each loop needs at least three vertices (`s2/s2loop.h:129-130`) and each
  // length is a count `S2Loop::Init` stores in an `int`, and the total is
  // accumulated with an overflow check, so a length list that cannot describe
  // a real vertex array is rejected instead of wrapping or narrowing.
  size_t total = 0;
  for (size_t i = 0; i < num_loops; ++i) {
    if (loop_sizes[i] < 3) return S2BRIDGE_INVALID_ARGUMENT;
    if (!NativeCountFits(loop_sizes[i], kVertexBytes)) {
      return S2BRIDGE_INVALID_ARGUMENT;
    }
    if (loop_sizes[i] > SIZE_MAX - total) return S2BRIDGE_INVALID_ARGUMENT;
    total += loop_sizes[i];
  }
  // `S2Polygon::InitLoopProperties` adds the per-loop counts up in one `int`
  // (`s2/s2polygon.cc:530`), and `AllUnitPoints` below walks the whole array
  // three doubles at a time, so the total is bounded exactly as one loop's
  // count is. A sum that is individually fine can still exceed the total.
  if (!NativeCountFits(total, kVertexBytes)) return S2BRIDGE_INVALID_ARGUMENT;
  // Every loop here goes through `S2Loop::Init`, so every vertex has to be a
  // unit-length direction before the first one is turned into an `S2Point`:
  // see `AllUnitPoints`.
  if (!AllUnitPoints(xyz, total)) return S2BRIDGE_INVALID_ARGUMENT;
  try {
    std::vector<std::unique_ptr<S2Loop>> owned;
    owned.reserve(num_loops);
    size_t offset = 0;
    for (size_t i = 0; i < num_loops; ++i) {
      const std::vector<S2Point> vertices =
          AsOwnedPoints(xyz + 3 * offset, loop_sizes[i]);
      auto loop = MakeDeferredValidationLoop(
          absl::MakeConstSpan(vertices.data(), vertices.size()));
      owned.push_back(std::move(loop));
      offset += loop_sizes[i];
    }
    auto handle = std::make_unique<S2BridgePolygon>();
    DeferValidation(&handle->polygon);
    handle->polygon.InitNested(std::move(owned));
    *out = handle.release();
  } catch (const std::bad_alloc&) {
    return S2BRIDGE_OUT_OF_MEMORY;
  }
  return S2BRIDGE_OK;
}

S2BridgeStatus s2br_polygon_create_empty(S2BridgePolygon** out) {
  if (out == nullptr) return S2BRIDGE_INVALID_ARGUMENT;
  *out = nullptr;
  try {
    auto handle = std::make_unique<S2BridgePolygon>();
    DeferValidation(&handle->polygon);
    // A default-constructed S2Polygon has no loops, which is exactly what
    // `is_empty()` reports (`s2/s2polygon.h:241`).
    *out = handle.release();
  } catch (const std::bad_alloc&) {
    return S2BRIDGE_OUT_OF_MEMORY;
  }
  return S2BRIDGE_OK;
}

S2BridgeStatus s2br_polygon_create_full(S2BridgePolygon** out) {
  if (out == nullptr) return S2BRIDGE_INVALID_ARGUMENT;
  *out = nullptr;
  try {
    auto handle = std::make_unique<S2BridgePolygon>();
    handle->polygon = S2Polygon::MakeFull();
    // After the move assignment, which copies the temporary's
    // `S2Debug::ALLOW` (`s2/s2polygon.cc:192`).
    DeferValidation(&handle->polygon);
    *out = handle.release();
  } catch (const std::bad_alloc&) {
    return S2BRIDGE_OUT_OF_MEMORY;
  }
  return S2BRIDGE_OK;
}

void s2br_polygon_destroy(S2BridgePolygon* polygon) { delete polygon; }

S2BridgeStatus s2br_polygon_num_loops(const S2BridgePolygon* polygon,
                                      int* out) {
  if (polygon == nullptr) return S2BRIDGE_INVALID_ARGUMENT;
  return PutInt(polygon->polygon.num_loops(), out);
}

S2BridgeStatus s2br_polygon_num_vertices(const S2BridgePolygon* polygon,
                                         int* out) {
  if (polygon == nullptr) return S2BRIDGE_INVALID_ARGUMENT;
  return PutInt(polygon->polygon.num_vertices(), out);
}

S2BridgeStatus s2br_polygon_loop_num_vertices(const S2BridgePolygon* polygon,
                                               int loop_index, int* out) {
  if (polygon == nullptr) return S2BRIDGE_INVALID_ARGUMENT;
  if (loop_index < 0 || loop_index >= polygon->polygon.num_loops()) {
    return S2BRIDGE_INVALID_ARGUMENT;
  }
  return PutInt(polygon->polygon.loop(loop_index)->num_vertices(), out);
}

S2BridgeStatus s2br_polygon_loop_vertex(const S2BridgePolygon* polygon,
                                        int loop_index, int vertex_index,
                                        double* xyz) {
  if (polygon == nullptr) return S2BRIDGE_INVALID_ARGUMENT;
  if (loop_index < 0 || loop_index >= polygon->polygon.num_loops()) {
    return S2BRIDGE_INVALID_ARGUMENT;
  }
  const S2Loop* loop = polygon->polygon.loop(loop_index);
  if (vertex_index < 0 || vertex_index >= loop->num_vertices()) {
    return S2BRIDGE_INVALID_ARGUMENT;
  }
  return PutXYZ(loop->vertex(vertex_index), xyz);
}

S2BridgeStatus s2br_polygon_loop_vertex_lat_lng_deg(
    const S2BridgePolygon* polygon, int loop_index, int vertex_index,
    double* out_lat_deg, double* out_lng_deg) {
  if (polygon == nullptr) return S2BRIDGE_INVALID_ARGUMENT;
  if (out_lat_deg == nullptr || out_lng_deg == nullptr) {
    return S2BRIDGE_INVALID_ARGUMENT;
  }
  if (loop_index < 0 || loop_index >= polygon->polygon.num_loops()) {
    return S2BRIDGE_INVALID_ARGUMENT;
  }
  const S2Loop* loop = polygon->polygon.loop(loop_index);
  if (vertex_index < 0 || vertex_index >= loop->num_vertices()) {
    return S2BRIDGE_INVALID_ARGUMENT;
  }
  const S2LatLng ll(loop->vertex(vertex_index));
  *out_lat_deg = ll.lat().degrees();
  *out_lng_deg = ll.lng().degrees();
  return S2BRIDGE_OK;
}

S2BridgeStatus s2br_polygon_area(const S2BridgePolygon* polygon,
                                 double* out_steradians) {
  if (polygon == nullptr) return S2BRIDGE_INVALID_ARGUMENT;
  try {
    // Every loop's `GetArea` has the same allocation as `s2br_loop_area`.
    return PutDouble(polygon->polygon.GetArea(), out_steradians);
  } catch (const std::bad_alloc&) {
    return S2BRIDGE_OUT_OF_MEMORY;
  }
}

S2BridgeStatus s2br_polygon_contains_point(const S2BridgePolygon* polygon,
                                           double x, double y, double z,
                                           int* out) {
  if (polygon == nullptr) return S2BRIDGE_INVALID_ARGUMENT;
  const double xyz[3] = {x, y, z};
  if (!IsUnitPoint(xyz)) return S2BRIDGE_INVALID_ARGUMENT;
  try {
    // `S2ContainsPointQuery` builds the polygon's `MutableS2ShapeIndex` on
    // first use (`s2/s2polygon.cc:728`), which allocates.
    return PutBool(polygon->polygon.Contains(S2Point(x, y, z)), out);
  } catch (const std::bad_alloc&) {
    return S2BRIDGE_OUT_OF_MEMORY;
  }
}

S2BridgeStatus s2br_polygon_contains_lat_lng_deg(
    const S2BridgePolygon* polygon, double lat_deg, double lng_deg, int* out) {
  if (polygon == nullptr) return S2BRIDGE_INVALID_ARGUMENT;
  if (!AllFinite(lat_deg, lng_deg)) return S2BRIDGE_INVALID_ARGUMENT;
  // `S2Polygon::Contains` takes an `S2Point` (`s2/s2polygon.h:654-656`), not a
  // coordinate, and `S2LatLng::ToPoint` produces the unit-length direction that
  // overload REQUIRES (`s2/s2polygon.h:653`). Same index build as
  // `s2br_polygon_contains_point`.
  try {
    return PutBool(
        polygon->polygon.Contains(
            S2LatLng::FromDegrees(lat_deg, lng_deg).ToPoint()),
        out);
  } catch (const std::bad_alloc&) {
    return S2BRIDGE_OUT_OF_MEMORY;
  }
}

S2BridgeStatus s2br_polygon_centroid_lat_lng_deg(const S2BridgePolygon* polygon,
                                                  double* out_lat_deg,
                                                  double* out_lng_deg) {
  if (polygon == nullptr) return S2BRIDGE_INVALID_ARGUMENT;
  if (out_lat_deg == nullptr || out_lng_deg == nullptr) {
    return S2BRIDGE_INVALID_ARGUMENT;
  }
  // `GetCentroid` is area-weighted and not unit length
  // (`s2/s2polygon.h:279-286`).
  const S2LatLng ll(polygon->polygon.GetCentroid().Normalize());
  *out_lat_deg = ll.lat().degrees();
  *out_lng_deg = ll.lng().degrees();
  return S2BRIDGE_OK;
}

S2BridgeStatus s2br_polygon_is_empty(const S2BridgePolygon* polygon, int* out) {
  if (polygon == nullptr) return S2BRIDGE_INVALID_ARGUMENT;
  return PutBool(polygon->polygon.is_empty(), out);
}

S2BridgeStatus s2br_polygon_is_full(const S2BridgePolygon* polygon, int* out) {
  if (polygon == nullptr) return S2BRIDGE_INVALID_ARGUMENT;
  return PutBool(polygon->polygon.is_full(), out);
}

S2BridgeStatus s2br_polygon_is_valid(const S2BridgePolygon* polygon, int* out) {
  if (polygon == nullptr) return S2BRIDGE_INVALID_ARGUMENT;
  try {
    // As for a loop, a validation failure formats its message through
    // `absl::StrFormat` (`s2/s2polygon.cc:264`, `:277`).
    return PutBool(polygon->polygon.IsValid(), out);
  } catch (const std::bad_alloc&) {
    return S2BRIDGE_OUT_OF_MEMORY;
  }
}

S2BridgeStatus s2br_polygon_complement(const S2BridgePolygon* polygon,
                                       S2BridgePolygon** out) {
  if (polygon == nullptr || out == nullptr) return S2BRIDGE_INVALID_ARGUMENT;
  *out = nullptr;
  try {
    auto handle = std::make_unique<S2BridgePolygon>();
    handle->polygon.InitToComplement(polygon->polygon);
    *out = handle.release();
  } catch (const std::bad_alloc&) {
    return S2BRIDGE_OUT_OF_MEMORY;
  }
  return S2BRIDGE_OK;
}

namespace {

// Upstream states the precondition of these two operations in the header that
// declares them: "The versions of these functions with an S2Error argument
// return true on success and set `error` appropriately otherwise.  However
// note that these functions should never return an error provided that both
// input polygons are valid (i.e., IsValid() returns true)"
// (`s2/s2polygon.h:385-388`). So the validity of the operands is what decides
// whether a failure is a failure at all, and an invalid operand is an
// argument, not a result: `InitToOperation` hands both operands to
// `S2BooleanOperation` (`s2/s2polygon.cc:936-943`), which has no answer for a
// polygon its own validator rejects. `IsValid` is upstream's own predicate
// for that question, asked before the operation rather than inferred from its
// outcome, and this bridge does not get to decide what a valid polygon is. Its
// error message is formatted through `absl::StrFormat`
// (`s2/s2polygon.cc:255-263`), so the allocation it may need is still the
// reportable one it is everywhere else.
S2BridgeStatus RequireValidOperand(const S2BridgePolygon* polygon) {
  try {
    if (polygon->polygon.IsValid()) return S2BRIDGE_OK;
  } catch (const std::bad_alloc&) {
    return S2BRIDGE_OUT_OF_MEMORY;
  }
  return S2BRIDGE_INVALID_ARGUMENT;
}

// Both entry points below are the same call with a different operator, so the
// operand precondition, the deferral of the result's validity check and the
// error mapping are stated once here rather than twice.
enum class BooleanOp { kIntersection, kUnion };

S2BridgeStatus BooleanOperation(BooleanOp op, const S2BridgePolygon* a,
                                const S2BridgePolygon* b,
                                S2BridgePolygon** out) {
  const S2BridgeStatus a_status = RequireValidOperand(a);
  if (a_status != S2BRIDGE_OK) return a_status;
  const S2BridgeStatus b_status = RequireValidOperand(b);
  if (b_status != S2BRIDGE_OK) return b_status;
  try {
    auto handle = std::make_unique<S2BridgePolygon>();
    // Before the call that can check it, as everywhere else: the result is a
    // handle this bridge owns, and it is built through `S2PolygonLayer`, whose
    // `Options` default leaves `validate_` false
    // (`s2/s2builderutil_s2polygon_layer.h:117-119`) so it never applies the
    // override itself (`s2/s2builderutil_s2polygon_layer.cc:75-83`) and stamps
    // every loop it emits with the result's own override
    // (`s2/s2builderutil_s2polygon_layer.cc:99`). Left at the default
    // `S2Debug::ALLOW` (`s2/s2polygon.h:876`), each of those loops would run
    // the fatal `ABSL_CHECK(IsValid())` of `S2Loop::InitIndex`
    // (`s2/s2loop.cc:353-359`) on a caller-supplied chain that
    // `s2br_polygon_is_valid` is there to report.
    DeferValidation(&handle->polygon);
    // The snap function is the one upstream's own two-argument overloads pass
    // -- `IdentitySnapFunction(S2::kIntersectionMergeRadius)`
    // (`s2/s2polygon.cc:955-957`, `:981-983`) -- so the result is the result
    // of the operation this header documents rather than of a variant of it.
    S2Error error;
    const bool built =
        op == BooleanOp::kIntersection
            ? handle->polygon.InitToIntersection(
                  a->polygon, b->polygon,
                  s2builderutil::IdentitySnapFunction(
                      S2::kIntersectionMergeRadius),
                  &error)
            : handle->polygon.InitToUnion(
                  a->polygon, b->polygon,
                  s2builderutil::IdentitySnapFunction(
                      S2::kIntersectionMergeRadius),
                  &error);
    // `S2Error` out-parameter, so upstream's answer is a status here. The
    // overloads without it are `ABSL_LOG(DFATAL) << ... << error`
    // (`s2/s2polygon.cc:945-951`), and DFATAL aborts in every optimize mode, so
    // they could not report this as anything at all. `*out` is still null and
    // `handle` still owns the result, so a failure releases the partial output
    // through the unique_ptr and hands the caller no half-built polygon.
    if (!built) return S2BRIDGE_INTERNAL_ERROR;
    *out = handle.release();
  } catch (const std::bad_alloc&) {
    return S2BRIDGE_OUT_OF_MEMORY;
  }
  return S2BRIDGE_OK;
}

}  // namespace

S2BridgeStatus s2br_polygon_intersection(const S2BridgePolygon* a,
                                         const S2BridgePolygon* b,
                                         S2BridgePolygon** out) {
  if (a == nullptr || b == nullptr || out == nullptr) {
    return S2BRIDGE_INVALID_ARGUMENT;
  }
  *out = nullptr;
  return BooleanOperation(BooleanOp::kIntersection, a, b, out);
}

S2BridgeStatus s2br_polygon_union(const S2BridgePolygon* a,
                                  const S2BridgePolygon* b,
                                  S2BridgePolygon** out) {
  if (a == nullptr || b == nullptr || out == nullptr) {
    return S2BRIDGE_INVALID_ARGUMENT;
  }
  *out = nullptr;
  return BooleanOperation(BooleanOp::kUnion, a, b, out);
}

// --- Region covering -------------------------------------------------------

namespace {

// Turns the caller's four integers into upstream's Options, rejecting the
// combinations upstream only debug-asserts. `s2/s2region_coverer.cc:44-47`
// checks `min_level <= max_level` with ABSL_DCHECK, which is compiled out in
// ReleaseFast, so doing it here is what makes the bound real on every build.
S2BridgeStatus MakeCoverer(const S2BridgeCovererOptions* opts,
                           S2RegionCoverer::Options* out) {
  if (opts == nullptr) return S2BRIDGE_INVALID_ARGUMENT;
  if (opts->min_level < 0 || opts->min_level > S2BRIDGE_MAX_LEVEL) {
    return S2BRIDGE_INVALID_ARGUMENT;
  }
  if (opts->max_level < 0 || opts->max_level > S2BRIDGE_MAX_LEVEL) {
    return S2BRIDGE_INVALID_ARGUMENT;
  }
  if (opts->min_level > opts->max_level) return S2BRIDGE_INVALID_ARGUMENT;
  // `set_level_mod` asserts 1..3 (`s2/s2region_coverer.cc:79-83`).
  if (opts->level_mod < 1 || opts->level_mod > 3) {
    return S2BRIDGE_INVALID_ARGUMENT;
  }
  if (opts->max_cells < 1) return S2BRIDGE_INVALID_ARGUMENT;
  *out = S2RegionCoverer::Options();
  out->set_min_level(opts->min_level);
  out->set_max_level(opts->max_level);
  out->set_level_mod(opts->level_mod);
  out->set_max_cells(opts->max_cells);
  return S2BRIDGE_OK;
}

// Runs the coverer on `region` and applies the two-pass buffer contract. The
// vector is upstream's `std::vector<S2CellId>`
// (`s2/s2region_coverer.h:187-193`) and dies with this function.
S2BridgeStatus CoverRegion(const S2Region& region,
                           const S2BridgeCovererOptions* opts, uint64_t* out,
                           size_t cap, size_t* out_count) {
  if (out_count == nullptr) return S2BRIDGE_INVALID_ARGUMENT;
  *out_count = 0;
  S2RegionCoverer::Options options;
  const S2BridgeStatus status = MakeCoverer(opts, &options);
  if (status != S2BRIDGE_OK) return status;
  try {
    S2RegionCoverer coverer(options);
    std::vector<S2CellId> covering;
    coverer.GetCovering(region, &covering);
    return DrainIds(covering, out, cap, out_count);
  } catch (const std::bad_alloc&) {
    return S2BRIDGE_OUT_OF_MEMORY;
  }
}

}  // namespace

S2BridgeStatus s2br_coverer_covering_cap(double lat_deg, double lng_deg,
                                         double radius_deg,
                                         const S2BridgeCovererOptions* opts,
                                         uint64_t* out, size_t cap,
                                         size_t* out_count) {
  S2Cap region;
  if (!MakeCap(lat_deg, lng_deg, radius_deg, &region)) {
    if (out_count != nullptr) *out_count = 0;
    return S2BRIDGE_INVALID_ARGUMENT;
  }
  return CoverRegion(region, opts, out, cap, out_count);
}

S2BridgeStatus s2br_coverer_covering_rect(double lat_lo_deg, double lng_lo_deg,
                                          double lat_hi_deg, double lng_hi_deg,
                                          const S2BridgeCovererOptions* opts,
                                          uint64_t* out, size_t cap,
                                          size_t* out_count) {
  S2LatLngRect rect;
  if (!MakeRect(lat_lo_deg, lng_lo_deg, lat_hi_deg, lng_hi_deg, &rect)) {
    if (out_count != nullptr) *out_count = 0;
    return S2BRIDGE_INVALID_ARGUMENT;
  }
  return CoverRegion(rect, opts, out, cap, out_count);
}

S2BridgeStatus s2br_coverer_covering_polygon(const S2BridgePolygon* polygon,
                                             const S2BridgeCovererOptions* opts,
                                             uint64_t* out, size_t cap,
                                             size_t* out_count) {
  if (out_count != nullptr) *out_count = 0;
  if (polygon == nullptr) return S2BRIDGE_INVALID_ARGUMENT;
  return CoverRegion(polygon->polygon, opts, out, cap, out_count);
}

S2BridgeStatus s2br_coverer_covering_cell(uint64_t id,
                                          const S2BridgeCovererOptions* opts,
                                          uint64_t* out, size_t cap,
                                          size_t* out_count) {
  if (out_count != nullptr) *out_count = 0;
  if (!s2br_cell_is_valid(id)) return S2BRIDGE_INVALID_ARGUMENT;
  const S2Cell cell{S2CellId(id)};
  return CoverRegion(cell, opts, out, cap, out_count);
}

// --- Raw loop measurements -------------------------------------------------

S2BridgeStatus s2br_loop_perimeter_rad(const S2BridgeLoop* loop,
                                       double* out_radians) {
  if (loop == nullptr) return S2BRIDGE_INVALID_ARGUMENT;
  // `S2::GetPerimeter` only sums `S1Angle`s over the span
  // (`s2/s2loop_measures.cc:42-49`), and `vertices_span()` is a view of the
  // loop's own storage (`s2/s2loop.h:216-220`), so this allocates nothing.
  const S2PointLoopSpan span = loop->loop.vertices_span();
  return PutDouble(S2::GetPerimeter(span).radians(), out_radians);
}

S2BridgeStatus s2br_loop_signed_area(const S2BridgeLoop* loop,
                                     double* out_steradians) {
  if (loop == nullptr) return S2BRIDGE_INVALID_ARGUMENT;
  try {
    // Same zero-copy span as `s2br_loop_perimeter_rad`. `S2::GetSignedArea`
    // may reach `GetCurvature`, which allocates (`s2/s2loop_measures.cc:211`),
    // so the failure is still a reportable one here.
    const S2PointLoopSpan span = loop->loop.vertices_span();
    return PutDouble(S2::GetSignedArea(span), out_steradians);
  } catch (const std::bad_alloc&) {
    return S2BRIDGE_OUT_OF_MEMORY;
  }
}

}  // extern "C"