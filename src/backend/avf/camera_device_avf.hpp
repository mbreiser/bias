#ifdef WITH_AVF
#ifndef BIAS_CAMERA_DEVICE_AVF_HPP
#define BIAS_CAMERA_DEVICE_AVF_HPP

#include "camera_device.hpp"
#include "guid.hpp"

namespace bias {

    // Stage 1 stub: declared so the facade can link, but constructing one
    // throws RuntimeError until Stage 3 lands the AVCaptureSession plumbing.
    class CameraDevice_avf : public CameraDevice
    {
        public:
            CameraDevice_avf();
            explicit CameraDevice_avf(Guid guid);
            virtual ~CameraDevice_avf();
            virtual CameraLib getCameraLib();
            virtual std::string getVendorName();
            virtual std::string getModelName();
    };

}

#endif
#endif
