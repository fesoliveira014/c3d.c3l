module c3d::ui;

import c3d;
import c3d::asset;
import c3d::material;
import c3d::platform;
import c3d::pool;
import c3d::render;
import clay;
import std::math;

<*
 Id of a loaded UI document.
*>
typedef UiDocumentId = Id;

<*
 Produces one binding's value for the scope of the element that reads it.
*>
alias UiGetterFn = fn UiValue (void* user, UiScope* scope);

<*
 Handles one action fired by input routing.
*>
alias UiActionFn = fn void (void* user, UiScope* scope, UiEvent* event);

<*
 Item a list binding's scope selects.
*>
alias UiItemFn = fn void* (void* user, UiScope* scope);

alias UiDocumentPool @private = Pool{UiDocument, UiDocumentId};

<*
 List nesting a binding scope records.
*>
const uint UI_SCOPE_DEPTH = 4; // a list in a list in a list in a list; inventories in containers use two

<*
 Fonts one style may list for fallback.
*>
const uint UI_FONT_FALLBACKS = 4; // Latin, Greek and Cyrillic, CJK, and one symbol font

<*
 UiEvent.cell of a drop outside any grid.
*>
const uint UI_NO_CELL = uint::max;

<*
 Layout units one wheel notch scrolls, before Clay's scaling.
*>
const float UI_WHEEL_STEP = 4; // Clay scales scroll deltas by 10: 40 layout units, about two lines of 16-unit text

<*
 Pointer travel in layout units that turns a press on a grid item into a drag.
*>
const float UI_DRAG_THRESHOLD = 4;

const uint UI_NONE @private = uint::max;
const short UI_Z_BAND @private = 4;              // per visible document: its root, its grid items, spare
const short UI_Z_TOOLTIP @private = short::max - 1;
const short UI_Z_GHOST @private = short::max;
const usz UI_ERROR_PATH_BYTES @private = 256;
const uint UI_ID_PROBE @private = 0x9E37_79B9;   // golden-ratio step; odd, so probing visits every 32-bit id

<*
 Kind of value a binding getter produces.
*>
enum UiValueKind {
    BOOL,
    INT,
    FLOAT,
    TEXT,
    IMAGE,
    LIST,
}

<*
 Kind of input that fired an action.
*>
enum UiEventKind {
    CLICK,
    SECONDARY_CLICK,
    SUBMIT,
    CHANGE,
    DROP,
}

enum UiElementKind @private {
    PANEL,
    LABEL,
    IMAGE,
    BUTTON,
    BAR,
    LIST,
    SCROLL,
    TEXT_FIELD,
    TOOLTIP,
    GRID,
}

enum UiAnchor @private {
    TOP_LEFT,
    TOP,
    TOP_RIGHT,
    LEFT,
    CENTER,
    RIGHT,
    BOTTOM_LEFT,
    BOTTOM,
    BOTTOM_RIGHT,
}

bitstruct UiStateFlags : char @private {
    bool focused  : 0;
    bool hovered  : 1;
    bool pressed  : 2;
    bool disabled : 3;
}

<*
 Value a getter returns for one element in one frame.
*>
struct UiValue {
    UiValueKind kind;
    union {
        bool       boolean;
        long       integer;
        double     number;
        String     text;   // borrowed until the getter's next call
        TextureRef image;
        uint       count;  // items of a LIST binding
    }
}

<*
 Item indices of the enclosing lists, outermost first.
*>
struct UiScope {
    uint[UI_SCOPE_DEPTH] indices;
    uint                 depth;
}

<*
 Details of the input that fired an action.
*>
struct UiEvent {
    UiEventKind kind;
    UiScope     source;      // dragged item for DROP
    String      source_list; // list binding of the dragged item for DROP
    uint        cell;        // target grid cell for DROP; UI_NO_CELL outside a grid
    String      text;        // field text for SUBMIT and CHANGE; borrowed during the handler
}

<*
 Capacities of one UI.
