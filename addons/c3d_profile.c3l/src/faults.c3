module c3d::profile @feat(C3D_PROFILE_CPU);

<* Recorder descriptor cannot be represented safely. *>
faultdef INVALID_ARGUMENT;

<* Requested capture is not retained. *>
faultdef NOT_FOUND;
