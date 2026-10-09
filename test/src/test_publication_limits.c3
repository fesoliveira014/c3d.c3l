module c3d::test::publication_limits;

import c3d;
import c3d::asset @public;
import c3d::asset::gltf;
import c3d::asset::loader @public;
import c3d::test::loading_fixtures;
import std::thread;

struct GeneratedSource @local {
    Allocator allocator;
    char[] small;
    char[] large;
    String failed_path;
}

fn char[]? read_generated(void* user, Allocator allocator, String path) @local {
    GeneratedSource* source = user;
    if (path == source.failed_path) return c3d::ASSET_IO_ERROR~;
    char[] source_bytes = path.starts_with("large") ? source.large : source.small;
    char[] bytes = alloc::new_array(allocator, char, (sz)source_bytes.len);
    mem::copy(bytes.ptr, source_bytes.ptr, source_bytes.len);
    return bytes;
}

fn GeneratedSource create_source(Allocator allocator) @local {
    return {
        .allocator = allocator,
        .small = loading_fixtures::small_model_gltf(allocator, 2),
        .large = loading_fixtures::small_model_gltf(allocator, 64),
    };
}

fn void destroy_source(GeneratedSource* source) @local {
    alloc::free(source.allocator, source.small.ptr);
    alloc::free(source.allocator, source.large.ptr);
}

fn AssetStore create_store(Allocator allocator, GeneratedSource* source) @local {
    AssetStoreDesc desc = asset::default_asset_store_desc();
    desc.file_source = { .read = &read_generated, .user = source };
    return asset::create_asset_store(allocator, desc);
}

fn LoadRequest request_for(String path) @local {
    return { .path = path, .format = ModelFormat.GLTF, .options = asset::LOAD_OPTIONS_DEFAULT };
}

fn LoadStatus settle(AsyncLoader* loader, LoadId id) @local {
    LoadStatus status = loader.status(id);
    while (status.phase == LoadPhase.QUEUED || status.phase == LoadPhase.DECODING || status.phase == LoadPhase.CANCELLING) {
        thread::yield();
        status = loader.status(id);
    }
    return status;
}

fn PublicationEstimate estimate_head(AssetStore* assets, AsyncLoader* loader, LoadId id) @local {
    return asset::estimate_model_publication(
        store:     assets,
        prepared:  &loader.state.slots[id.index].prepared,
        model:     loader.state.slots[id.index].request.replace,
        allowance: 0,
        bounded:   false,
    );
}

fn void test_strict_fifo_defers_oversized_head_and_preserves_fresh_allowances() @test {
    GeneratedSource source = create_source(mem);
    defer destroy_source(&source);
    AssetStore assets = create_store(mem, &source);
    defer asset::destroy_asset_store(&assets);
    AsyncLoader loader = loader::create_async_loader(mem, &assets, 2)!!;
    defer loader::destroy_async_loader(&loader);
    LoadId head = loader.request(request_for("large_head.gltf"))!!;
    LoadId follower = loader.request(request_for("small_follower.gltf"))!!;
    assert(settle(&loader, head).phase == LoadPhase.DECODED);
    assert(settle(&loader, follower).phase == LoadPhase.DECODED);
    sz keys = assets.keys.len();
    ulong minimum = loader.state.slots[head.index].prepared.incoming_items;
    PublicationEstimate head_bill = estimate_head(&assets, &loader, head);
    PublicationEstimate follower_bill = estimate_head(&assets, &loader, follower);
    assert(minimum > 1 && head_bill.required_items > follower_bill.required_items);

    PublishReport tiny = loader.publish_within({ .items = minimum - 1 });
    assert(tiny.deferred && !tiny.required_exact && tiny.required_items == minimum);
    assert(tiny.items_used == 0 && tiny.published == 0 && tiny.failed == 0);
    assert(loader.status(head).phase == LoadPhase.DECODED && loader.status(follower).phase == LoadPhase.DECODED);
    assert(assets.keys.len() == keys);

    PublishReport first = loader.publish_within({ .items = head_bill.required_items });
    assert(first.published == 1 && first.failed == 0 && first.items_used == head_bill.required_items);
    assert(first.deferred && first.required_items > 0 && !first.required_exact);
    assert(loader.status(head).phase == LoadPhase.PUBLISHED && loader.status(follower).phase == LoadPhase.DECODED);
    PublishReport next = loader.publish_within({ .items = follower_bill.required_items });
    assert(next.published == 1 && next.failed == 0 && next.items_used == follower_bill.required_items);
    assert(!next.deferred && next.required_items == 0 && !next.required_exact);
    assert(loader.publish() == 0);
    LoaderCounters counters = loader.counters();
    assert(counters.published == 2 && counters.publications == 2 && counters.decoded == 0);
    assert(counters.publication_items == first.items_used + next.items_used);
}

