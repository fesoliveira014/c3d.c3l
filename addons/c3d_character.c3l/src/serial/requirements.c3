module c3d::character @feat(C3D_CHARACTER_SERIAL);

macro bool @valid_serial_features() @local {
    $if !$feat(C3D_PHYSICS_SERIAL):
        $error "C3D_CHARACTER_SERIAL requires C3D_PHYSICS_SERIAL.";
    $endif
    $if $feat(C3D_CHARACTER_NAV) && !$feat(C3D_NAV_SERIAL):
        $error "NavDriven serialization requires C3D_NAV_SERIAL and C3D_CHARACTER_NAV.";
    $endif
    return true;
}

$assert @valid_serial_features();
