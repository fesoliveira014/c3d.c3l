module c3d::nav;

import std::math;
import c3d;

<* Handle to a queued path request; 0 is invalid. *>
typedef PathQueueRef = uint;

<* Requests a queue holds; mirrors MAX_QUEUE. *>
const uint MAX_PATH_QUEUE = 8;

const int MAX_KEEP_ALIVE @local = 2; // mirrors dtPathQueue::update: updates a finished result waits to be collected

<* Progress of one queued request; mirrors the request's dtStatus. *>
enum PathRequestState {
    PENDING,        // the search has not started
    IN_PROGRESS,
    DONE,           // path_result returns the corridor
    FAILED,
}

<* One queued request; mirrors dtPathQueue::PathQuery. *>
struct PathRequest {
    PathQueueRef     ref;          // 0 while the slot is free
    Vec3             start;
    Vec3             end;
    PolyRef          start_ref;
    PolyRef          end_ref;
    PolyRef[]        path;         // max_path_size
    usz              count;
    bool             partial;      // the goal was unreachable or the corridor ends short of it
    PathRequestState state;
    int              keep_alive;   // updates since the request finished
    QueryFilter*     filter;       // must outlive the request
}

<* Round-robin sliced path finder for a crowd; mirrors dtPathQueue. *>
struct PathQueue {
    Allocator                   allocator;
    PathRequest[MAX_PATH_QUEUE] queue;
    PathQueueRef                next_handle;
    usz                         max_path_size;
    uint                        head;
    NavQuery                    query;
}

<*
 Advance the requests round-robin by up to max_iterations search steps in total; mirrors update.
 Results nobody collects within two updates are dropped.
*>
fn void PathQueue.update(&self, uint max_iterations) {
    int iterations_left = (int)max_iterations;
    for (uint visited = 0; visited < MAX_PATH_QUEUE; visited++) {
        PathRequest* request = &self.queue[self.head % MAX_PATH_QUEUE];
        if (!request.ref) {
            self.head++;
            continue;
        }
        if (request.state == DONE || request.state == FAILED) {
            request.keep_alive++;
            if (request.keep_alive > MAX_KEEP_ALIVE) {
                request.ref = (PathQueueRef)0;
                request.state = PENDING;
            }
            self.head++;
            continue;
        }

        if (request.state == PENDING) {
            request.state = IN_PROGRESS;
            if (catch self.query.init_sliced_find_path(
                start_ref: request.start_ref,
                end_ref:   request.end_ref,
                start:     request.start,
                end:       request.end,
                filter:    request.filter,
            )) {
                request.state = FAILED;
            }
        }
        if (request.state == IN_PROGRESS) {
            SlicedProgress? progress = self.query.update_sliced_find_path((uint)iterations_left);
            if (catch progress) {
                request.state = FAILED;
            } else {
                iterations_left -= (int)progress.iterations;
                if (progress.status == DONE) finish_request(self, request);
            }
        }
        if (iterations_left <= 0) break;
        self.head++;
    }
}

<*
 Queue a request; 0 when every slot is taken; mirrors request.
 @param [&in] filter : "Must outlive the request."
*>
fn PathQueueRef PathQueue.request(
    &self,
    PolyRef start_ref,
    PolyRef end_ref,
    Vec3 start,
    Vec3 end,
    QueryFilter* filter,
) {
    foreach (&request : self.queue) {
        if (request.ref) continue;
        PathQueueRef ref = self.next_handle++;
        if (!self.next_handle) self.next_handle++;
        request.ref = ref;
        request.start = start;
        request.end = end;
        request.start_ref = start_ref;
        request.end_ref = end_ref;
        request.count = 0;
        request.partial = false;
        request.state = PENDING;
        request.keep_alive = 0;
        request.filter = filter;
        return ref;
    }
    return (PathQueueRef)0;
}

<* State of a request; FAILED for an unknown ref. *>
fn PathRequestState PathQueue.request_state(&self, PathQueueRef ref) {
    foreach (&request : self.queue) {
        if (ref && request.ref == ref) return request.state;
    }
    return FAILED;
}

<*
 Take the corridor of a request and free its slot; mirrors getPathResult.
 @param [out] out_path : "Filled up to its length."
 @return? INVALID_REF
*>
fn PathResult? PathQueue.path_result(&self, PathQueueRef ref, PolyRef[] out_path) {
    foreach (&request : self.queue) {
        if (!ref || request.ref != ref) continue;
        request.ref = (PathQueueRef)0;
        request.state = PENDING;
        usz count = math::min(request.count, (usz)out_path.len);
        out_path[:count] = request.path[:count];
        return { .count = count, .partial = request.partial, .truncated = request.count > out_path.len };
    }
    return INVALID_REF~;
}

<*
 Free the request paths and the query.
 @param [&inout] queue : "Left zeroed."
*>
fn void destroy_path_queue(PathQueue* queue) {
    foreach (&request : queue.queue) alloc::free(queue.allocator, request.path.ptr);
    destroy_nav_query(&queue.query);
    *queue = {};
}

<*
 Queue whose requests hold max_path_size polygons, searching with its own query of max_nodes.
 @param [&in] mesh : "Outlives the queue."
 @return? c3d::CAPACITY_EXCEEDED
 @require max_path_size > 0, max_nodes > 0 && max_nodes < (uint)NULL_NODE
*>
fn PathQueue? create_path_queue(
    Allocator allocator,
    usz max_path_size,
    uint max_nodes,
    NavMesh* mesh,
) {
    PathQueue queue = {
        .allocator     = allocator,
        .next_handle   = (PathQueueRef)1,
        .max_path_size = max_path_size,
        .query         = create_nav_query(allocator, mesh, max_nodes)!,
    };
    defer catch destroy_path_queue(&queue);
    foreach (&request : queue.queue) {
        PolyRef[]? path = alloc::new_array_try(allocator, PolyRef, (sz)max_path_size);
        if (catch path) return c3d::CAPACITY_EXCEEDED~;
        request.path = path;
    }
    return queue;
}

// A corridor cut short of the goal by the slot's size is as partial as an unreachable goal.
fn void finish_request(PathQueue* queue, PathRequest* request) @local {
    PathResult? result = queue.query.finalize_sliced_find_path(request.path);
    if (catch result) {
        request.state = FAILED;
        return;
    }
    request.count = result.count;
    request.partial = result.partial || result.truncated;
    request.state = DONE;
}
