module c3d::nav;

import std::math;
import c3d;

const ushort NULL_GRID_ITEM @local = ushort::max; // ends a bucket chain; mirrors the grid's 0xffff
const uint   CELL_HASH_X @local = 73856093; // mirrors hashPos2's primes
const uint   CELL_HASH_Z @local = 19349663;
const int    EMPTY_BOUNDS @local = 0xffff; // mirrors clear: bounds start inverted

<* One cell entry of a proximity grid; mirrors dtProximityGrid::Item. *>
struct GridItem {
    ushort id;
    short  x;
    short  z;
    ushort next;    // pool index of the next item in the bucket
}

<* Hash grid of agent bounds for neighbour queries; mirrors dtProximityGrid. *>
struct ProximityGrid {
    Allocator  allocator;
    float      cell_size;
    float      inverse_cell_size;
    GridItem[] pool;
    uint       pool_head;
    ushort[]   buckets;       // next power of two of the pool size
    int[4]     bounds;        // cells covered since clear: min x, min z, max x, max z
}

<* Drop every item. *>
fn void ProximityGrid.clear(&self) {
    self.buckets[..] = NULL_GRID_ITEM;
    self.pool_head = 0;
    self.bounds = { EMPTY_BOUNDS, EMPTY_BOUNDS, -EMPTY_BOUNDS, -EMPTY_BOUNDS };
}

<* Add an item over every cell of the XZ box; cells past the pool are dropped. *>
fn void ProximityGrid.add_item(
    &self,
    ushort id,
    float min_x,
    float min_z,
    float max_x,
    float max_z,
) {
    int low_x = (int)math::floor(min_x * self.inverse_cell_size);
    int low_z = (int)math::floor(min_z * self.inverse_cell_size);
    int high_x = (int)math::floor(max_x * self.inverse_cell_size);
    int high_z = (int)math::floor(max_z * self.inverse_cell_size);
    self.bounds[0] = math::min(self.bounds[0], low_x);
    self.bounds[1] = math::min(self.bounds[1], low_z);
    self.bounds[2] = math::max(self.bounds[2], high_x);
    self.bounds[3] = math::max(self.bounds[3], high_z);

    for (int z = low_z; z <= high_z; z++) {
        for (int x = low_x; x <= high_x; x++) {
            if (self.pool_head >= self.pool.len) continue;
            uint bucket = cell_bucket(x, z, (uint)self.buckets.len);
            ushort index = (ushort)self.pool_head++;
            self.pool[index] = { .id = id, .x = (short)x, .z = (short)z, .next = self.buckets[bucket] };
            self.buckets[bucket] = index;
        }
    }
}

<*
 Unique ids of the items overlapping the cells of the XZ box.
 @param out_ids : "Filled up to its length."
 @return "How many were written."
*>
fn usz ProximityGrid.query_items(
    &self,
    float min_x,
    float min_z,
    float max_x,
    float max_z,
    ushort[] out_ids,
) {
    int low_x = (int)math::floor(min_x * self.inverse_cell_size);
    int low_z = (int)math::floor(min_z * self.inverse_cell_size);
    int high_x = (int)math::floor(max_x * self.inverse_cell_size);
    int high_z = (int)math::floor(max_z * self.inverse_cell_size);

    usz count;
    for (int z = low_z; z <= high_z; z++) {
        for (int x = low_x; x <= high_x; x++) {
            uint bucket = cell_bucket(x, z, (uint)self.buckets.len);
            for (ushort index = self.buckets[bucket]; index != NULL_GRID_ITEM; index = self.pool[index].next) {
                GridItem* item = &self.pool[index];
                if ((int)item.x != x || (int)item.z != z || holds_id(out_ids[:count], item.id)) continue;
                if (count >= out_ids.len) return count;
                out_ids[count++] = item.id;
            }
        }
    }
    return count;
}

<* Items registered in the cell. *>
fn uint ProximityGrid.item_count_at(&self, int x, int z) {
    uint count;
    uint bucket = cell_bucket(x, z, (uint)self.buckets.len);
    for (ushort index = self.buckets[bucket]; index != NULL_GRID_ITEM; index = self.pool[index].next) {
        if ((int)self.pool[index].x == x && (int)self.pool[index].z == z) count++;
    }
    return count;
}

<*
 Free the pool and buckets.
 @param [&inout] grid : "Left zeroed."
*>
fn void destroy_proximity_grid(ProximityGrid* grid) {
    alloc::free(grid.allocator, grid.pool.ptr);
    alloc::free(grid.allocator, grid.buckets.ptr);
    *grid = {};
}

<*
 Empty grid for pool_size cell entries at cell_size, allocated once.
 @return? c3d::CAPACITY_EXCEEDED
 @require pool_size > 0 && pool_size < ushort::max, cell_size > 0
*>
fn ProximityGrid? create_proximity_grid(Allocator allocator, uint pool_size, float cell_size) {
    ProximityGrid grid = { .allocator = allocator, .cell_size = cell_size, .inverse_cell_size = 1.0f / cell_size };
    defer catch destroy_proximity_grid(&grid);
    GridItem[]? pool = alloc::new_array_try(allocator, GridItem, pool_size);
    if (catch pool) return c3d::CAPACITY_EXCEEDED~;
    grid.pool = pool;
    ushort[]? buckets = alloc::alloc_array_try(allocator, ushort, next_pow2(pool_size));
    if (catch buckets) return c3d::CAPACITY_EXCEEDED~;
    grid.buckets = buckets;
    grid.clear();
    return grid;
}

// Mirrors hashPos2 with wrapping products.
fn uint cell_bucket(int x, int z, uint bucket_count) @local {
    return (((uint)x * CELL_HASH_X) ^ ((uint)z * CELL_HASH_Z)) & (bucket_count - 1);
}

fn bool holds_id(ushort[] ids, ushort id) @local {
    foreach (entry : ids) {
        if (entry == id) return true;
    }
    return false;
}
