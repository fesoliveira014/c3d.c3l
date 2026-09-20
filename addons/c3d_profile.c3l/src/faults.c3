module c3d::profile @feat(C3D_PROFILE_CPU | C3D_PROFILE_GPU);

<* Recorder descriptor cannot be represented safely. *>
faultdef INVALID_ARGUMENT;

<* Source identity space is exhausted. *>
faultdef CAPACITY_EXCEEDED;

<* Requested capture is not retained. *>
faultdef NOT_FOUND;