*>
struct UiDesc {
    uint max_documents;
    uint max_styles;       // styles of one set, across its sheets
    uint max_font_sets;    // distinct font lists, never released
    uint max_bindings;
    uint max_actions;
    uint max_item_sources; // @bind_items registrations
    uint name_bytes;       // binding and action names
    uint max_instances;    // elements laid out per frame
    uint text_bytes;       // expanded text per frame
    uint cache_lines;      // placement cache entries
    uint cache_glyphs;     // placements the cache holds
    uint field_bytes;      // the focused field's edit buffer
}

<*
 Counters of the last update and draw.
*>
struct UiStats {
    uint instances;
    uint getter_calls;
    uint text_bytes;
    uint placement_hits;
    uint placement_misses;
    uint placement_clears;
}

struct UiClayError @private {
    bool            raised;
    clay::ErrorType type;
}

struct UiBinding @private {
    String      name;
    UiValueKind kind;
    UiGetterFn  getter;
    void*       user;
    uint        list;  // owning LIST binding, UI_NONE for a root binding
    uint        level; // scope depth the getter receives
}

struct UiAction @private {
    String     name;
    UiActionFn handler;
    void*      user;
}

struct UiFontSet @private {
    FontId[UI_FONT_FALLBACKS] fonts;
    uint                      count;
}

struct UiElementKey @private {
    UiDocumentId document; // zero generation: no element
    uint         element;
    UiScope      scope;
}

struct UiInstance @private {
    UiElementKey key;
    UiDocument*  document;
    UiElement*   element;
    uint         clay_id;
    UiProperties properties;
    UiStateFlags state;
    uint         grid;        // instance of the owning grid for a grid item
    uint         list;        // LIST binding a grid item came from
    uint         span_width;
    uint         span_height;
    String       text;        // expanded text of a label or field
    TextureRef   image;
    float        value;       // bar fill fraction
    bool         interactive;
    bool         hit;         // tooltips and the drag ghost take no hits
    bool         enabled;
}

struct UiInstanceSlot @private {
    uint clay_id; // zero: empty
    uint instance;
}

struct UiDrag @private {
    bool         candidate;
    bool         active;
    UiElementKey source;      // template root of the dragged item
    uint         list;        // LIST binding of the dragged item
    uint         span_width;
    uint         span_height;
    Vec2         size;        // layout units of the dragged item
    Vec2         origin;      // pointer at the press
    Vec2         grab;        // pointer minus the item's top left at the press
    UiElementKey target;      // drop target under the pointer, if any
    uint         cell;
}

<*
 Documents, styles, bindings and layout state of one UI.
*>
struct Ui {
    Allocator    allocator;
    AssetStore*  assets;
    UiDesc       desc;
    char[]       storage;             // one allocation behind every fixed table
    bool         wants_text_input;
    UiStats      stats;
    UiDocumentId load_error_document; // zero unless load_styles failed on a document

    clay::Context*            context;
    char[]                    clay_memory;
    UiClayError*              clay_error;   // in storage: a stable address for Clay's error callback
    clay::RenderCommandArray  commands;     // of the last successful update
    bool                      frame_ready;
    float                     scale;        // output pixels per layout unit, of the last update
    UiDocumentPool            documents;
    UiDocument*[]             document_stack; // visible documents of one update, bottom first
    uint                      next_order;
    UiStyleSet                styles;
    UiFontSet[]               font_sets;
    uint                      font_set_count;
    UiBinding[]               bindings;
    uint                      binding_count;
    UiAction[]                actions;
    uint                      action_count;
    UiItemSource[]            item_sources;
    uint                      item_source_count;
    char[]                    names;
    uint                      names_used;
    UiInstance[]              instances;
    uint                      instance_count;
    UiInstanceSlot[]          instance_lookup;
    char[]                    text;
    uint                      text_used;
    UiPlacementCache          cache;
    char[]                    field;
    uint                      field_length;
    uint                      caret;        // byte offset in field
    UiElementKey              hover;
    UiElementKey              press;
    MouseButton               press_button;
    UiElementKey              focus;
    UiDrag                    drag;
    Vec2                      pointer;      // layout units, of the last route
    char[UI_ERROR_PATH_BYTES] error_path;
    uint                      error_path_length;
}

