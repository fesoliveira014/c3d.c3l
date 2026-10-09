module c3d::describe::value <Type> @private;

import c3d::describe @public;
import c3d::describe::typed @public;
import c3d::describe::enum_access @public;

fn bool? visit(
    Visitor* visitor,
    String name,
    void* raw,
    Metadata metadata,
) {
    Info info = {
        .name = name,
        .kind = describe::@kind(Type),
        .size = Type::size,
        .alignment = Type::alignment,
        .identity = Type::typeid,
        .metadata = metadata,
    };
    $switch describe::@kind(Type):
        $case STRUCT:
            Descriptor* descriptor = &typed::entry{Type}.descriptor;
            if (!descriptor.fields) {
                visitor.missing_type = Type::qname;
                return describe::MISSING_DESCRIPTION~;
            }
            return describe::visit_struct(descriptor, visitor, &info, raw);
        $case ARRAY:
        $case SLICE:
            var $Element = $Typefrom(Type::inner);
            info.element_kind = describe::@kind($Element);
            info.element_size = $Element::size;
            info.element_alignment = $Element::alignment;
            $if Type::kind == ARRAY:
                info.extent = Type::len;
            $endif
            if (!visitor.begin(visitor, &info, raw)!) return false;
            bool changed = false;
            Metadata element_metadata = {
                .range = metadata.range,
                .unit = metadata.unit,
                .has_asset_kind = metadata.has_asset_kind,
                .asset_kind = metadata.asset_kind,
            };
            if (visitor.mode == SCHEMA) {
                (void)visit{$Element}(
                    visitor: visitor,
                    name: "",
                    raw: null,
                    metadata: element_metadata,
                )!;
            } else {
                Type* sequence = raw;
                foreach (&element : *sequence) {
                    changed = visit{$Element}(
                        visitor: visitor,
                        name: "",
                        raw: element,
                        metadata: element_metadata,
                    )! || changed;
                }
            }
            visitor.end(visitor, &info, raw)!;
            return visitor.mode == EDIT && changed;
        $default:
            $if describe::@kind(Type) == ENUM:
                info.enum_names = Type::names;
                info.read_enum = &enum_access::read{Type};
                info.write_enum = &enum_access::write{Type};
            $endif
            $if describe::@kind(Type) == ASSET:
                info.metadata.has_asset_kind = true;
                $if Type::typeid != Id::typeid:
                    info.metadata.asset_kind = describe::@asset_kind(Type);
                    $if $defined(Type.slot_address):
                        Type kind_probe;
                        info.metadata.custom_slot = kind_probe.slot_address();
                    $endif
                $endif
            $endif
            bool changed = visitor.field(visitor, &info, raw)!;
            return visitor.mode == EDIT && changed;
    $endswitch
}
module c3d::describe::enum_access <Type> @private;

import c3d;

fn ulong read(void* raw) {
    return (ulong)(*(Type*)raw).ordinal;
}

fn void? write(void* raw, ulong ordinal) {
    if (ordinal >= Type::values.len) return c3d::INVALID_ARGUMENT~;
    *(Type*)raw = Type::from_ordinal(ordinal);
}
