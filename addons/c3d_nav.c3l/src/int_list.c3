module c3d::nav;

import std::math;
import c3d;

struct IntList @private {
    Allocator allocator;
    int[]     items;    // capacity
    sz        count;
}

fn void? IntList.push(&self, int value) {
    if (self.count == self.items.len) grow_int_list(self, self.count + 1)!;
    self.items[self.count++] = value;
}

fn int IntList.pop(&self) => self.items[--self.count];

fn void? IntList.resize(&self, sz count) {
    if (count > self.items.len) grow_int_list(self, count)!;
    if (count > self.count) self.items[self.count:count - self.count] = 0;
    self.count = count;
}

fn void IntList.clear(&self) => self.count = 0;

fn int[] IntList.view(&self) => self.items[:self.count];

fn IntList? create_int_list(Allocator allocator, sz capacity) @private {
    int[]? items = alloc::alloc_array_try(allocator, int, capacity);
    if (catch items) return c3d::CAPACITY_EXCEEDED~;
    return { .allocator = allocator, .items = items };
}

fn void destroy_int_list(IntList* list) @private {
    alloc::free(list.allocator, list.items.ptr);
    *list = {};
}

fn void? grow_int_list(IntList* list, sz required) @local {
    sz capacity = math::max(list.items.len, (sz)1);
    while (capacity < required) capacity *= 2;
    int[]? grown = alloc::realloc_array_try(list.allocator, list.items.ptr, int, capacity);
    if (catch grown) return c3d::CAPACITY_EXCEEDED~;
    list.items = grown;
}
