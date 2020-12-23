dest=/Library/Audio/Plug-Ins/HAL
src=$1

echo "Going to install $src into $dest..."

splits=(${src//\// })
fname=${splits[${#splits[@]}-1]}


echo "Removing $fname from $dest..."

echo
echo "Will run:"

cmd="sudo rm -r $dest/$fname"

echo $cmd
echo
read -p "Continue? " -n 1 -r

eval $cmd

echo "Restarting coreaudio..."
sudo launchctl kickstart -kp system/com.apple.audio.coreaudiod

echo "Moving driver..."
sudo mv $src $dest 

echo "Restarting coreaudio..."
sudo launchctl kickstart -kp system/com.apple.audio.coreaudiod

echo "Complete"
