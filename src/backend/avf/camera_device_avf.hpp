#ifdef WITH_AVF
#ifndef BIAS_CAMERA_DEVICE_AVF_HPP
#define BIAS_CAMERA_DEVICE_AVF_HPP

#include "camera_device.hpp"
#include "guid.hpp"

namespace bias {

    // Stage 2: constructor succeeds, but connect/startCapture/grabImage are
    // still stubs. Stage 3 wires up the AVCaptureSession.
    class CameraDevice_avf : public CameraDevice
    {
        public:
            CameraDevice_avf();
            explicit CameraDevice_avf(Guid guid);
            virtual ~CameraDevice_avf();

            virtual CameraLib getCameraLib();

            virtual void connect();
            virtual void disconnect();
            virtual void startCapture();
            virtual void stopCapture();
            virtual cv::Mat grabImage();
            virtual void grabImage(cv::Mat &image);

            virtual std::string getVendorName();
            virtual std::string getModelName();
    };

}

#endif
#endif
