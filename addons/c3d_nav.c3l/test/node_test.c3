module c3d_nav_test;

import std::math;
import c3d;
import c3d::nav @public;

const uint QUEUE_NODES @private = 100;
const uint QUEUE_HASH_SIZE @private = 32;
const uint TOTAL_SHUFFLE @private = 37; // coprime with QUEUE_NODES, so the totals are a permutation
const uint LOWERED_NODE @private = 50;

fn void test_node_pool_returns_the_same_node_for_a_ref_and_state() @test {
    NodePool pool = nav::create_node_pool(mem, 2, 4)!!;
    defer nav::destroy_node_pool(&pool);
    PolyRef ref = nav::encode_poly_ref(1, 2, 3);

    SearchNode* first = pool.get_node(ref);
    SearchNode* again = pool.get_node(ref);
    SearchNode* crossed = pool.get_node(ref, 1);

    SearchNode*[nav::MAX_NODE_STATES] found;
    assert(first && again == first);
    assert(crossed && crossed != first && pool.find_node(ref, 1) == crossed);
    assert(pool.find_nodes(ref, found[..]) == 2);
    assert(pool.node_at(pool.node_index(crossed)) == crossed);
    assert(!pool.get_node(nav::encode_poly_ref(1, 2, 4)), "the pool holds two nodes");
}

fn void test_node_queue_pops_in_total_order() @test {
    NodePool pool = nav::create_node_pool(mem, QUEUE_NODES, QUEUE_HASH_SIZE)!!;
    defer nav::destroy_node_pool(&pool);
    NodeQueue queue = nav::create_node_queue(mem, QUEUE_NODES)!!;
    defer nav::destroy_node_queue(&queue);
    for (uint index = 0; index < QUEUE_NODES; index++) {
        SearchNode* node = pool.get_node(nav::encode_poly_ref(1, 0, index));
        node.total = (float)((index * TOTAL_SHUFFLE) % QUEUE_NODES);
        queue.push(node);
    }
    SearchNode* lowered = pool.find_node(nav::encode_poly_ref(1, 0, LOWERED_NODE), 0);

    lowered.total = -1;
    queue.modify(lowered);

    assert(queue.pop() == lowered);
    float previous = -1;
    uint popped = 1;
    while (!queue.is_empty()) {
        SearchNode* node = queue.pop();
        assert(node.total >= previous);
        previous = node.total;
        popped++;
    }
    assert(popped == QUEUE_NODES);
}
