#ifndef BIAS_OPENCV4_COMPAT_HPP
#define BIAS_OPENCV4_COMPAT_HPP

// Shim for legacy OpenCV 2/3 CV_* constants removed in OpenCV 4.
// Include this in any .cpp that still uses them.

#include <opencv2/imgproc.hpp>
#include <opencv2/videoio.hpp>
#include <opencv2/imgcodecs.hpp>

#ifndef CV_RETR_EXTERNAL
#  define CV_RETR_EXTERNAL        cv::RETR_EXTERNAL
#  define CV_CHAIN_APPROX_NONE    cv::CHAIN_APPROX_NONE
#  define CV_FILLED               cv::FILLED
#  define CV_GRAY2BGR             cv::COLOR_GRAY2BGR
#  define CV_BGR2GRAY             cv::COLOR_BGR2GRAY
#  define CV_THRESH_BINARY        cv::THRESH_BINARY
#  define CV_IMWRITE_JPEG_QUALITY cv::IMWRITE_JPEG_QUALITY
#  define CV_FONT_HERSHEY_SIMPLEX cv::FONT_HERSHEY_SIMPLEX
#  define CV_FOURCC(c1,c2,c3,c4)  cv::VideoWriter::fourcc(c1,c2,c3,c4)
#endif

#endif
