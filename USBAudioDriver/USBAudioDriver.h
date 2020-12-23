//
//  USBAudioDriver.h
//  iAudioProject
//
//  Created by Travis Ziegler on 12/22/20.
//

#ifndef USBAudioDriver_h
#define USBAudioDriver_h

//==================================================================================================
// Include
//==================================================================================================

// System Includes
#include <CoreAudio/AudioServerPlugIn.h>
#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdint.h>
#include <sys/syslog.h>

//==================================================================================================
#pragma mark -
#pragma mark Macros
//==================================================================================================

#if TARGET_RT_BIG_ENDIAN
    #define    FourCCToCString(the4CC)    { ((char*)&the4CC)[0], ((char*)&the4CC)[1], ((char*)&the4CC)[2], ((char*)&the4CC)[3], 0 }
#else
    #define    FourCCToCString(the4CC)    { ((char*)&the4CC)[3], ((char*)&the4CC)[2], ((char*)&the4CC)[1], ((char*)&the4CC)[0], 0 }
#endif


#if DEBUG

    #define    DebugMsg(inFormat, ...)    syslog(LOG_NOTICE, inFormat, ## __VA_ARGS__)

    #define    FailIf(inCondition, inHandler, inMessage)                                    \
            if(inCondition)                                                                \
            {                                                                            \
                DebugMsg(inMessage);                                                    \
                goto inHandler;                                                            \
            }

    #define    FailWithAction(inCondition, inAction, inHandler, inMessage)                    \
            if(inCondition)                                                                \
            {                                                                            \
                DebugMsg(inMessage);                                                    \
                { inAction; }                                                            \
                goto inHandler;                                                            \
            }

#else

    #define    DebugMsg(inFormat, ...)
    
    #define    FailIf(inCondition, inHandler, inMessage)                                    \
            if(inCondition)                                                                \
            {                                                                            \
                goto inHandler;                                                            \
            }

    #define    FailWithAction(inCondition, inAction, inHandler, inMessage)                    \
            if(inCondition)                                                                \
            {                                                                            \
                { inAction; }                                                            \
                goto inHandler;                                                            \
            }

#endif

//==================================================================================================
#pragma mark -
#pragma mark USBAudio State
//==================================================================================================

// The purpose of the USBAudio is to provide the barest of bare bones implementations to
// illustrate the minimal set of things a driver has to do. As such, the driver has the following
// qualities:
// - a box
// - a device
//     - supports 44100 and 48000 sample rates
//     - provides a rate scalar of 1.0 via hard coding
// - a single input stream
//     - supports 2 channels of 32 bit float LPCM samples
//     - always produces zeros
// - a single output stream
//     - supports 2 channels of 32 bit float LPCM samples
//     - data written to it is ignored
// - controls
//     - master input volume
//     - master output volume
//     - master input mute
//     - master output mute
//     - master input data source
//     - master output data source
//     - all are for illustration purposes only and do not actually manipulate data


// Declare the internal object ID numbers for all the objects this driver implements. Note that
// because the driver has fixed set of objects that never grows or shrinks. If this were not the
// case, the driver would need to have a means to dynamically allocate these IDs. It is important
// to realize that a lot of the structure of this driver is vastly simpler when the IDs are all
// known a priori. Comments in the code will try to identify some of these simplifications and
// point out what a more complicated driver will need to do.
enum
{
    kObjectID_PlugIn                    = kAudioObjectPlugInObject,
    kObjectID_Box                       = 2,
    kObjectID_Device                    = 3,
    kObjectID_Stream_Input              = 4,
    kObjectID_Volume_Input_Master       = 5,
    kObjectID_Mute_Input_Master         = 6,
    kObjectID_DataSource_Input_Master   = 7,
    kObjectID_Stream_Output             = 8,
    kObjectID_Volume_Output_Master      = 9,
    kObjectID_Mute_Output_Master        = 10,
    kObjectID_DataSource_Output_Master  = 11
};

