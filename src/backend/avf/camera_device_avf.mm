#ifdef WITH_AVF

#include "camera_device_avf.hpp"
#include "utils_avf.hpp"
#include "exception.hpp"
#include <sstream>
#include <mutex>
#include <cstdio>
#include <cstdarg>
#include <opencv2/core.hpp>
#include <opencv2/imgproc.hpp>
#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>

// File-based delegate tracing, gated behind env var BIAS_AVF_TRACE.
// Set BIAS_AVF_TRACE=1 before launching test_gui to get a per-frame log
// at /tmp/bias_avf_delegate.log. Useful for debugging AVCaptureSession
// setup, pixel formats, and whether the delegate is firing.
static void bias_avf_trace(const char *fmt, ...)
{
    static FILE *f = nullptr;
    static bool enabled = false;
    static std::once_flag once;
    std::call_once(once, []{
        const char *v = getenv("BIAS_AVF_TRACE");
        enabled = (v && *v && *v != '0');
        if (enabled) {
            f = fopen("/tmp/bias_avf_delegate.log", "w");
            if (f) setvbuf(f, nullptr, _IOLBF, 0);
        }
    });
    if (!enabled || !f) return;
    va_list ap;
    va_start(ap, fmt);
    vfprintf(f, fmt, ap);
    va_end(ap);
    fputc('\n', f);
}

@class BiasAvfDelegate;

namespace bias {

    struct CameraDevice_avf_Impl
    {
        AVCaptureSession *session = nil;
        AVCaptureDevice *device = nil;
        AVCaptureDeviceInput *input = nil;
        AVCaptureVideoDataOutput *output = nil;
        BiasAvfDelegate *delegate = nil;
        dispatch_queue_t queue = nullptr;

        std::mutex frameMutex;
        cv::Mat latestFrame;
    };

}

// Sample-buffer delegate — lives in the .mm file's internal linkage
@interface BiasAvfDelegate : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
{
    bias::CameraDevice_avf_Impl *impl_;
}
- (instancetype)initWithImpl:(bias::CameraDevice_avf_Impl *)impl;
@end

@implementation BiasAvfDelegate

- (instancetype)initWithImpl:(bias::CameraDevice_avf_Impl *)impl
{
    self = [super init];
    if (self) { impl_ = impl; }
    return self;
}

- (void)captureOutput:(AVCaptureOutput *)output
      didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
           fromConnection:(AVCaptureConnection *)connection
{
    static int fireCount = 0;
    ++fireCount;

    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!imageBuffer) {
        bias_avf_trace("fire %d: NULL imageBuffer", fireCount);
        return;
    }

    OSType pf = CVPixelBufferGetPixelFormatType(imageBuffer);
    char pfChars[5] = { (char)((pf>>24)&0xFF), (char)((pf>>16)&0xFF),
                        (char)((pf>>8)&0xFF), (char)(pf&0xFF), 0 };

    CVPixelBufferLockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);

    const size_t width  = CVPixelBufferGetWidth(imageBuffer);
    const size_t height = CVPixelBufferGetHeight(imageBuffer);

    cv::Mat gray;

    if (pf == kCVPixelFormatType_32BGRA) {
        const size_t stride = CVPixelBufferGetBytesPerRow(imageBuffer);
        uint8_t *base = (uint8_t *)CVPixelBufferGetBaseAddress(imageBuffer);
        if (base && width > 0 && height > 0) {
            cv::Mat bgra((int)height, (int)width, CV_8UC4, base, stride);
            cv::cvtColor(bgra, gray, cv::COLOR_BGRA2GRAY);
        }
    }
    else if (pf == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
             pf == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
    {
        // Y plane (plane 0) is grayscale already — just copy it
        const size_t stride0 = CVPixelBufferGetBytesPerRowOfPlane(imageBuffer, 0);
        uint8_t *base0 = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(imageBuffer, 0);
        if (base0 && width > 0 && height > 0) {
            cv::Mat y((int)height, (int)width, CV_8UC1, base0, stride0);
            y.copyTo(gray);  // deep copy so we don't hold onto CV's mapped pages
        }
    }
    // Add other formats as needed.

    CVPixelBufferUnlockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);

    if (fireCount == 1 || fireCount % 60 == 0) {
        bias_avf_trace("fire %d: pf=0x%x (%s) %zux%zu gray.empty=%d size=%dx%d",
                       fireCount, (unsigned)pf, pfChars, width, height,
                       gray.empty() ? 1 : 0, gray.cols, gray.rows);
    }

    if (!gray.empty()) {
        std::lock_guard<std::mutex> lock(impl_->frameMutex);
        impl_->latestFrame = gray;  // overwrites any un-consumed prior frame
    }
}

