module c3d::nav;

import std::math;
import c3d;

<* Search node index; mirrors dtNodeIndex. *>
typedef NodeIndex = ushort;

<* Node index meaning none; mirrors DT_NULL_IDX. *>
const NodeIndex NULL_NODE = (NodeIndex)ushort::max;

<* Nodes one polygon may hold in a search, one per state; mirrors DT_MAX_STATES_PER_NODE. *>
const uint MAX_NODE_STATES = 4;

<* Parent index, state and flags of a search node; mirrors the dtNode bitfields. *>
bitstruct NodeBits : uint {
    uint parent          : 0..23;    // node index + 1; 0 is none
    uint state           : 24..25;
    bool open            : 26;
    bool closed          : 27;
    bool parent_detached : 28;       // reached through a raycast shortcut
}

<* A* search node; mirrors dtNode with a 64-bit ref. *>
struct SearchNode {
    Vec3     position;
    float    cost;         // from the parent node
    float    total;        // up to this node, heuristic included
    NodeBits bits;
    PolyRef  id;
}

$assert SearchNode::size == 32;

<* Fixed pool of search nodes keyed by ref and state; mirrors dtNodePool. *>
struct NodePool {
    Allocator    allocator;
    SearchNode[] nodes;
    NodeIndex[]  first;    // hash buckets
    NodeIndex[]  next;     // chain per node
    uint         count;
}

<* Binary heap of node pointers ordered by total; mirrors dtNodeQueue. *>
struct NodeQueue {
    Allocator     allocator;
    SearchNode*[] heap;    // capacity + 1
    uint          size;
}

<* Forget every node; capacity is kept. *>
fn void NodePool.clear(&self) {
    self.first[..] = NULL_NODE;
    self.count = 0;
}

<*
 Node for the ref and state, taken from the pool when absent; null when the pool is full.
 @require state < MAX_NODE_STATES
*>
fn SearchNode* NodePool.get_node(&self, PolyRef id, char state = 0) {
    uint bucket = hash_ref(id) & (uint)(self.first.len - 1);
    for (NodeIndex index = self.first[bucket]; index != NULL_NODE; index = self.next[(usz)index]) {
        SearchNode* node = &self.nodes[(usz)index];
        if (node.id == id && node.bits.state == state) return node;
    }
    if (self.count >= self.nodes.len) return null;

    usz index = self.count++;
    SearchNode* node = &self.nodes[index];
    *node = { .id = id, .bits = { .state = state } };
    self.next[index] = self.first[bucket];
    self.first[bucket] = (NodeIndex)index;
    return node;
}

<* Node for the ref and state, or null. *>
fn SearchNode* NodePool.find_node(&self, PolyRef id, char state) {
    uint bucket = hash_ref(id) & (uint)(self.first.len - 1);
    for (NodeIndex index = self.first[bucket]; index != NULL_NODE; index = self.next[(usz)index]) {
        SearchNode* node = &self.nodes[(usz)index];
        if (node.id == id && node.bits.state == state) return node;
    }
    return null;
}

<*
 Every node of the ref regardless of state.
 @param [out] out_nodes : "Filled up to its length."
 @return "How many were written."
*>
fn usz NodePool.find_nodes(&self, PolyRef id, SearchNode*[] out_nodes) {
    usz count;
    uint bucket = hash_ref(id) & (uint)(self.first.len - 1);
    for (NodeIndex index = self.first[bucket]; index != NULL_NODE; index = self.next[(usz)index]) {
        SearchNode* node = &self.nodes[(usz)index];
        if (node.id != id) continue;
        if (count == out_nodes.len) return count;
        out_nodes[count++] = node;
    }
    return count;
}

<*
 Index + 1 of a node; 0 for null.
 @param [in] node : "One of self.nodes, or null."
*>
fn uint NodePool.node_index(&self, SearchNode* node) {
    if (!node) return 0;
    return (uint)(node - self.nodes.ptr) + 1;
}

<* Node of an index + 1; null for 0. *>
fn SearchNode* NodePool.node_at(&self, uint index) {
    if (!index) return null;
    return &self.nodes[index - 1];
}

<* Drop every node. *>
fn void NodeQueue.clear(&self) {
    self.size = 0;
}

<*
 Lowest-total node without removing it.
 @require self.size > 0
*>
fn SearchNode* NodeQueue.top(&self) {
    return self.heap[0];
}

