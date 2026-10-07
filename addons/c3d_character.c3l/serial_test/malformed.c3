module c3d_character_serial_test;

import c3d::serial @public;

fn char[] invalid_character_height(char[] bytes, bool text_mode) @private {
    uint found;
    if (text_mode) {
        String text = (String)bytes;
        SerialDiagnostic diagnostic = serial::create_serial_diagnostic(tmem);
        defer serial::destroy_serial_diagnostic(&diagnostic);
        TextDocument document = serial::parse_text(
            allocator: tmem,
            source: text,
            limits: serial::TEXT_LIMITS_DEFAULT,
            diagnostic: &diagnostic,
        )!!;
        defer serial::destroy_text_document(&document);
        for (sz index = (sz)document.values.len - 1; index >= 0; index--) {
            TextValue value = document.values[index];
            if (value.name != "half_height") continue;
            String replacement = "0";
            char[] changed = alloc::new_array(tmem, char, text.len - value.length + replacement.len);
            changed[:value.offset] = ((char[])text[:value.offset])[..];
            changed[value.offset:replacement.len] = ((char[])replacement)[..];
            changed[value.offset + replacement.len..] = ((char[])text[value.offset + value.length..])[..];
            text = (String)changed;
            found++;
        }
        assert(found == 1);
        return (char[])text;
    }
    char[] changed = alloc::new_array(tmem, char, bytes.len);
    changed[..] = bytes[..];
    char[float::size] expected;
    Writer reference = serial::writer_over(&expected);
    reference.write_float(0.7f);
    for (usz index = 0; index + float::size <= changed.len; index++) {
        if (changed[index:float::size] != expected[..]) continue;
        Writer writer = serial::writer_over(changed[index:float::size]);
        writer.write_float(0);
        found++;
    }
    assert(found == 1);
    return changed;
}
