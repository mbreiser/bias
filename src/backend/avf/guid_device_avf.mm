#ifdef WITH_AVF

#include "guid_device_avf.hpp"
#include <cstdlib>
#include <iostream>

namespace bias {

    // Reads BIAS_AVF_PREFER_UID once. If set, GuidDevice_avf::lessThan
    // treats that uid as smaller than any other, so the std::set-based
    // GuidSet ends up with the preferred camera at position 0 (cam 0 in
    // main.cpp, HTTP port 5010). Unset (default) → plain alphabetical.
    static const std::string &preferredUid()
    {
        static const std::string uid = []() -> std::string {
            const char *v = std::getenv("BIAS_AVF_PREFER_UID");
            return v ? std::string(v) : std::string();
        }();
        return uid;
    }


    GuidDevice_avf::GuidDevice_avf()
    {
        value_ = std::string();
    }

    GuidDevice_avf::GuidDevice_avf(std::string uniqueID)
    {
        value_ = uniqueID;
    }

    CameraLib GuidDevice_avf::getCameraLib()
    {
        return CAMERA_LIB_AVF;
    }

    std::string GuidDevice_avf::toString()
    {
        return value_;
    }

    void GuidDevice_avf::printValue()
    {
        std::cout << "guid: " << toString() << std::endl;
    }

    std::string GuidDevice_avf::getValue()
    {
        return value_;
    }

    bool GuidDevice_avf::isEqual(GuidDevice &guid)
    {
        return value_.compare(guid.toString()) == 0;
    }

    bool GuidDevice_avf::lessThan(GuidDevice &guid)
    {
        const std::string &pref = preferredUid();
        if (!pref.empty())
        {
            const bool meIsPref    = (value_ == pref);
            const bool otherIsPref = (guid.toString() == pref);
            if (meIsPref && !otherIsPref) { return true; }
            if (!meIsPref && otherIsPref) { return false; }
        }
        return value_.compare(guid.toString()) < 0;
    }

    bool GuidDevice_avf::lessThanEqual(GuidDevice &guid)
    {
        return isEqual(guid) || lessThan(guid);
    }
}

#endif
