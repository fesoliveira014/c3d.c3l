module c3d::physics::fracture;

import c3d;
import std::sort;
import std::math;

struct PlanarSegment @private {
    PlaneTriple first;
    PlaneTriple second;
    ExactPlane*[2] line;
}

struct PlanarEdge @private {
    uint first;
    uint second;
    long weight;
    ExactPlane*[2] line;
}

struct PlanarEdges @private {
    PlaneTriple[] vertices;
    PlanarEdge[] edges;
}

struct PlanarPoint @local {
    PlaneTriple vertex;
    PlanarPoint* next;
    uint index;
}

struct PlanarPointList @local {
    PlanarPoint* first;
    uint count;
}

struct PlanarInput @local {
    PlanarPoint* first;
    PlanarPoint* second;
    ExactPlane*[2] line;
}

struct PlanarEdgeNode @local {
    PlanarEdge edge;
    PlanarEdgeNode* next;
}

fn PlanarPoint*? add_planar_point(SolidScratch* scratch, PlanarPointList* points, PlaneTriple vertex) @local {
    for (PlanarPoint* point = points.first; point; point = point.next) {
        if (same_vertex(scratch.exact, point.vertex, vertex)!) return point;
    }
    if (points.count == uint::max) return c3d::CAPACITY_EXCEEDED~;
    PlanarPoint* point = &reserve_elements(scratch, PlanarPoint, 1)![0];
    *point = { .vertex = vertex, .next = points.first };
    points.first = point;
    points.count++;
    return point;
}

fn void? add_planar_crossings(
    SolidScratch* scratch,
    PlanarPointList* points,
    PlanarInput[] inputs,
    ExactPlane* plane,
    uint dropped_axis,
) @local {
    foreach (usz index, first : inputs) {
        for (usz other = index + 1; other < inputs.len; other++) {
            PlanarInput second = inputs[other];
            int start = planar_orientation(
                scratch: scratch.exact,
                vertices: { first.first.vertex, first.second.vertex, second.first.vertex },
                dropped_axis: dropped_axis,
            )!;
            int end = planar_orientation(
                scratch: scratch.exact,
                vertices: { first.first.vertex, first.second.vertex, second.second.vertex },
                dropped_axis: dropped_axis,
            )!;
            if (!start || start != -end) continue;
            start = planar_orientation(
                scratch: scratch.exact,
                vertices: { second.first.vertex, second.second.vertex, first.first.vertex },
                dropped_axis: dropped_axis,
            )!;
            end = planar_orientation(
                scratch: scratch.exact,
                vertices: { second.first.vertex, second.second.vertex, first.second.vertex },
                dropped_axis: dropped_axis,
            )!;
            if (!start || start != -end) continue;
            ExactPlane* first_line = first.line[0];
            ExactPlane* second_line = second.line[0];
            if (!independent_plane_pair(scratch.exact, plane, first_line)!) first_line = first.line[1];
            if (!independent_plane_pair(scratch.exact, plane, second_line)!) second_line = second.line[1];
            (void)add_planar_point(scratch, points, { plane, first_line, second_line })!;
        }
    }
    return;
}

fn PlanarPoint*[]? order_planar_points(SolidScratch* scratch, PlanarPointList* points, uint dropped_axis) @local {
    PlanarPoint*[] ordered = reserve_elements(scratch, PlanarPoint*, points.count)!;
    uint count;
    for (PlanarPoint* point = points.first; point; point = point.next) {
        uint index = count++;
        while (index && compare_planar_points(
            scratch: scratch.exact,
            first: point.vertex,
            second: ordered[index - 1].vertex,
            dropped_axis: dropped_axis,
        )! < 0) {
            ordered[index] = ordered[index - 1];
            index--;
        }
        ordered[index] = point;
    }
    foreach (uint index, point : ordered) point.index = index;
    return ordered;
}

fn int compare_planar_edges(PlanarEdge first, PlanarEdge second) @local {
    if (first.first != second.first) return first.first < second.first ? -1 : 1;
    if (first.second != second.second) return first.second < second.second ? -1 : 1;
    int order = compare_exact_planes(first.line[0], second.line[0]);
    return order ? order : compare_exact_planes(first.line[1], second.line[1]);
}