<*
 Remove and return the lowest-total node.
 @require self.size > 0
*>
fn SearchNode* NodeQueue.pop(&self) {
    SearchNode* result = self.heap[0];
    self.size--;
    trickle_down(self, 0, self.heap[self.size]);
    return result;
}

<*
 Insert a node.
 @param [&in] node : "Stays owned by its pool."
 @require self.size < self.heap.len
*>
fn void NodeQueue.push(&self, SearchNode* node) {
    self.size++;
    bubble_up(self, self.size - 1, node);
}

<*
 Re-sort a queued node whose total decreased.
 @param [&in] node : "Queued."
*>
fn void NodeQueue.modify(&self, SearchNode* node) {
    for (uint index = 0; index < self.size; index++) {
        if (self.heap[index] != node) continue;
        bubble_up(self, index, node);
        return;
    }
}

<* Whether nothing is queued. *>
fn bool NodeQueue.is_empty(&self) => self.size == 0;

<*
 Pool of max_nodes with hash_size buckets, allocated once.
 @return? c3d::CAPACITY_EXCEEDED
 @require max_nodes > 0 && max_nodes < (uint)NULL_NODE
 @require hash_size > 0 && math::is_power_of_2(hash_size)
*>
fn NodePool? create_node_pool(Allocator allocator, uint max_nodes, uint hash_size) {
    NodePool pool = { .allocator = allocator };
    defer catch destroy_node_pool(&pool);
    SearchNode[]? nodes = alloc::new_array_try(allocator, SearchNode, max_nodes);
    if (catch nodes) return c3d::CAPACITY_EXCEEDED~;
    pool.nodes = nodes;
    NodeIndex[]? first = alloc::alloc_array_try(allocator, NodeIndex, hash_size);
    if (catch first) return c3d::CAPACITY_EXCEEDED~;
    pool.first = first;
    NodeIndex[]? next = alloc::alloc_array_try(allocator, NodeIndex, max_nodes);
    if (catch next) return c3d::CAPACITY_EXCEEDED~;
    pool.next = next;
    pool.first[..] = NULL_NODE;
    pool.next[..] = NULL_NODE;
    return pool;
}

<*
 Free the pool's arrays.
 @param [&inout] pool : "Left zeroed."
*>
fn void destroy_node_pool(NodePool* pool) {
    alloc::free(pool.allocator, pool.nodes.ptr);
    alloc::free(pool.allocator, pool.first.ptr);
    alloc::free(pool.allocator, pool.next.ptr);
    *pool = {};
}

<*
 Queue for capacity nodes, allocated once.
 @return? c3d::CAPACITY_EXCEEDED
 @require capacity > 0
*>
fn NodeQueue? create_node_queue(Allocator allocator, uint capacity) {
    SearchNode*[]? heap = alloc::new_array_try(allocator, SearchNode*, (usz)capacity + 1);
    if (catch heap) return c3d::CAPACITY_EXCEEDED~;
    return { .allocator = allocator, .heap = heap };
}

<*
 Free the heap.
 @param [&inout] queue : "Left zeroed."
*>
fn void destroy_node_queue(NodeQueue* queue) {
    alloc::free(queue.allocator, queue.heap.ptr);
    *queue = {};
}

// Thomas Wang's 64-bit mix; upstream's dtHashRef under DT_POLYREF64.
fn uint hash_ref(PolyRef ref) @local {
    ulong mixed = (ulong)ref;
    mixed = ~mixed + (mixed << 18);
    mixed ^= mixed >> 31;
    mixed *= 21;
    mixed ^= mixed >> 11;
    mixed += mixed << 6;
    mixed ^= mixed >> 22;
    return (uint)mixed;
}

fn void bubble_up(NodeQueue* queue, uint index, SearchNode* node) @local {
    while (index > 0) {
        uint parent = (index - 1) / 2;
        if (queue.heap[parent].total <= node.total) break;
        queue.heap[index] = queue.heap[parent];
        index = parent;
    }
    queue.heap[index] = node;
}

fn void trickle_down(NodeQueue* queue, uint index, SearchNode* node) @local {
    uint child = index * 2 + 1;
    while (child < queue.size) {
        if (child + 1 < queue.size && queue.heap[child].total > queue.heap[child + 1].total) child++;
        queue.heap[index] = queue.heap[child];
        index = child;
        child = index * 2 + 1;
    }
    bubble_up(queue, index, node);
}
