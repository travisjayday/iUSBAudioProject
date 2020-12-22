sudo rm -r /Library/Audio/Plug-Ins/HAL/USBAudioDriver.driver
sudo launchctl kickstart -kp system/com.apple.audio.coreaudiod
exit
sudo mv /Volumes/macHDD/XCode/DerivedData/iAudioProject-gqoandplmgjtybculddcsqxqcsyk/Build/Products/Debug/USBAudioDriver.driver /Library/Audio/Plug-Ins/HAL
sudo launchctl kickstart -kp system/com.apple.audio.coreaudiod