fn PlanarEdge[]? split_planar_edges(
    SolidScratch* scratch,
    PlanarInput[] inputs,
    PlanarPoint*[] points,
    uint dropped_axis,
) @local {
    PlanarEdgeNode* first;
    uint count;
    foreach (input : inputs) {
        uint low = math::min(input.first.index, input.second.index);
        uint high = math::max(input.first.index, input.second.index);
        uint previous = low;
        for (uint index = low + 1; index <= high; index++) {
            if (planar_orientation(
                scratch: scratch.exact,
                vertices: { input.first.vertex, input.second.vertex, points[index].vertex },
                dropped_axis: dropped_axis,
            )!) continue;
            if (count == uint::max) return c3d::CAPACITY_EXCEEDED~;
            PlanarEdgeNode* node = &reserve_elements(scratch, PlanarEdgeNode, 1)![0];
            *node = {
                .edge = {
                    .first = previous,
                    .second = index,
                    .weight = input.first.index < input.second.index ? 1 : -1,
                    .line = input.line,
                },
                .next = first,
            };
            first = node;
            previous = index;
            count++;
        }
    }
    PlanarEdge[] edges = reserve_elements(scratch, PlanarEdge, count)!;
    count = 0;
    for (PlanarEdgeNode* node = first; node; node = node.next) edges[count++] = node.edge;
    sort::quicksort(edges, &compare_planar_edges);
    uint output;
    for (uint index = 0; index < count;) {
        PlanarEdge edge = edges[index++];
        while (index < count && edges[index].first == edge.first && edges[index].second == edge.second) {
            edge.weight += edges[index++].weight;
        }
        if (edge.weight) edges[output++] = edge;
    }
    return edges[:output];
}

fn PlanarEdges? normalize_planar_edges(
    SolidScratch* scratch,
    ExactPlane* plane,
    PlanarSegment[] segments,
) @private {
    usz saved = scratch.used;
    defer catch scratch.used = saved;
    if (segments.len > uint::max) return c3d::CAPACITY_EXCEEDED~;
    uint dropped_axis;
    while (!plane.coefficients[dropped_axis].used) dropped_axis++;
    PlanarInput[] inputs = reserve_elements(scratch, PlanarInput, segments.len)!;
    PlanarPointList list;
    foreach (index, segment : segments) {
        inputs[index] = {
            .first = add_planar_point(scratch, &list, segment.first)!,
            .second = add_planar_point(scratch, &list, segment.second)!,
            .line = segment.line,
        };
        if (compare_exact_planes(inputs[index].line[0], inputs[index].line[1]) > 0) {
            ExactPlane* swap = inputs[index].line[0];
            inputs[index].line[0] = inputs[index].line[1];
            inputs[index].line[1] = swap;
        }
    }
    add_planar_crossings(
        scratch: scratch,
        points: &list,
        inputs: inputs,
        plane: plane,
        dropped_axis: dropped_axis,
    )!;
    PlanarPoint*[] points = order_planar_points(scratch, &list, dropped_axis)!;
    PlanarEdge[] edges = split_planar_edges(
        scratch: scratch,
        inputs: inputs,
        points: points,
        dropped_axis: dropped_axis,
    )!;
    if (!edges.len) {
        scratch.used = saved;
        return {};
    }
    foreach (point : points) point.index = NO_SOLID_INDEX;
    foreach (edge : edges) {
        points[edge.first].index = 0;
        points[edge.second].index = 0;
    }
    uint count;
    foreach (point : points) if (point.index != NO_SOLID_INDEX) point.index = count++;
    PlaneTriple[] vertices = reserve_elements(scratch, PlaneTriple, count)!;
    foreach (point : points) if (point.index != NO_SOLID_INDEX) vertices[point.index] = point.vertex;
    foreach (&edge : edges) {
        edge.first = points[edge.first].index;
        edge.second = points[edge.second].index;
    }
    return { .vertices = vertices, .edges = edges };
}
