#ifdef WITH_AVF

#include "guid_device_avf.hpp"
#include <iostream>

namespace bias {

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
        return value_.compare(guid.toString()) < 0;
    }

    bool GuidDevice_avf::lessThanEqual(GuidDevice &guid)
    {
        return isEqual(guid) || lessThan(guid);
    }
}

#endif
