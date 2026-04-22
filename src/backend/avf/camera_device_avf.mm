#ifdef WITH_AVF

#include "camera_device_avf.hpp"
#include <opencv2/core.hpp>

namespace bias {

    CameraDevice_avf::CameraDevice_avf() : CameraDevice() {}

    CameraDevice_avf::CameraDevice_avf(Guid guid) : CameraDevice(guid) {}

    CameraDevice_avf::~CameraDevice_avf()
    {
        if (capturing_) { stopCapture(); }
        if (connected_) { disconnect(); }
    }

    CameraLib CameraDevice_avf::getCameraLib()
    {
        return CAMERA_LIB_AVF;
    }

    void CameraDevice_avf::connect()
    {
        // Stage 3 will resolve the AVCaptureDevice from guid_ and build the
        // AVCaptureSession. For now, just mark as connected so the GUI wiring
        // lights up.
        connected_ = true;
    }

    void CameraDevice_avf::disconnect()
    {
        connected_ = false;
    }

    void CameraDevice_avf::startCapture()
    {
        capturing_ = true;
    }

    void CameraDevice_avf::stopCapture()
    {
        capturing_ = false;
    }

    cv::Mat CameraDevice_avf::grabImage()
    {
        return cv::Mat();
    }

    void CameraDevice_avf::grabImage(cv::Mat &image)
    {
        image = cv::Mat();
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