@end

namespace bias {

    // Synchronous camera-access request. Blocks connect() until the user
    // answers the TCC prompt (or immediately if already decided).
    static bool ensureCameraAuthorization()
    {
        AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
        bias_avf_trace("[bias.avf] initial authorizationStatus = %ld", (long)status);
        if (status == AVAuthorizationStatusAuthorized) { return true; }
        if (status == AVAuthorizationStatusDenied ||
            status == AVAuthorizationStatusRestricted) {
            bias_avf_trace("[bias.avf] auth denied/restricted — returning false without prompting");
            return false;
        }

        bias_avf_trace("[bias.avf] authorizationStatus NotDetermined, calling requestAccessForMediaType...");
        __block bool granted = false;
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo
                                 completionHandler:^(BOOL ok) {
            bias_avf_trace("[bias.avf] requestAccess completion ok=%d", ok);
            granted = ok;
            dispatch_semaphore_signal(sem);
        }];
        dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
        bias_avf_trace("[bias.avf] requestAccess returned, granted=%d", granted);
        return granted;
    }

    CameraDevice_avf::CameraDevice_avf()
        : CameraDevice(), impl_(new CameraDevice_avf_Impl())
    {}

    CameraDevice_avf::CameraDevice_avf(Guid guid)
        : CameraDevice(guid), impl_(new CameraDevice_avf_Impl())
    {}

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
        if (connected_) { return; }

        if (!ensureCameraAuthorization())
        {
            std::stringstream ss;
            ss << __PRETTY_FUNCTION__
               << ": camera access denied. Grant access in "
               << "System Settings > Privacy & Security > Camera.";
            throw RuntimeError(ERROR_AVF_AUTHORIZATION_DENIED, ss.str());
        }

        @autoreleasepool {
            NSString *uid = std_to_nsstring(guid_.toString());
            AVCaptureDevice *device = [AVCaptureDevice deviceWithUniqueID:uid];
            if (!device)
            {
                std::stringstream ss;
                ss << __PRETTY_FUNCTION__
                   << ": no AVCaptureDevice with uniqueID " << guid_.toString();
                throw RuntimeError(ERROR_AVF_DEVICE_NOT_FOUND, ss.str());
            }
            impl_->device = device;
            modelName_ = nsstring_to_std(device.localizedName);

            // Capture native dimensions from the device's active format so
            // getFormat7Info/getImageInfo can report them. This is what
            // BIAS's setCameraFromMap uses when round-tripping configs.
            if (device.activeFormat) {
                CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(
                    device.activeFormat.formatDescription);
                width_ = (unsigned int)dims.width;
                height_ = (unsigned int)dims.height;
                bias_avf_trace("[bias.avf] device active format %ux%u", width_, height_);
            }

            NSError *err = nil;
            AVCaptureDeviceInput *input =
                [AVCaptureDeviceInput deviceInputWithDevice:device error:&err];
            if (!input)
            {
                std::stringstream ss;
                ss << __PRETTY_FUNCTION__
                   << ": AVCaptureDeviceInput failed: "
                   << nsstring_to_std(err.localizedDescription);
                throw RuntimeError(ERROR_AVF_CREATE_INPUT, ss.str());
            }
            impl_->input = input;

            AVCaptureSession *session = [[AVCaptureSession alloc] init];
            if (![session canAddInput:input])
            {
                std::stringstream ss;
                ss << __PRETTY_FUNCTION__ << ": session cannot add input";
                throw RuntimeError(ERROR_AVF_CREATE_INPUT, ss.str());
            }
            [session addInput:input];
            impl_->session = session;

            AVCaptureVideoDataOutput *output = [[AVCaptureVideoDataOutput alloc] init];
            output.alwaysDiscardsLateVideoFrames = YES;
            if (![session canAddOutput:output])
            {
                std::stringstream ss;
                ss << __PRETTY_FUNCTION__ << ": session cannot add video data output";
                throw RuntimeError(ERROR_AVF_NO_BGRA_FORMAT, ss.str());
            }
            [session addOutput:output];
            impl_->output = output;

            // Log what pixel formats AVF offers on this output, then try to
            // request BGRA if it's in the list. Fall back to native otherwise.
            NSArray *avail = output.availableVideoCVPixelFormatTypes;
            bias_avf_trace("[bias.avf] availableVideoCVPixelFormatTypes count=%lu",
                           (unsigned long)avail.count);
            bool wantBGRA = false;
            for (NSNumber *n in avail) {
                OSType pf = (OSType)[n unsignedIntValue];
                char pc[5] = { (char)((pf>>24)&0xFF), (char)((pf>>16)&0xFF),
                               (char)((pf>>8)&0xFF), (char)(pf&0xFF), 0 };
                bias_avf_trace("[bias.avf]   format 0x%x (%s)", (unsigned)pf, pc);
                if (pf == kCVPixelFormatType_32BGRA) { wantBGRA = true; }
            }
            if (wantBGRA) {
                output.videoSettings = @{
                    (NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)
                };
                bias_avf_trace("[bias.avf] requested BGRA output");
            } else {
                bias_avf_trace("[bias.avf] BGRA not in availableVideoCVPixelFormatTypes; using native");
            }

            impl_->queue = dispatch_queue_create("com.bias.avf.capture", DISPATCH_QUEUE_SERIAL);
            impl_->delegate = [[BiasAvfDelegate alloc] initWithImpl:impl_.get()];
            [output setSampleBufferDelegate:impl_->delegate queue:impl_->queue];
            id postSetDelegate = output.sampleBufferDelegate;
            bias_avf_trace("[bias.avf] delegate set; connections=%lu; output.sbDelegate=%p (ours=%p same=%d) ours retainCount~%d",
                           (unsigned long)output.connections.count,
                           (__bridge void*)postSetDelegate,
                           (__bridge void*)impl_->delegate,
                           postSetDelegate == impl_->delegate,
                           (int)[impl_->delegate respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]);
            for (AVCaptureConnection *c in output.connections) {
                bias_avf_trace("[bias.avf]   connection enabled=%d active=%d inputPorts=%lu",
                               c.enabled, c.active, (unsigned long)c.inputPorts.count);
                for (AVCaptureInputPort *p in c.inputPorts) {
                    bias_avf_trace("[bias.avf]     inputPort mediaType=%s enabled=%d",
                                   [p.mediaType UTF8String], p.enabled);
                }
            }
        }

        connected_ = true;
    }

    void CameraDevice_avf::disconnect()
    {
        if (!connected_) { return; }
        if (capturing_) { stopCapture(); }

        @autoreleasepool {
            if (impl_->session && impl_->input) {
                [impl_->session removeInput:impl_->input];
            }
            if (impl_->session && impl_->output) {
                [impl_->session removeOutput:impl_->output];
            }
            impl_->delegate = nil;
            impl_->output = nil;
            impl_->input = nil;
            impl_->session = nil;
            impl_->device = nil;
            impl_->queue = nullptr;
        }
        connected_ = false;
    }

    void CameraDevice_avf::startCapture()
    {
        if (!connected_)
        {
            std::stringstream ss;
            ss << __PRETTY_FUNCTION__ << ": connect() first";
            throw RuntimeError(ERROR_AVF_NOT_CONNECTED, ss.str());
        }
        if (capturing_) { return; }
        bias_avf_trace("[bias.avf] startCapture entry; delegate=%p queue=%p output=%p",
                       (__bridge void*)impl_->delegate,
                       (__bridge void*)impl_->queue,
                       (__bridge void*)impl_->output);
        @autoreleasepool {
            [impl_->session startRunning];
            bias_avf_trace("[bias.avf] session.running=%d after startRunning", impl_->session.running);
        }
        capturing_ = true;
    }

    void CameraDevice_avf::stopCapture()
    {
        if (!capturing_) { return; }
        @autoreleasepool {
            [impl_->session stopRunning];
        }
        capturing_ = false;
    }

    cv::Mat CameraDevice_avf::grabImage()
    {
        cv::Mat out;
        grabImage(out);
        return out;
    }

    void CameraDevice_avf::grabImage(cv::Mat &image)
    {
        std::lock_guard<std::mutex> lock(impl_->frameMutex);
        if (impl_->latestFrame.empty())
        {
            image = cv::Mat();
        }
        else
        {
            image = impl_->latestFrame;   // cheap: cv::Mat = shared reference to the pixel data
            impl_->latestFrame = cv::Mat();  // consume — next frame will be set by the delegate
        }
    }

    std::string CameraDevice_avf::getVendorName()
    {
        return std::string("Apple");
    }

    std::string CameraDevice_avf::getModelName()
    {
        return modelName_.empty() ? std::string("AVFoundation") : modelName_;
    }

    // --- Minimum reporting methods so BIAS's setCameraFromMap round-trips ---

    bool CameraDevice_avf::isColor()
    {
        // We convert everything to MONO8 in the delegate, so from BIAS's
        // perspective the stream is monochrome.
        return false;
    }

    bool CameraDevice_avf::isSupported(VideoMode vidMode, FrameRate frmRate)
    {
        return vidMode == VIDEOMODE_FORMAT7 && frmRate == FRAMERATE_FORMAT7;
    }

    bool CameraDevice_avf::isSupported(ImageMode imgMode)
    {
        return imgMode == IMAGEMODE_0;
    }

    unsigned int CameraDevice_avf::getNumberOfImageMode()
    {
        return 1;
    }

    VideoMode CameraDevice_avf::getVideoMode()
    {
        return VIDEOMODE_FORMAT7;
    }

    FrameRate CameraDevice_avf::getFrameRate()
    {
        return FRAMERATE_FORMAT7;
    }

    ImageMode CameraDevice_avf::getImageMode()
    {
        return IMAGEMODE_0;
    }

    VideoModeList CameraDevice_avf::getAllowedVideoModes()
    {
        VideoModeList list;
        list.push_back(VIDEOMODE_FORMAT7);
        return list;
    }

    FrameRateList CameraDevice_avf::getAllowedFrameRates(VideoMode /*vidMode*/)
    {
        FrameRateList list;
        list.push_back(FRAMERATE_FORMAT7);
        return list;
    }

    ImageModeList CameraDevice_avf::getAllowedImageModes()
    {
        ImageModeList list;
        list.push_back(IMAGEMODE_0);
        return list;
    }

    Format7Settings CameraDevice_avf::getFormat7Settings()
    {
        Format7Settings s;
        s.mode = IMAGEMODE_0;
        s.offsetX = 0;
        s.offsetY = 0;
        s.width = width_;
        s.height = height_;
        s.pixelFormat = PIXEL_FORMAT_MONO8;
        return s;
    }

    Format7Info CameraDevice_avf::getFormat7Info(ImageMode /*imgMode*/)
    {
        Format7Info info;
        info.mode = IMAGEMODE_0;
        info.supported = true;
        info.maxWidth = width_ > 0 ? width_ : 1;
        info.maxHeight = height_ > 0 ? height_ : 1;
        info.offsetHStepSize = 1;
        info.offsetVStepSize = 1;
        info.imageHStepSize = 1;
        info.imageVStepSize = 1;
        info.pixelFormatBitField = 0;
        info.vendorPixelFormatBitField = 0;
        info.packetSize = 0;
        info.minPacketSize = 0;
        info.maxPacketSize = 0;
        info.percentage = 100.0f;
        return info;
    }

    bool CameraDevice_avf::validateFormat7Settings(Format7Settings /*settings*/)
    {
        // AVF delivers whatever the device's active format gives us;
        // we accept all settings and no-op on apply. Good enough for
        // Phase 2/3 — the user can't actually change the size mid-stream.
        return true;
    }

    void CameraDevice_avf::setFormat7Configuration(Format7Settings /*settings*/,
                                                   float /*percentSpeed*/)
    {
        // No-op: AVF format selection is a future enhancement.
    }

    PixelFormatList CameraDevice_avf::getListOfSupportedPixelFormats(
        ImageMode /*imgMode*/)
    {
        PixelFormatList list;
        list.push_back(PIXEL_FORMAT_MONO8);
        return list;
    }

    TriggerType CameraDevice_avf::getTriggerType()
    {
        return TRIGGER_INTERNAL;
    }

    ImageInfo CameraDevice_avf::getImageInfo()
    {
        ImageInfo info;
        info.rows = height_;
        info.cols = width_;
        info.stride = width_;  // MONO8 packed
        info.dataSize = width_ * height_;
        info.pixelFormat = PIXEL_FORMAT_MONO8;
        return info;
    }

}

#endif
