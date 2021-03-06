# iUSBAudioProject
Software enabling macOS audio playback on an iOS device over USB. 

# Project State
The project is usable and has been tested on macOS 11 and iPad Air 2. Transmission of mono-channel 16-bit audio from iOS mic to macOS and macOS system audio to iPad is working succesfully with very low latency. Drivers have been written to allow for volume control and voice pitch change using FFT. 

# Installation
- Compile USBAudioDriver to make `USBAudioDriver.driver`. Run `./install_usb_driver.sh [PATH TO .driver file]`
- Compile iOSMicDriver to make `iOSMicDriver.driver`. Run `./install_usb_driver.sh [PATH TO .driver file]`
- Compile and run iAudioClient on your iOS device
- Compile and run iAudioServer on your mac (in the menu bar, you will see the connection status)

# Structure
`USBAudioDriver.driver` is a macOS userland system extension that creates a virtual audio IO device. 
This audio device feeds its output to its input. 
Setting this audio device as the system default audio, then reading from it allows us to capture all system audio. 
The driver's source is in `USBAudioDriver/USBAudioDriver.c`

`iAudioServer` is a macOS userland application that uses `usbmuxd` to scan for, connect to, and transmit data to connected iOS devices. 
It reads from the virutal audio device and sends captured data to connected iOS devices. 

`iAudioClient` is an iOS application that listens for incoming connections initiated by `iAudioServer`. 
Upon connection, it plays back the audio transmitted by `iAudioServer`, i.e. the audio generated by the virtual audio IO device, i.e. system output audio.

# Thanks
Thanks to big brother Apple. 
