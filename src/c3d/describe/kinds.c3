module c3d::describe;

import std::math;
import c3d::ecs;

macro Kind @kind($Type, $name = "") @private {
    $switch $Type::typeid:
        $case bool::typeid: return BOOL;
        $case int::typeid: return INT;
        $case uint::typeid: return UINT;
        $case long::typeid: return LONG;
        $case ulong::typeid: return ULONG;
        $case float::typeid: return FLOAT;
        $case double::typeid: return DOUBLE;
        $case Vec2::typeid: return VEC2;
        $case Vec3::typeid: return VEC3;
        $case Vec4::typeid: return VEC4;
        $case Quat::typeid: return QUAT;
        $case String::typeid: return STRING;
        $case Entity::typeid: return ENTITY;
        $case Id::typeid:
        $case GeometryId::typeid:
        $case TextureId::typeid:
        $case SamplerId::typeid:
        $case MaterialId::typeid:
        $case ModelId::typeid:
        $case ClipId::typeid:
        $case SkeletonId::typeid:
        $case ShaderId::typeid:
        $case ComputeShaderId::typeid:
        $case EnvironmentId::typeid:
        $case FontId::typeid:
            return ASSET;
        $default:
            $switch $Type::kind:
                $case ENUM: return ENUM;
                $case STRUCT: return STRUCT;
                $case ARRAY: return ARRAY;
                $case SLICE: return SLICE;
                $default: $error "Unsupported described field: " +++ $name +++ " (" +++ $Type::qname +++ ")";
            $endswitch
    $endswitch
}

macro AssetKind @asset_kind($Type) @private {
    $switch $Type::typeid:
        $case GeometryId::typeid: return GEOMETRY;
        $case TextureId::typeid: return TEXTURE;
        $case SamplerId::typeid: return SAMPLER;
        $case MaterialId::typeid: return MATERIAL;
        $case ModelId::typeid: return MODEL;
        $case ClipId::typeid: return CLIP;
        $case SkeletonId::typeid: return SKELETON;
        $case ShaderId::typeid: return SHADER;
        $case ComputeShaderId::typeid: return COMPUTE_SHADER;
        $case EnvironmentId::typeid: return ENVIRONMENT;
        $case FontId::typeid: return FONT;
        $default: return CUSTOM;
    $endswitch
}

macro bool @transient($member) @private {
    $if $member.has_tag("transient"):
        return $member.get_tag("transient");
    $else
        return false;
    $endif
}

macro bool @range_valid($Type, #minimum, #maximum) @private {
    $switch @kind($Type):
        $case ARRAY:
        $case SLICE:
            return @range_valid($Typefrom($Type::inner), #minimum, #maximum);
        $case INT:
        $case UINT:
            return #minimum <= #maximum
                && #minimum >= (double)$Type::min && #maximum <= (double)$Type::max
                && #minimum == (double)(int128)#minimum && #maximum == (double)(int128)#maximum;
        $case LONG:
        $case ULONG:
            // Double rounds 64-bit maxima beyond their valid integer range.
            return #minimum <= #maximum
                && #minimum >= (double)$Type::min && #maximum < (double)$Type::max
                && #minimum == (double)(int128)#minimum && #maximum == (double)(int128)#maximum;
        $case FLOAT:
        $case VEC2:
        $case VEC3:
        $case VEC4:
            return #minimum <= #maximum
                && #minimum >= -(double)float::max && #maximum <= (double)float::max;
        $case DOUBLE:
            return #minimum <= #maximum
                && #minimum >= -double::max && #maximum <= double::max;
        $default:
            return false;
    $endswitch
}

macro bool @metadata_valid($Type, Metadata metadata) @private {
    if (metadata.range.enabled && !@range_valid($Type, metadata.range.min, metadata.range.max)) return false;
    $switch @kind($Type):
        $case ARRAY:
        $case SLICE:
            return @metadata_valid($Typefrom($Type::inner), metadata);
        $case ASSET:
            $if $Type::typeid == Id::typeid:
                return metadata.has_asset_kind;
            $else
                return !metadata.has_asset_kind || metadata.asset_kind == @asset_kind($Type);
            $endif
        $default:
            return !metadata.has_asset_kind;
    $endswitch
}