<*
 Default UI capacities.
*>
fn UiDesc default_ui_desc() {
    return {
        .max_documents    = 16,
        .max_styles       = 256,
        .max_font_sets    = 64,
        .max_bindings     = 1024,
        .max_actions      = 256,
        .max_item_sources = 64,
        .name_bytes       = 32 * 1024,
        .max_instances    = 4096,
        .text_bytes       = 64 * 1024,
        .cache_lines      = 2048,
        .cache_glyphs     = 32 * 1024,
        .field_bytes      = 256,
    };
}

<*
 Create a UI that resolves fonts and images in the store.
 Leaves its Clay context current.
 @param [&inout] assets : "Outlives the UI; fonts gain outlines while drawing."
 @return? c3d::INVALID_ARGUMENT
*>
fn Ui? create_ui(Allocator allocator, AssetStore* assets, UiDesc desc) {
    if (!desc.max_documents || !desc.max_styles || !desc.max_font_sets || !desc.max_bindings) {
        return c3d::INVALID_ARGUMENT~;
    }
    if (!desc.max_actions || !desc.max_item_sources || !desc.name_bytes || !desc.max_instances) {
        return c3d::INVALID_ARGUMENT~;
    }
    if (!desc.text_bytes || !desc.cache_lines || !desc.cache_glyphs || !desc.field_bytes) {
        return c3d::INVALID_ARGUMENT~;
    }

    usz offset;
    usz stack_at = @reserve(&offset, UiDocument*, desc.max_documents);
    usz font_sets_at = @reserve(&offset, UiFontSet, desc.max_font_sets);
    usz bindings_at = @reserve(&offset, UiBinding, desc.max_bindings);
    usz actions_at = @reserve(&offset, UiAction, desc.max_actions);
    usz sources_at = @reserve(&offset, UiItemSource, desc.max_item_sources);
    usz instances_at = @reserve(&offset, UiInstance, desc.max_instances);
    usz lookup_at = @reserve(&offset, UiInstanceSlot, 2 * (usz)desc.max_instances);
    usz lines_at = @reserve(&offset, UiPlacementLine, desc.cache_lines);
    usz line_slots_at = @reserve(&offset, uint, 2 * (usz)desc.cache_lines);
    usz segment_count = (usz)UI_CACHE_SEGMENTS_PER_LINE * desc.cache_lines;
    usz segments_at = @reserve(&offset, UiPlacementSegment, segment_count);
    usz glyphs_at = @reserve(&offset, GlyphPlacement, desc.cache_glyphs);
    usz error_at = @reserve(&offset, UiClayError, 1);
    usz names_at = @reserve(&offset, char, desc.name_bytes);
    usz text_at = @reserve(&offset, char, desc.text_bytes);
    usz cache_text_at = @reserve(&offset, char, (usz)UI_CACHE_BYTES_PER_LINE * desc.cache_lines);
    usz field_at = @reserve(&offset, char, desc.field_bytes);

    // Allocated as Vec4 so every allocator aligns the block for the Vec4 members of the carved tables.
    Vec4[] block = alloc::new_array(allocator, Vec4, (sz)((offset + Vec4::size - 1) / Vec4::size));
    char[] storage = ((char*)block.ptr)[:block.len * Vec4::size];

    clay::set_current_context(null);
    clay::set_max_element_count((int)(2 * (usz)desc.max_instances));
    uint clay_bytes = clay::min_memory_size();
    char[] clay_memory = alloc::new_array(allocator, char, clay_bytes);
    UiClayError* clay_error = (UiClayError*)(storage.ptr + error_at);
    clay::Context* context = clay::initialize(
        clay::create_arena(clay_bytes, clay_memory.ptr),
        { 1, 1 },
        { .error_handler_function = &on_clay_error, .user_data = clay_error },
    );

    return {
        .allocator       = allocator,
        .assets          = assets,
        .desc            = desc,
        .storage         = storage,
        .context         = context,
        .clay_memory     = clay_memory,
        .clay_error      = clay_error,
        .scale           = 1,
        .documents       = pool::create_pool{UiDocument, UiDocumentId}(allocator, desc.max_documents),
        .document_stack  = @carve(storage, stack_at, UiDocument*, desc.max_documents),
        .font_sets       = @carve(storage, font_sets_at, UiFontSet, desc.max_font_sets),
        .bindings        = @carve(storage, bindings_at, UiBinding, desc.max_bindings),
        .actions         = @carve(storage, actions_at, UiAction, desc.max_actions),
        .item_sources    = @carve(storage, sources_at, UiItemSource, desc.max_item_sources),
        .names           = @carve(storage, names_at, char, desc.name_bytes),
        .instances       = @carve(storage, instances_at, UiInstance, desc.max_instances),
        .instance_lookup = @carve(storage, lookup_at, UiInstanceSlot, 2 * (usz)desc.max_instances),
        .text            = @carve(storage, text_at, char, desc.text_bytes),
        .field           = @carve(storage, field_at, char, desc.field_bytes),
        .cache           = {
            .lines    = @carve(storage, lines_at, UiPlacementLine, desc.cache_lines),
            .slots    = @carve(storage, line_slots_at, uint, 2 * (usz)desc.cache_lines),
            .segments = @carve(storage, segments_at, UiPlacementSegment, segment_count),
            .glyphs   = @carve(storage, glyphs_at, GlyphPlacement, desc.cache_glyphs),
            .bytes    = @carve(storage, cache_text_at, char, (usz)UI_CACHE_BYTES_PER_LINE * desc.cache_lines),
        },
    };
}

