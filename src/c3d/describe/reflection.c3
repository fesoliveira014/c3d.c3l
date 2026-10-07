module c3d::describe;

import c3d;

macro void @check_field(
    $Type,
    $name,
    bool $asset = false,
    AssetKind $asset_kind = CUSTOM,
) @private {
    var $kind = @kind($Type, $name);
    $if $Type::typeid == Id::typeid:
        $assert $asset : "Untyped asset field requires an asset tag: " +++ $name;
    $endif
    $if $kind == ARRAY || $kind == SLICE:
        @check_field(
            $Type: $Typefrom($Type::inner),
            $name: $name +++ "[]",
            $asset: $asset,
            $asset_kind: $asset_kind,
        );
    $else
        $if $asset:
            $assert $kind == ASSET : "Asset tag requires an asset reference: " +++ $name;
            $if $Type::typeid != Id::typeid:
                $assert $asset_kind == @asset_kind($Type) : "Asset kind contradicts typed field: " +++ $name;
            $endif
        $endif
    $endif
}

macro void @check_recursive($Type, $parents, $name) @private {
    $switch $Type::kind:
        $case STRUCT:
            $foreach $parent : $parents:
                $if $Type::typeid == $parent:
                    $error "Recursive described field: " +++ $name;
                $endif
            $endforeach
            $foreach $member : $Type::members:
                $if !@transient($member):
                    @check_recursive(
                        $Type: $Typefrom($member.type),
                        $parents: $parents +++ {$Type::typeid},
                        $name: $name +++ "." +++ $member.name,
                    );
                $endif
            $endforeach
        $case ARRAY:
        $case SLICE:
            @check_recursive($Typefrom($Type::inner), $parents, $name +++ "[]");
        $default:
    $endswitch
}