fn void test_deferred_estimation_is_charged_and_repeated_against_current_store() @test {
    GeneratedSource source = create_source(mem);
    defer destroy_source(&source);
    AssetStore assets = create_store(mem, &source);
    defer asset::destroy_asset_store(&assets);
    AsyncLoader loader = loader::create_async_loader(mem, &assets, 1)!!;
    defer loader::destroy_async_loader(&loader);
    LoadId id = loader.request(request_for("small.gltf"))!!;
    assert(settle(&loader, id).phase == LoadPhase.DECODED);
    PublicationEstimate bill = estimate_head(&assets, &loader, id);
    ulong minimum = loader.state.slots[id.index].prepared.incoming_items;
    assert(bill.required_items > minimum && bill.items_used > 0);
    sz keys = assets.keys.len();

    PublishReport deferred = loader.publish_within({ .items = bill.required_items - 1 });
    assert(deferred.deferred && deferred.required_exact && deferred.required_items == bill.required_items);
    assert(deferred.items_used == bill.items_used && deferred.published == 0 && deferred.failed == 0);
    assert(assets.keys.len() == keys && loader.status(id).phase == LoadPhase.DECODED);
    ModelId collision = gltf::load_model(&assets, "small.gltf")!!;
    bill = estimate_head(&assets, &loader, id);
    PublishReport committed = loader.publish_within({ .items = bill.required_items });
    assert(committed.failed == 1 && committed.published == 0 && committed.items_used == bill.required_items);
    assert(!committed.deferred && committed.required_items == 0);
    assert(loader.status(id).phase == LoadPhase.FAILED && loader.status(id).failure == c3d::INVALID_ARGUMENT);
    assert(c3d::same_id(assets.find_model("small.gltf")!!, collision));
    LoaderCounters counters = loader.counters();
    assert(counters.commit_failures == 1 && counters.decode_failures == 0);
    assert(counters.publication_items == deferred.items_used + committed.items_used);
}

fn void test_failed_commit_consumes_items_before_the_next_fifo_request() @test {
    GeneratedSource source = create_source(mem);
    defer destroy_source(&source);
    foreach (admit_follower : (bool[2]){ false, true }) {
        TrackingAllocator tracker;
        tracker.init(mem);
        defer tracker.free();
        AssetStore assets = create_store(&tracker, &source);
        AsyncLoader loader = loader::create_async_loader(&tracker, &assets, 2)!!;
        LoadId failed = loader.request(request_for("collision.gltf"))!!;
        LoadId success = loader.request(request_for("success.gltf"))!!;
        assert(settle(&loader, failed).phase == LoadPhase.DECODED);
        assert(settle(&loader, success).phase == LoadPhase.DECODED);
        gltf::load_model(&assets, "collision.gltf")!!;
        PublicationEstimate failed_bill = estimate_head(&assets, &loader, failed);
        PublicationEstimate success_bill = estimate_head(&assets, &loader, success);
        ulong allowance = failed_bill.required_items + (admit_follower ? success_bill.required_items : 0);

        PublishReport report = loader.publish_within({ .items = allowance });
        assert(report.failed == 1 && report.published == (uint)admit_follower && report.items_used == allowance);
        if (admit_follower) {
            assert(!report.deferred && report.required_items == 0);
            assert(loader.status(success).phase == LoadPhase.PUBLISHED);
        } else {
            assert(report.deferred && !report.required_exact);
            assert(loader.status(success).phase == LoadPhase.DECODED);
        }
        assert(loader.publish() == (admit_follower ? 0 : 1));
        assert(loader.status(success).phase == LoadPhase.PUBLISHED && loader.publish() == 0);
        LoaderCounters counters = loader.counters();
        assert(counters.commit_failures == 1 && counters.publications == 1 && counters.decode_failures == 0);
        assert(counters.publication_items == failed_bill.required_items + success_bill.required_items);
        loader::destroy_async_loader(&loader);
        asset::destroy_asset_store(&assets);
        assert(tracker.allocated() == 0);
    }
}

