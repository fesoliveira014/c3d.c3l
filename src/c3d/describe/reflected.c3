module c3d::describe::reflected <Type> @private;

import c3d::describe @public;

fn bool? fields(Visitor* visitor, void* raw) {
    describe::@check_recursive(Type, {}, Type::qname);
    Type* value = raw;
    bool changed = false;
    $foreach $member : Type::members:
        $if !describe::@transient($member):
            $if $member.has_tag("asset"):
                describe::@check_field(
                    $Type: $Typefrom($member.type),
                    $name: Type::qname +++ "." +++ $member.name,
                    $asset: true,
                    $asset_kind: $member.get_tag("asset"),
                );
            $else
                describe::@check_field($Typefrom($member.type), Type::qname +++ "." +++ $member.name);
            $endif
            {
                Metadata metadata = {};
                $if $member.has_tag("display"):
                    metadata.display_name = $member.get_tag("display");
                $endif
                $if $member.has_tag("range"):
                    describe::@check_range(
                        $Type: $Typefrom($member.type),
                        $name: Type::qname +++ "." +++ $member.name,
                        $minimum: $member.get_tag("range")[0],
                        $maximum: $member.get_tag("range")[1],
                    );
                    metadata.range = {
                        .enabled = true,
                        .min = $member.get_tag("range")[0],
                        .max = $member.get_tag("range")[1],
                    };
                $endif
                $if $member.has_tag("unit"):
                    metadata.unit = $member.get_tag("unit");
                $endif
                $if $member.has_tag("asset"):
                    metadata.has_asset_kind = true;
                    metadata.asset_kind = $member.get_tag("asset");
                $endif
                changed = describe::@field(
                    visitor: visitor,
                    name: $member.name,
                    #field: value.$member,
                    metadata: metadata,
                )! || changed;
            }
        $endif
    $endforeach
    return changed;
}