// Declare the stuff that tracks the state of the plug-in, the device and its sub-objects.
// Note that we use global variables here because this driver only ever has a single device. If
// multiple devices were supported, this state would need to be encapsulated in one or more structs
// so that each object's state can be tracked individually.
// Note also that we share a single mutex across all objects to be thread safe for the same reason.
#define                         kPlugIn_BundleID                "com.tzgames.audio.USBAudioDriver"
static pthread_mutex_t          gPlugIn_StateMutex              = PTHREAD_MUTEX_INITIALIZER;
static UInt32                   gPlugIn_RefCount                = 0;
static AudioServerPlugInHostRef gPlugIn_Host                    = NULL;

#define                         kBox_UID                        "USBAudioBox_UID"
static CFStringRef              gBox_Name                       = NULL;
static Boolean                  gBox_Acquired                   = true;

#define                         kDevice_UID                     "USBAudioDevice_UID"
#define                         kDevice_ModelUID                "USBAudioDevice_ModelUID"
#define                         kDevice_HumanName               "USB Audio Interface"
#define                         kDevice_Manufacturer            "Ape Inc."

static pthread_mutex_t          gDevice_IOMutex                 = PTHREAD_MUTEX_INITIALIZER;
static UInt64                   gDevice_IOIsRunning             = 0;
static const Float64            kDevice_SampleRateOption1       = 32000.0;
static const Float64            kDevice_SampleRateOption2       = 44100.0;
static Float64                  gDevice_SampleRate              = kDevice_SampleRateOption1;
static const UInt32             kDevice_RingBufferSize          = 16384;
static const UInt32             kDevice_NumChannels             = 1;
static const UInt32             kDevice_BitsPerChannel          = 16;
static const UInt32             kDevice_BytesPerFrame           = (kDevice_BitsPerChannel / 8) * kDevice_NumChannels;
static Float64                  gDevice_HostTicksPerFrame       = 0.0;
static UInt64                   gDevice_NumberTimeStamps        = 0;
static Float64                  gDevice_AnchorSampleTime        = 0.0;
static UInt64                   gDevice_AnchorHostTime          = 0;

static char                     gDevice_ringBuffer[kDevice_RingBufferSize];
static UInt64                   gDevice_ringBufferOffset        = 0;
static UInt64                   gDevice_inIOBufferByteSize      = 0;
static UInt64                   gDevice_remainingRingBufferByteSize = 0;

static bool                     gStream_Input_IsActive          = true;
static bool                     gStream_Output_IsActive         = true;

static const Float32            kVolume_MinDB                   = -96.0;
static const Float32            kVolume_MaxDB                   = 6.0;
static Float32                  gVolume_Input_Master_Value      = 0.0;
static Float32                  gVolume_Output_Master_Value     = 0.0;

static bool                     gMute_Input_Master_Value        = false;
static bool                     gMute_Output_Master_Value       = false;

static const UInt32             kDataSource_NumberItems         = 1;
#define                         kDataSource_ItemNamePattern     "iAudio USB Device %d"
static UInt32                   gDataSource_Input_Master_Value  = 0;
static UInt32                   gDataSource_Output_Master_Value = 0;

//==================================================================================================
#pragma mark -
#pragma mark AudioServerPlugInDriverInterface Implementation
//==================================================================================================

#pragma mark Prototypes

// Entry points for the COM methods
void*                   USBAudio_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID);
static HRESULT          USBAudio_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface);
static ULONG            USBAudio_AddRef(void* inDriver);
static ULONG            USBAudio_Release(void* inDriver);
static OSStatus         USBAudio_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost);
static OSStatus         USBAudio_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo* inClientInfo, AudioObjectID* outDeviceObjectID);
static OSStatus         USBAudio_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID);
static OSStatus         USBAudio_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo);
static OSStatus         USBAudio_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo);
static OSStatus         USBAudio_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo);
static OSStatus         USBAudio_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo);
static Boolean          USBAudio_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress);
static OSStatus         USBAudio_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable);
static OSStatus         USBAudio_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize);
static OSStatus         USBAudio_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData);
static OSStatus         USBAudio_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData);
static OSStatus         USBAudio_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus         USBAudio_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus         USBAudio_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed);
static OSStatus         USBAudio_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean* outWillDo, Boolean* outWillDoInPlace);
static OSStatus         USBAudio_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo);
static OSStatus         USBAudio_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo, void* ioMainBuffer, void* ioSecondaryBuffer);
static OSStatus         USBAudio_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo);

