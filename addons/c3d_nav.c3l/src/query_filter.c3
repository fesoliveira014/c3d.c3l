module c3d::nav;

import std::math;

<* Whether a polygon whose flags passed may be visited. *>
alias PassFn = fn bool (QueryFilter* filter, PolyRef ref, Poly* poly);

<* Cost of the segment inside current; next is null at the path's end. *>
alias CostFn = fn float (QueryFilter* filter, Vec3 from, Vec3 to, Poly* current, PolyRef next_ref, Poly* next);

<* Flags and costs a query applies; mirrors dtQueryFilter with typed hooks. *>
struct QueryFilter {
    ushort           include;      // a polygon passes when its flags share a bit with include
    ushort           exclude;      // and share none with exclude
    float[MAX_AREAS] area_cost;    // per metre, by area; at least 1 keeps the A* heuristic admissible
    PassFn           pass;         // null passes on flags alone
    CostFn           cost;         // null is distance times the current polygon's area cost
}

<*
 Whether the polygon passes: its flags meet include and miss exclude, then the hook when set.
 @param [&in] poly : "The polygon of ref."
*>
fn bool QueryFilter.passes(&self, PolyRef ref, Poly* poly) {
    if ((poly.flags & self.include) == 0 || (poly.flags & self.exclude) != 0) return false;
    return !self.pass || self.pass(self, ref, poly);
}

<*
 Cost of moving from one point to the other inside current.
 @param [&in] current : "The polygon the segment lies in."
 @param [in] next : "The polygon entered at to; null at the path's end."
*>
fn float QueryFilter.segment_cost(
    &self,
    Vec3 from,
    Vec3 to,
    Poly* current,
    PolyRef next_ref,
    Poly* next,
) {
    if (self.cost) return self.cost(self, from, to, current, next_ref, next);
    return (to - from).length() * self.area_cost[current.area_type.area];
}

<* Include everything, exclude nothing, every area at cost 1, no hooks. *>
fn QueryFilter default_query_filter() {
    QueryFilter filter = { .include = ushort::max };
    filter.area_cost[..] = 1;
    return filter;
}
