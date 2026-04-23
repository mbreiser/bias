#ifdef WITH_AVF
#ifndef BIAS_CAMERA_DEVICE_AVF_HPP
#define BIAS_CAMERA_DEVICE_AVF_HPP

#include "camera_device.hpp"
#include "guid.hpp"
#include <memory>

namespace bias {

    struct CameraDevice_avf_Impl;  // opaque, defined in camera_device_avf.mm

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

        private:
            std::unique_ptr<CameraDevice_avf_Impl> impl_;
            std::string modelName_;
    };

}

#endif
#endif
