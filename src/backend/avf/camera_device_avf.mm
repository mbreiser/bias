#ifdef WITH_AVF

#include "camera_device_avf.hpp"
#include "exception.hpp"
#include <sstream>

namespace bias {

    CameraDevice_avf::CameraDevice_avf() : CameraDevice() {}

    CameraDevice_avf::CameraDevice_avf(Guid guid) : CameraDevice(guid)
    {
        // Stage 1: enumeration is not wired up yet, so this constructor
        // is unreachable in practice. Stage 3 will resolve the AVCaptureDevice
        // from the guid's unique ID and prepare the capture session.
        std::stringstream ss;
        ss << __PRETTY_FUNCTION__ << ": AVFoundation capture not yet implemented";
        throw RuntimeError(ERROR_AVF_DEVICE_NOT_FOUND, ss.str());
    }

    CameraDevice_avf::~CameraDevice_avf() {}

    CameraLib CameraDevice_avf::getCameraLib()
    {
        return CAMERA_LIB_AVF;
    }

    std::string CameraDevice_avf::getVendorName()
    {
        return std::string("Apple");
    }

    std::string CameraDevice_avf::getModelName()
    {
        return std::string("AVFoundation");
    }

}

#endif