// Implementation
static Boolean          USBAudio_HasPlugInProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress);
static OSStatus         USBAudio_IsPlugInPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable);
static OSStatus         USBAudio_GetPlugInPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize);
static OSStatus         USBAudio_GetPlugInPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData);
static OSStatus         USBAudio_SetPlugInPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData, UInt32* outNumberPropertiesChanged, AudioObjectPropertyAddress outChangedAddresses[2]);

static Boolean          USBAudio_HasBoxProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress);
static OSStatus         USBAudio_IsBoxPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable);
static OSStatus         USBAudio_GetBoxPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize);
static OSStatus         USBAudio_GetBoxPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData);
static OSStatus         USBAudio_SetBoxPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData, UInt32* outNumberPropertiesChanged, AudioObjectPropertyAddress outChangedAddresses[2]);

static Boolean          USBAudio_HasDeviceProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress);
static OSStatus         USBAudio_IsDevicePropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable);
static OSStatus         USBAudio_GetDevicePropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize);
static OSStatus         USBAudio_GetDevicePropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData);
static OSStatus         USBAudio_SetDevicePropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData, UInt32* outNumberPropertiesChanged, AudioObjectPropertyAddress outChangedAddresses[2]);

static Boolean          USBAudio_HasStreamProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress);
static OSStatus         USBAudio_IsStreamPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable);
static OSStatus         USBAudio_GetStreamPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize);
static OSStatus         USBAudio_GetStreamPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData);
static OSStatus         USBAudio_SetStreamPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData, UInt32* outNumberPropertiesChanged, AudioObjectPropertyAddress outChangedAddresses[2]);

static Boolean          USBAudio_HasControlProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress);
static OSStatus         USBAudio_IsControlPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable);
static OSStatus         USBAudio_GetControlPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize);
static OSStatus         USBAudio_GetControlPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData);
static OSStatus         USBAudio_SetControlPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData, UInt32* outNumberPropertiesChanged, AudioObjectPropertyAddress outChangedAddresses[2]);

#pragma mark The Interface

static AudioServerPlugInDriverInterface gAudioServerPlugInDriverInterface =
{
    NULL,
    USBAudio_QueryInterface,
    USBAudio_AddRef,
    USBAudio_Release,
    USBAudio_Initialize,
    USBAudio_CreateDevice,
    USBAudio_DestroyDevice,
    USBAudio_AddDeviceClient,
    USBAudio_RemoveDeviceClient,
    USBAudio_PerformDeviceConfigurationChange,
    USBAudio_AbortDeviceConfigurationChange,
    USBAudio_HasProperty,
    USBAudio_IsPropertySettable,
    USBAudio_GetPropertyDataSize,
    USBAudio_GetPropertyData,
    USBAudio_SetPropertyData,
    USBAudio_StartIO,
    USBAudio_StopIO,
    USBAudio_GetZeroTimeStamp,
    USBAudio_WillDoIOOperation,
    USBAudio_BeginIOOperation,
    USBAudio_DoIOOperation,
    USBAudio_EndIOOperation
};
static AudioServerPlugInDriverInterface* gAudioServerPlugInDriverInterfacePtr = &gAudioServerPlugInDriverInterface;
static AudioServerPlugInDriverRef gAudioServerPlugInDriverRef = &gAudioServerPlugInDriverInterfacePtr;


#endif /* USBAudioDriver_h */
