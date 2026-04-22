#ifndef FRAME_DATA_HPP
#define FRAME_DATA_HPP

#include <opencv2/core.hpp>
#include <QQueue>
#include <QSharedPointer>


namespace bias
{
    class FrameData
    {

        public:

            FrameData() {};

            cv::Mat image;
            unsigned long count;
    };

    typedef QQueue<FrameData> FrameDataQueue;
    typedef QSharedPointer<FrameDataQueue> FrameDataQueuePtr;

}


#endif
