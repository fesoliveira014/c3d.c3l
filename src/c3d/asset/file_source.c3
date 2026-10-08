module c3d::asset;

import c3d;
import std::io::file;

const usz UNC_SEGMENT_COUNT @private = 2; // server and share
const usz DRIVE_PREFIX_LENGTH @private = 3; // letter, colon and slash

<*
 Read a whole file into memory from the allocator.
 Called concurrently from the loader thread and the owner thread; must not call into the store.
 @param [in] user : "Passed unchanged."
 @param path : "Normalized by normalize_path; borrowed for the call."
 @return? c3d::ASSET_IO_ERROR
*>
alias ReadFileFn = fn char[]? (void* user, Allocator allocator, String path);

<*
 Where importers and the loader read files from; a null read selects the file system.
 Its read function is called concurrently from the loader thread and the owner thread.
*>
struct FileSource {
    ReadFileFn read;
    void*      user;
}

<*
 Read a file from the file system; the default file source.
 @param [in] user : "Ignored."
 @return? c3d::ASSET_IO_ERROR
*>
fn char[]? read_file_system(void* user, Allocator allocator, String path) {
    char[]? bytes = file::load(allocator, path);
    if (catch bytes) return c3d::ASSET_IO_ERROR~;
    return bytes;
}

<*
 Canonical form of a path handed to a file source.
 @return "Allocated with the allocator."
*>
fn String normalize_path(Allocator allocator, String path) {
    String text = path.treplace("\\", "/");
    usz prefix_length = absolute_prefix_length(text);
    String prefix = text[:prefix_length];
    String rest = text[prefix_length..];

    String[] kept = alloc::new_array(tmem, String, (sz)((rest.len + 1) / 2 + 1));
    usz count;
    usz start;
    for (usz index = 0; index <= rest.len; index++) {
        if (index < rest.len && rest[index] != '/') continue;
        String segment = rest[start:index - start];
        start = index + 1;
        if (!segment.len || segment == ".") continue;
        if (segment == ".." && count > 0 && kept[count - 1] != "..") {
            count--;
            continue;
        }
        kept[count++] = segment;
    }

    bool needs_separator = prefix.len > 0 && prefix[^1] != '/';
    usz length = prefix.len;
    foreach (sz index, segment : kept[:count]) {
        length += segment.len;
        if (index > 0 || needs_separator) length++;
    }
    if (!length) return ".".copy(allocator);

    char[] joined = alloc::new_array(allocator, char, (sz)length);
    usz cursor;
    mem::copy(joined.ptr, prefix.ptr, prefix.len);
    cursor += prefix.len;
    foreach (sz index, segment : kept[:count]) {
        if (index > 0 || needs_separator) joined[cursor++] = '/';
        mem::copy(joined.ptr + cursor, segment.ptr, segment.len);
        cursor += segment.len;
    }
    return (String)joined;
}

fn usz absolute_prefix_length(String text) @private {
    if (text.len > UNC_SEGMENT_COUNT && text[0] == '/' && text[1] == '/' && text[2] != '/') {
        usz end = 2;
        usz position = 2;
        for (usz segment = 0; segment < UNC_SEGMENT_COUNT && position < text.len; segment++) {
            while (position < text.len && text[position] != '/') position++;
            end = position;
            if (position < text.len) position++;
        }
        return end;
    }
    if (text.len >= DRIVE_PREFIX_LENGTH && text[0].is_alpha() && text[1] == ':' && text[2] == '/') {
        return DRIVE_PREFIX_LENGTH;
    }
    if (text.len > 0 && text[0] == '/') return 1;
    return 0;
}

<*
 Read a file through the store's file source.
 @return? c3d::ASSET_IO_ERROR
*>
fn char[]? AssetStore.read_file(&self, Allocator allocator, String path) {
    return self.file_source.read_path(allocator, path);
}

<*
 Read a file through a source, or the file system when its read is null.
 @return? c3d::ASSET_IO_ERROR
*>
fn char[]? FileSource.read_path(&self, Allocator allocator, String path) {
    String normalized = normalize_path(allocator, path);
    defer alloc::free(allocator, normalized.ptr);
    ReadFileFn read = self.read ?: &read_file_system;
    char[]? bytes = read(self.user, allocator, normalized);
    if (catch bytes) return c3d::ASSET_IO_ERROR~;
    return bytes;
}
