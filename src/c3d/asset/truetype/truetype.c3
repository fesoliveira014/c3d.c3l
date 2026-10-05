module c3d::asset::truetype;

const char VERTEX_MOVE @private = 1;
const char VERTEX_LINE @private = 2;
const char VERTEX_CURVE @private = 3;
const char VERTEX_CUBIC @private = 4;

// Mirrors stbtt_fontinfo of stb_truetype v1.26; pinned below.
struct FontInfo @private {
    void*  user_data;
    char*  data;
    int    font_start;
    int    glyph_count;
    int    loca;
    int    head;
    int    glyf;
    int    hhea;
    int    hmtx;
    int    kern;
    int    gpos;
    int    svg;
    int    index_map;
    int    index_to_loc_format;
    Buffer cff;
    Buffer charstrings;
    Buffer global_subrs;
    Buffer subrs;
    Buffer font_dicts;
    Buffer fd_select;
}

struct Buffer @private {
    char* data;
    int   cursor;
    int   size;
}

struct Vertex @private {
    short x;
    short y;
    short control_x;
    short control_y;
    short control1_x;
    short control1_y;
    char  type;
    char  padding;
}

$assert(FontInfo::size == 160);
$assert($reflect(FontInfo.glyph_count).offset == 20);
$assert($reflect(FontInfo.cff).offset == 64);
$assert(Vertex::size == 14);

extern fn int get_number_of_fonts(char* data) @cname("stbtt_GetNumberOfFonts") @private;
extern fn int get_font_offset_for_index(char* data, int index) @cname("stbtt_GetFontOffsetForIndex") @private;
extern fn int init_font(FontInfo* info, char* data, int offset) @cname("stbtt_InitFont") @private;
extern fn int find_glyph_index(FontInfo* info, int code_point) @cname("stbtt_FindGlyphIndex") @private;
extern fn float scale_for_mapping_em_to_pixels(FontInfo* info, float pixels)
    @cname("stbtt_ScaleForMappingEmToPixels") @private;

extern fn void get_font_v_metrics(
    FontInfo* info,
    int* ascent,
    int* descent,
    int* line_gap,
) @cname("stbtt_GetFontVMetrics") @private;

extern fn void get_glyph_h_metrics(
    FontInfo* info,
    int glyph,
    int* advance_width,
    int* left_side_bearing,
) @cname("stbtt_GetGlyphHMetrics") @private;

extern fn int get_glyph_kern_advance(FontInfo* info, int first, int second)
    @cname("stbtt_GetGlyphKernAdvance") @private;
extern fn int is_glyph_empty(FontInfo* info, int glyph) @cname("stbtt_IsGlyphEmpty") @private;
extern fn int get_glyph_shape(FontInfo* info, int glyph, Vertex** vertices) @cname("stbtt_GetGlyphShape") @private;
extern fn void free_shape(FontInfo* info, Vertex* vertices) @cname("stbtt_FreeShape") @private;

extern fn void get_glyph_bitmap_box_subpixel(
    FontInfo* info,
    int glyph,
    float scale_x,
    float scale_y,
    float shift_x,
    float shift_y,
    int* min_x,
    int* min_y,
    int* max_x,
    int* max_y,
) @cname("stbtt_GetGlyphBitmapBoxSubpixel") @private;

extern fn void make_glyph_bitmap_subpixel(
    FontInfo* info,
    char* output,
    int width,
    int height,
    int stride,
    float scale_x,
    float scale_y,
    float shift_x,
    float shift_y,
    int glyph,
) @cname("stbtt_MakeGlyphBitmapSubpixel") @private;