<*
 Release every document, style and binding.
 @param [&inout] ui : "Left zeroed."
*>
fn void destroy_ui(Ui* ui) {
    if (clay::get_current_context() == ui.context) clay::set_current_context(null);
    foreach (&document : ui.documents.items) {
        if (document.live) free_document(ui, document);
    }
    pool::destroy_pool{UiDocument, UiDocumentId}(&ui.documents);
    free_style_set(ui, &ui.styles);
    alloc::free(ui.allocator, ui.clay_memory.ptr);
    alloc::free(ui.allocator, ui.storage.ptr);
    *ui = {};
}

fn void invalidate_frame(Ui* ui) @private {
    ui.frame_ready = false;
    ui.instance_count = 0;
    ui.hover = {};
    ui.press = {};
    ui.drag = {};
}

fn UiElement[] ui_elements(Ui* ui, UiDocumentId document) @private => ui.documents.get(document).elements;

fn bool key_valid(UiElementKey* key) @private => key.document.generation != 0;

fn bool same_key(UiElementKey* first, UiElementKey* second) @private {
    if (!c3d::same_id(first.document, second.document) || first.element != second.element) return false;
    if (first.scope.depth != second.scope.depth) return false;
    for (uint level = 0; level < first.scope.depth; level++) {
        if (first.scope.indices[level] != second.scope.indices[level]) return false;
    }
    return true;
}

fn void on_clay_error(clay::ErrorData error) @private {
    UiClayError* record = error.user_data;
    if (record.raised) return;
    record.raised = true;
    record.type = error.error_type;
}

macro usz @reserve(usz* offset, $Type, usz count) @private {
    usz start = (*offset + $Type::alignment - 1) / $Type::alignment * $Type::alignment;
    *offset = start + $Type::size * count;
    return start;
}

macro @carve(char[] storage, usz offset, $Type, usz count) @private {
    return (($Type*)(storage.ptr + offset))[:count];
}