fn void test_reports_exclude_earlier_decode_failure_and_cancellation() @test {
    GeneratedSource source = create_source(mem);
    source.failed_path = "failed.gltf";
    defer destroy_source(&source);
    AssetStore assets = create_store(mem, &source);
    defer asset::destroy_asset_store(&assets);
    AsyncLoader loader = loader::create_async_loader(mem, &assets, 3)!!;
    defer loader::destroy_async_loader(&loader);
    LoadId failed = loader.request(request_for("failed.gltf"))!!;
    LoadId cancelled = loader.request(request_for("cancelled.gltf"))!!;
    LoadId published = loader.request(request_for("published.gltf"))!!;
    assert(settle(&loader, failed).phase == LoadPhase.FAILED);
    assert(settle(&loader, cancelled).phase == LoadPhase.DECODED);
    assert(settle(&loader, published).phase == LoadPhase.DECODED);
    loader.cancel(cancelled)!!;
    PublicationEstimate bill = estimate_head(&assets, &loader, published);

    PublishReport report = loader.publish_within({});
    assert(report.published == 1 && report.failed == 0 && report.items_used == bill.required_items);
    assert(!report.deferred && report.required_items == 0 && !report.required_exact);
    LoaderCounters counters = loader.counters();
    uint occupied = counters.queued + counters.decoding + counters.decoded + counters.cancelling
        + counters.published + counters.failed + counters.cancelled;
    assert(occupied == 3 && counters.published == 1 && counters.failed == 1 && counters.cancelled == 1);
    assert(counters.publications == 1 && counters.decode_failures == 1 && counters.commit_failures == 0 && counters.cancellations == 1);
    assert(counters.publication_items == bill.required_items);
    PublishReport empty = loader.publish_within({});
    assert(empty.published == 0 && empty.failed == 0 && empty.items_used == 0 && !empty.deferred && empty.required_items == 0);
    LoaderCounters repeated = loader.counters();
    assert(repeated.publications == counters.publications && repeated.decode_failures == counters.decode_failures);
    assert(repeated.commit_failures == counters.commit_failures && repeated.cancellations == counters.cancellations);
    assert(repeated.publication_items == counters.publication_items && repeated.decode_ns == counters.decode_ns);
    assert(repeated.publication_ns >= counters.publication_ns);
}

fn void test_saturated_incoming_requirement_cannot_be_admitted_by_finite_limit() @test {
    GeneratedSource source = create_source(mem);
    defer destroy_source(&source);
    AssetStore assets = create_store(mem, &source);
    defer asset::destroy_asset_store(&assets);
    AsyncLoader loader = loader::create_async_loader(mem, &assets, 1)!!;
    defer loader::destroy_async_loader(&loader);
    LoadId id = loader.request(request_for("saturated.gltf"))!!;
    assert(settle(&loader, id).phase == LoadPhase.DECODED);
    ulong actual = loader.state.slots[id.index].prepared.incoming_items;
    loader.state.slots[id.index].prepared.incoming_items = ulong::max;
    PublishReport report = loader.publish_within({ .items = ulong::max });
    assert(report.deferred && !report.required_exact && report.required_items == ulong::max);
    assert(report.published == 0 && report.failed == 0);
    assert(loader.status(id).phase == LoadPhase.DECODED);
    loader.state.slots[id.index].prepared.incoming_items = actual;
    assert(loader.publish() == 1);
}
