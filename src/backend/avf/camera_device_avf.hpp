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

            // Minimum reporting so CameraWindow::setCameraFromMap accepts
            // round-tripped configurations. AVF devices only support a
            // single "format7"-style mode at whatever resolution the
            // camera's AVCaptureDeviceFormat exposes; everything maps to
            // IMAGEMODE_0 / VIDEOMODE_FORMAT7 / FRAMERATE_FORMAT7 / MONO8.
            virtual bool isColor();
            virtual bool isSupported(VideoMode vidMode, FrameRate frmRate);
            virtual bool isSupported(ImageMode imgMode);
            virtual unsigned int getNumberOfImageMode();
            virtual VideoMode getVideoMode();
            virtual FrameRate getFrameRate();
            virtual ImageMode getImageMode();
            virtual VideoModeList getAllowedVideoModes();
            virtual FrameRateList getAllowedFrameRates(VideoMode vidMode);
            virtual ImageModeList getAllowedImageModes();
            virtual Format7Settings getFormat7Settings();
            virtual Format7Info getFormat7Info(ImageMode imgMode);
            virtual bool validateFormat7Settings(Format7Settings settings);
            virtual void setFormat7Configuration(Format7Settings settings,
                                                 float percentSpeed);
            virtual PixelFormatList getListOfSupportedPixelFormats(ImageMode imgMode);
            virtual TriggerType getTriggerType();
            virtual ImageInfo getImageInfo();

            virtual std::string getVendorName();
            virtual std::string getModelName();

        private:
            std::unique_ptr<CameraDevice_avf_Impl> impl_;
            std::string modelName_;
            unsigned int width_ = 0;
            unsigned int height_ = 0;
    };

}

#endif
#endif
