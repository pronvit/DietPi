#!/bin/bash
{
	#------------------------------------------------------------------------------------------------
	# Optimize current Debian installation and prep for DietPi installation.
	#------------------------------------------------------------------------------------------------
	# REQUIREMENTS
	# - Currently running Debian (ideally minimal, eg: Raspbian Lite-ish =)) )
	# - Active eth0 connection
	#------------------------------------------------------------------------------------------------
	# Dev notes:
	# Following items must be exported at all times, throughout this script, else, additional scripts launched will trigger incorrect results.
	# - G_HW_MODEL
	# - G_HW_ARCH
	# - G_DISTRO
	#------------------------------------------------------------------------------------------------

	#Use master branch, if unset
	GIT_BRANCH=${GIT_BRANCH:=master}
	echo -e "Git Branch: $GIT_BRANCH"

	#Ensure we are in users home dir: https://github.com/Fourdee/DietPi/issues/905#issuecomment-298223705
	cd "$HOME"

	#------------------------------------------------------------------------------------------------
	# Critical checks and pre-reqs, with exit, prior to initial run of script
	#------------------------------------------------------------------------------------------------
	#Exit path for non-root logins.
	if (( $UID )); then

		echo -e 'Error: Root privileges required, please run the script with "sudo"\nIn case install the "sudo" package with root privileges:\n\t# apt-get install -y sudo\n'
		exit 1

	fi

	# - APT force IPv4
	echo 'Acquire::ForceIPv4 "true";' > /etc/apt/apt.conf.d/99-dietpi-force-ipv4

	#Check/install minimal APT Pre-Reqs
	a_MIN_APT_PREREQS=(

		'wget'
		'ca-certificates'
		'locales'
		'ncurses-bin' #tput G_WHIP
		'unzip' #dietpi sourcecode extract, pre APT install

	)

	# - Meveric special: https://github.com/Fourdee/DietPi/issues/1285#issuecomment-355759321
	rm /etc/apt/sources.list.d/deb-multimedia.list &> /dev/null

	apt-get clean
	apt-get update
	for (( i=0; i<${#a_MIN_APT_PREREQS[@]}; i++))
	do

		if ! dpkg --get-selections | grep -qi "^${a_MIN_APT_PREREQS[$i]}[[:space:]]"; then

			apt-get install -y ${a_MIN_APT_PREREQS[$i]}
			if (( $? )); then

				echo -e "Error: Unable to install ${a_MIN_APT_PREREQS[$i]}, please try to install it manually:\n\t# apt-get install -y ${a_MIN_APT_PREREQS[$i]}"
				exit 1

			fi

		fi

	done

	unset a_MIN_APT_PREREQS

	# - Wget prefer IPv4
	if grep -q '^[[:blank:]]*prefer-family =' /etc/wgetrc; then

		sed -i '/^[[:blank:]]*prefer-family =/c\prefer-family = IPv4' /etc/wgetrc

	elif grep -q '^[[:blank:]#;]*prefer-family =' /etc/wgetrc; then

		sed -i '/^[[:blank:]#;]*prefer-family =/c\prefer-family = IPv4' /etc/wgetrc

	else

		echo 'prefer-family = IPv4' >> /etc/wgetrc

	fi

	#Setup locale
	# - Remove exisiting settings that will break dpkg-reconfigure
	> /etc/environment
	rm /etc/default/locale &> /dev/null

	#	NB: DEV, any changes here must be also rolled into function '/DietPi/dietpi/func/dietpi-set_software locale', for future script use
	echo 'en_GB.UTF-8 UTF-8' > /etc/locale.gen
	dpkg-reconfigure -f noninteractive locales
	# dpkg-reconfigure includes:
	#	- "locale-gen": Generate locale(s) based on "/etc/locale.gen" or interactive selection.
	#	- "update-locale": Add $LANG to "/etc/default/locale" based on generated locale(s) or interactive default language selection.
	if (( $? )); then

		echo -e 'Error: Locale generation failed. Aborting...\n'
		exit 1

	fi

	# - Update /etc/default/locales with new values (not effective until next load of bash session, eg: logout/in)
	update-locale LANG=en_GB.UTF-8
	update-locale LC_CTYPE=en_GB.UTF-8
	update-locale LC_TIME=en_GB.UTF-8
	update-locale LC_ALL=en_GB.UTF-8

	#Force en_GB Locale for rest of script. Prevents incorrect parsing with non-english locales.
	export LC_ALL=en_GB.UTF-8
	export LANG=en_GB.UTF-8

	#------------------------------------------------------------------------------------------------
	#Globals
	#------------------------------------------------------------------------------------------------
	#Download DietPi-Globals
	# - NB: we'll have to manually handle errors, until script is sucessfully loaded
	wget https://raw.githubusercontent.com/Fourdee/DietPi/$GIT_BRANCH/dietpi/func/dietpi-globals -O dietpi-globals
	if (( $? )); then

		echo -e 'Error: Unable to download dietpi-globals. Aborting...\n'
		exit 1

	fi

	# - load
	. ./dietpi-globals
	if (( $? )); then

		echo -e 'Error: Unable to load dietpi-globals. Aborting...\n'
		exit 1

	fi

	export G_PROGRAM_NAME='DietPi-PREP'
	export HIERARCHY=0
	export G_DISTRO=0 # Export to dietpi-globals
	export G_DISTRO_NAME='NULL' # Export to dietpi-globals
	DISTRO_TARGET=0
	DISTRO_TARGET_NAME=''
	if grep -q 'wheezy' /etc/os-release; then

		G_DISTRO=2
		G_DISTRO_NAME='wheezy'

	elif grep -q 'jessie' /etc/os-release; then

		G_DISTRO=3
		G_DISTRO_NAME='jessie'

	elif grep -q 'stretch' /etc/os-release; then

		G_DISTRO=4
		G_DISTRO_NAME='stretch'

	elif grep -q 'buster' /etc/os-release; then

		G_DISTRO=5
		G_DISTRO_NAME='buster'

	else

		echo -e 'Error: Unknown or unsupported distribution version. Aborting...\n'
		exit 1

	fi

	#G_HW_MODEL # init from dietpi-globals
	#G_HW_ARCH_DESCRIPTION # init from dietpi-globals
	G_HW_ARCH_DESCRIPTION="$(uname -m)"
	if [[ $G_HW_ARCH_DESCRIPTION == armv6l ]]; then

		export G_HW_ARCH=1

	elif [[ $G_HW_ARCH_DESCRIPTION == armv7l ]]; then

		export G_HW_ARCH=2

	elif [[ $G_HW_ARCH_DESCRIPTION == aarch64 ]]; then

		export G_HW_ARCH=3

	elif [[ $G_HW_ARCH_DESCRIPTION == x86_64 ]]; then

		export G_HW_ARCH=10

	else

		echo -e "Error: Unknown or unsupported CPU architecture \"$G_HW_ARCH_DESCRIPTION\". Aborting...\n"
		exit 1

	fi

	#WiFi install flag
	WIFI_REQUIRED=0

	#Image creator flags
	IMAGE_CREATOR=''
	PREIMAGE_INFO=''

	#Setup step, current (used in info)
	SETUP_STEP=0

	#URL connection test var holder
	INTERNET_ADDRESS=''

	#------------------------------------------------------------------------------------------------
	#------------------------------------------------------------------------------------------------
	#------------------------------------------------------------------------------------------------
	# MAIN LOOP
	#------------------------------------------------------------------------------------------------
	#------------------------------------------------------------------------------------------------
	#------------------------------------------------------------------------------------------------

	#------------------------------------------------------------------------------------------------
	echo ''
	G_DIETPI-NOTIFY 2 '-----------------------------------------------------------------------------------'
	G_DIETPI-NOTIFY 0 "Step $SETUP_STEP: Detecting existing DietPi system:"
	((SETUP_STEP++))
	G_DIETPI-NOTIFY 2 '-----------------------------------------------------------------------------------'
	#------------------------------------------------------------------------------------------------
	if systemctl is-active dietpi-ramdisk | grep -qi '^active'; then

		G_DIETPI-NOTIFY 2 'DietPi system found, running pre-prep'

		# - Stop services
		/DietPi/dietpi/dietpi-services stop

		G_RUN_CMD systemctl stop dietpi-ramlog
		G_RUN_CMD systemctl stop dietpi-ramdisk

		# - Delete any previous exsiting data
		rm -R /DietPi/*
		rm -R /boot/dietpi

		rm -R /mnt/dietpi-backup &> /dev/null
		rm -R /mnt/dietpi-sync &> /dev/null
		rm -R /mnt/dietpi_userdata &> /dev/null

		rm -R /etc/dietpi &> /dev/null # Pre v160
		rm -R /var/lib/dietpi &> /dev/null
		rm -R /var/tmp/dietpi &> /dev/null

		rm /root/DietPi-Automation.log &> /dev/null
		rm /boot/Automation_Format_My_Usb_Drive &> /dev/null

	else

		G_DIETPI-NOTIFY 2 'Non-DietPi system'

	fi

	#------------------------------------------------------------------------------------------------
	echo ''
	G_DIETPI-NOTIFY 2 '-----------------------------------------------------------------------------------'
	G_DIETPI-NOTIFY 0 "Step $SETUP_STEP: Initial prep to allow this script to function:"
	((SETUP_STEP++))
	G_DIETPI-NOTIFY 2 '-----------------------------------------------------------------------------------'
	#------------------------------------------------------------------------------------------------
	G_DIETPI-NOTIFY 2 'Updating APT:'

	#Recreate dietpi logs dir, used by G_AGx
	G_RUN_CMD mkdir -p /var/tmp/dietpi/logs

	G_DIETPI-NOTIFY 2 'Installing core packages, required for next stage of this script:'

	G_AGI apt-transport-https unzip whiptail

	#------------------------------------------------------------------------------------------------
	echo ''
	G_DIETPI-NOTIFY 2 '-----------------------------------------------------------------------------------'
	G_DIETPI-NOTIFY 0 "Step $SETUP_STEP (inputs): Image info / Hardware / WiFi / Distro:"
	((SETUP_STEP++))
	G_DIETPI-NOTIFY 2 '-----------------------------------------------------------------------------------'
	#------------------------------------------------------------------------------------------------

	#Image creator
	while true
	do

		G_WHIP_INPUTBOX 'Please enter your name. This will be used to identify the image creator within credits banner.\n\nYou can add your contanct information as well for end users.\n\nNB: An entry is required.'
		if (( ! $? )) && [[ -n $G_WHIP_RETURNED_VALUE ]]; then

			#Disallowed:
			DISALLOWED_NAME=0
			aDISALLOWED_NAMES=(

				'official'
				'fourdee'
				'daniel knight'
				'dan knight'
				'michaing'
				'k-plan'
				'diet'

			)

			LOWERCASE_TEMP="$(echo -e $G_WHIP_RETURNED_VALUE | tr '[:upper:]' '[:lower:]')"
			for (( i=0; i<${#aDISALLOWED_NAMES[@]}; i++))
			do

				if [[ $LOWERCASE_TEMP == *"${aDISALLOWED_NAMES[$i]}"* ]]; then

					DISALLOWED_NAME=1
					break

				fi

			done

			unset aDISALLOWED_NAMES

			if (( $DISALLOWED_NAME )); then

				G_WHIP_MSG "\"$G_WHIP_RETURNED_VALUE\" is reserved and cannot be used. Please try again."

			else

				IMAGE_CREATOR="$G_WHIP_RETURNED_VALUE"
				break

			fi

		fi

	done

	#Pre-image used/name
	while true
	do

		G_WHIP_INPUTBOX 'Please enter the name or URL of the pre-image you installed on this system, prior to running this script. This will be used to identify the pre-image credits.\n\nEG: Debian, Raspbian Lite, Meveric, FriendlyARM, or "forum.odroid.com/viewtopic.php?f=ABC&t=XYZ" etc.\n\nNB: An entry is required.'
		if (( ! $? )) && [[ -n $G_WHIP_RETURNED_VALUE ]]; then

			PREIMAGE_INFO="$G_WHIP_RETURNED_VALUE"
			break

		fi

	done

	#Hardware selection
	G_WHIP_DEFAULT_ITEM=22
	G_WHIP_BUTTON_CANCEL_TEXT='Exit'
	G_WHIP_MENU_ARRAY=(

		'' '────Other──────────────────────────────'
		'22' 'Generic device (unknown to DietPi)'
		'' '────SBC─(Core devices)─────────────────'
		'10' 'Odroid C1'
		'12' 'Odroid C2'
		'14' 'Odroid N1'
		'13' 'Odroid U3'
		'11' 'Odroid XU3/4/HC1/HC2'
		'0' 'Raspberry Pi 1 (256mb)'
		'1' 'Raspberry Pi 1/Zero (512mb)'
		'2' 'Raspberry Pi 2'
		'3' 'Raspberry Pi 3/3+'
		'' '────PC─────────────────────────────────'
		'21' 'x86_64 Native PC'
		'20' 'x86_64 VMware/VirtualBox'
		'' '────SBC─(Limited support devices)──────'
		'52' 'Asus Tinker Board'
		'53' 'BananaPi (sinovoip)'
		'51' 'BananaPi Pro (Lemaker)'
		'50' 'BananaPi M2+ (sinovoip)'
		'71' 'Beagle Bone Black'
		'39' 'LeMaker Guitar'
		'67' 'NanoPi K1 Plus'
		'66' 'NanoPi M1 Plus'
		'65' 'NanoPi NEO 2'
		'64' 'NanoPi NEO Air'
		'63' 'NanoPi M1/T1'
		'62' 'NanoPi M3/T3'
		'61' 'NanoPi M2/T2'
		'60' 'NanoPi Neo'
		'38' 'OrangePi PC 2'
		'37' 'OrangePi Prime'
		'36' 'OrangePi Win'
		'35' 'OrangePi Zero Plus 2 (H3/H5)'
		'34' 'OrangePi Plus'
		'33' 'OrangePi Lite'
		'32' 'OrangePi Zero (H2+)'
		'31' 'OrangePi One'
		'30' 'OrangePi PC'
		'41' 'OrangePi PC Plus'
		'40' 'Pine A64'
		'43' 'Rock64'
		'70' 'Sparky SBC'

	)

	G_WHIP_MENU 'Please select the current device this is being installed on:\n - NB: Select "Generic device" if not listed.\n - "Core devices": Are fully supported by DietPi, offering full GPU + Kodi support.\n - "Limited support devices": No GPU support, supported limited to DietPi specific issues only (eg: excludes Kernel/GPU/VPU related items).'
	if (( $? )) || [[ -z $G_WHIP_RETURNED_VALUE ]]; then

		G_DIETPI-NOTIFY 1 'No choices detected. Aborting...'
		exit 0

	fi

	# + Export to future scripts
	export G_HW_MODEL=$G_WHIP_RETURNED_VALUE

	G_DIETPI-NOTIFY 2 "Setting G_HW_MODEL index of: $G_HW_MODEL"
	G_DIETPI-NOTIFY 2 "CPU ARCH = $G_HW_ARCH : $G_HW_ARCH_DESCRIPTION"

	echo -e "$G_HW_MODEL" > /etc/.dietpi_hw_model_identifier

	#WiFi selection
	G_DIETPI-NOTIFY 2 'WiFi selection'

	G_WHIP_DEFAULT_ITEM=1
	G_WHIP_MENU_ARRAY=(

		'0' "I don't require WiFi, do not install."
		'1' 'I require WiFi functionality, keep/install related packages.'

	)

	G_WHIP_MENU 'Please select an option:'
	if (( $? == 0 && $G_WHIP_RETURNED_VALUE == 1 )); then

		G_DIETPI-NOTIFY 2 'Marking WiFi as needed'
		WIFI_REQUIRED=1

	fi

	#Distro Selection
	G_WHIP_DEFAULT_ITEM=$G_DISTRO
	G_WHIP_BUTTON_CANCEL_TEXT='Exit'
	DISTRO_LIST_ARRAY=(

		'3' 'Jessie (oldstable, just if you need to avoid upgrade to current release)'
		'4' 'Stretch (current stable release, recommended)'
		'5' 'Buster (testing only, not officially supported)'

	)

	# - Enable/list available options based on criteria
	#	NB: Whiptail use 2 array indexs per whip displayed entry.
	G_WHIP_MENU_ARRAY=()
	for ((i=0; i<$(( ${#DISTRO_LIST_ARRAY[@]} / 2 )); i++))
	do
		temp_distro_available=1
		temp_distro_index=$(( $i + 3 ))

		# - Disable downgrades
		if (( $temp_distro_index < $G_DISTRO )); then

			G_DIETPI-NOTIFY 2 "Disabled Distro downgrade: index $temp_distro_index"
			temp_distro_available=0

		fi

		# - Enable option
		if (( $temp_distro_available )); then

			G_WHIP_MENU_ARRAY+=( "${DISTRO_LIST_ARRAY[$(( $i * 2 ))]}" "${DISTRO_LIST_ARRAY[$(( ($i * 2) + 1 ))]}" )

		fi

	done

	#delete []
	unset DISTRO_LIST_ARRAY

	if [[ -z ${G_WHIP_MENU_ARRAY+x} ]]; then

		G_DIETPI-NOTIFY 1 'Error: No available Distros for this system. Aborting...'
		exit 1

	fi

	G_WHIP_MENU "Please select a distro to install on this system. Selecting a distro that is older than the current installed on system, is not supported.\n\nCurrently installed:\n - $G_DISTRO $G_DISTRO_NAME"
	if (( $? )) || [[ -z $G_WHIP_RETURNED_VALUE ]]; then

		G_DIETPI-NOTIFY 1 'No choices detected. Aborting...'
		exit 0

	fi

	DISTRO_TARGET=$G_WHIP_RETURNED_VALUE
	if (( $DISTRO_TARGET == 3 )); then

		DISTRO_TARGET_NAME='jessie'

	elif (( $DISTRO_TARGET == 4 )); then

		DISTRO_TARGET_NAME='stretch'

	elif (( $DISTRO_TARGET == 5 )); then

		DISTRO_TARGET_NAME='buster'

	fi


	#------------------------------------------------------------------------------------------------
	echo ''
	G_DIETPI-NOTIFY 2 '-----------------------------------------------------------------------------------'
	G_DIETPI-NOTIFY 0 "Step $SETUP_STEP: Downloading and installing DietPi sourcecode:"
	((SETUP_STEP++))
	G_DIETPI-NOTIFY 2 '-----------------------------------------------------------------------------------'
	#------------------------------------------------------------------------------------------------

	INTERNET_ADDRESS="https://github.com/Fourdee/DietPi/archive/$GIT_BRANCH.zip"
	G_RUN_CMD wget "$INTERNET_ADDRESS" -O package.zip

	G_DIETPI-NOTIFY 2 'Extracting DietPi sourcecode'

	G_RUN_CMD unzip -o package.zip

	rm package.zip

	G_DIETPI-NOTIFY 2 'Removing files not required'

	#	Remove files we do not require, or want to overwrite in /boot
	rm DietPi-*/CHANGELOG.txt
	rm DietPi-*/PREP_SYSTEM_FOR_DIETPI.sh
	rm DietPi-*/TESTING-BRANCH.md
	rm DietPi-*/uEnv.txt # Pine 64, use existing on system.

	G_DIETPI-NOTIFY 2 'Creating /boot'

	G_RUN_CMD mkdir -p /boot

	G_DIETPI-NOTIFY 2 'Moving to /boot'

	# - HW specific boot.ini uEnv.txt
	if (( $G_HW_MODEL == 10 )); then

		G_RUN_CMD mv DietPi-*/boot_c1.ini /boot/boot.ini

	elif (( $G_HW_MODEL == 11 )); then

		G_RUN_CMD mv DietPi-*/boot_xu4.ini /boot/boot.ini

	elif (( $G_HW_MODEL == 12 )); then

		G_RUN_CMD mv DietPi-*/boot_c2.ini /boot/boot.ini

	fi
	rm DietPi-*/*.ini
	(( $G_HW_MODEL > 9 )) && rm DietPi-*/config.txt 

	G_RUN_CMD cp -R DietPi-*/* /boot/

	G_DIETPI-NOTIFY 2 'Cleaning up extracted files'

	G_RUN_CMD rm -R DietPi-*

	G_DIETPI-NOTIFY 2 'Setting execute permissions for /boot/dietpi'

	G_RUN_CMD chmod -R +x /boot/dietpi

	G_DIETPI-NOTIFY 2 'Installing DietPi-RAMDISK'

	#	NB: Duplicate of set-core_env
	cat << _EOF_ > /etc/systemd/system/dietpi-ramdisk.service
[Unit]
Description=DietPi-RAMdisk
After=local-fs.target boot.mount
Before=rsyslog.service syslog.service

[Service]
Type=forking
RemainAfterExit=yes
ExecStartPre=$(which mkdir) -p /var/tmp/dietpi/logs
ExecStart=/bin/bash -c '/boot/dietpi/dietpi-ramdisk 0 &>> /var/tmp/dietpi/logs/dietpi-ramdisk.log'
ExecStop=/bin/bash -c '/DietPi/dietpi/dietpi-ramdisk 1 &>> /var/tmp/dietpi/logs/dietpi-ramdisk.log'

[Install]
WantedBy=local-fs.target
_EOF_
	systemctl daemon-reload
	systemctl enable dietpi-ramdisk.service

	G_DIETPI-NOTIFY 2 'Starting DietPi-RAMDISK'

	# - Mount tmpfs
	mkdir -p /DietPi
	mount -t tmpfs -o size=20m tmpfs /DietPi
	#G_RUN_CMD systemctl start dietpi-ramdisk.service
	/boot/dietpi/dietpi-ramdisk 0

	#------------------------------------------------------------------------------------------------
	echo ''
	G_DIETPI-NOTIFY 2 '-----------------------------------------------------------------------------------'
	G_DIETPI-NOTIFY 0 "Step $SETUP_STEP: APT configuration:"
	((SETUP_STEP++))
	G_DIETPI-NOTIFY 2 '-----------------------------------------------------------------------------------'
	#------------------------------------------------------------------------------------------------

	G_DIETPI-NOTIFY 2 'Removing conflicting /etc/apt/sources.list.d entries'
	#	NB: Apt sources will get overwritten during 1st run, via boot script and dietpi.txt entry

	#rm /etc/apt/sources.list.d/* &> /dev/null #Probably a bad idea
	#rm /etc/apt/sources.list.d/deb-multimedia.list &> /dev/null #meveric, already done above
	rm /etc/apt/sources.list.d/openmediavault.list &> /dev/null #http://dietpi.com/phpbb/viewtopic.php?f=11&t=2772&p=10646#p10594

	G_DIETPI-NOTIFY 2 "Setting APT sources.list: $DISTRO_TARGET_NAME $DISTRO_TARGET"

	# - We need to temp export target DISTRO vars, then revert them to current, after setting sources.list
	G_DISTRO_TEMP=$G_DISTRO
	G_DISTRO_NAME_TEMP="$G_DISTRO_NAME"
	export G_DISTRO=$DISTRO_TARGET
	export G_DISTRO_NAME="$DISTRO_TARGET_NAME"

	G_RUN_CMD /DietPi/dietpi/func/dietpi-set_software apt-mirror 'default'

	export G_DISTRO=$G_DISTRO_TEMP
	export G_DISTRO_NAME="$G_DISTRO_NAME_TEMP"
	unset G_DISTRO_TEMP
	unset G_DISTRO_NAME_TEMP

	# - Meveric, update repo to use our EU mirror: https://github.com/Fourdee/DietPi/issues/1519#issuecomment-368234302
	sed -i 's@https://oph.mdrjr.net/meveric@http://fuzon.co.uk/meveric@' /etc/apt/sources.list.d/meveric* &> /dev/null

	G_DIETPI-NOTIFY 2 "Updating APT for $DISTRO_TARGET_NAME:"

	G_RUN_CMD apt-get clean

	G_AGUP

	# - @MichaIng https://github.com/Fourdee/DietPi/pull/1266/files
	G_DIETPI-NOTIFY 2 'Marking all packages as auto installed first, to allow effective autoremove afterwards'

	G_RUN_CMD apt-mark auto $(apt-mark showmanual)

	# - @MichaIng https://github.com/Fourdee/DietPi/pull/1266/files
	G_DIETPI-NOTIFY 2 'Disable automatic recommends/suggests installation and allow them to be autoremoved:'

	#	Remove any existing apt recommends settings
	rm /etc/apt/apt.conf.d/*recommends*

	export G_ERROR_HANDLER_COMMAND='/etc/apt/apt.conf.d/99-dietpi-norecommends'
	cat << _EOF_ > $G_ERROR_HANDLER_COMMAND
APT::Install-Recommends "false";
APT::Install-Suggests "false";
APT::AutoRemove::RecommendsImportant "false";
APT::AutoRemove::SuggestsImportant "false";
_EOF_
	export G_ERROR_HANDLER_EXITCODE=$?
	G_ERROR_HANDLER

	G_DIETPI-NOTIFY 2 'Forcing use of modified package configs'

	export G_ERROR_HANDLER_COMMAND='/etc/apt/apt.conf.d/99-dietpi-forceconf'
	cat << _EOF_ > $G_ERROR_HANDLER_COMMAND
Dpkg::options {
   "--force-confdef";
   "--force-confold";
}
_EOF_
	export G_ERROR_HANDLER_EXITCODE=$?
	G_ERROR_HANDLER

	# - DietPi list of minimal required packages, which must be installed:
	aPACKAGES_REQUIRED_INSTALL=(

		'apt-transport-https'	# Allows https sources in ATP
		'apt-utils'		# Allows debconf to preconfigure APT packages before installing
		'bash-completion'	# Auto completes a wide list of bash commands
		'bc'			# Floating point calculation within bash
		'bzip2'			# .bz2 wrapper
		'ca-certificates'	# Adds known ca-certificates, necessary to practically access https sources
		'console-setup'		# DietPi-Config keyboard configuration
		'cron'			# background job scheduler
		'curl'			# Web address testing, downloading, uploading etc.
		'debconf'		# APT package configuration, e.g. 'debconf-set-selections'
		'dirmngr'		# GNU key management required for some APT installs via additional repos
		'dosfstools' 		# DietPi-Drive_Manager + fat (boot) drive file system check
		'ethtool'		# Ethernet link checking
		'fake-hwclock'		# Hardware clock emulation, to allow correct timestamps during boot before network time sync
		'gnupg'			# apt-key add
		'hfsplus'		# DietPi-Drive_Manager NTS (MacOS) file system support
		'htop'			# System monitor
		'initramfs-tools'	# RAM file system initialization
		'iputils-ping'		# ping command
		'isc-dhcp-client'	# DHCP client
		'locales'		# Support locales, necessary for DietPi scripts, as we use enGB.UTF8 as default language
		'nano'			# Simple text editor
		'net-tools'		# DietPi-Boot: Network tools, ifconfig, route etc.
		'ntfs-3g'		# DietPi-Drive_Manager NTPS (Windows) file system support
		'ntp'			# Network time syncronization
		'p7zip-full'		# .7z wrapper
		'parted'		# DietPi-Boot + DietPi-Drive_Manager
		'psmisc'		# DietPi-Boot + DietPi-Software: e.g. killall
		'resolvconf'		# System name server updater
		'sudo'			# DietPi-Software + general use
		'systemd-sysv'		# Includes systemd and additional commands: poweroff, shutdown etc.
		'tzdata'		# Time zone data for system clock, auto summer/winter time adjustment
		'unzip'			# .zip unwrapper
		'usbutils'		# DietPi-Software + DietPi-Bugreport: e.g. lsusb
		'wget'			# download
		'whiptail'		# DietPi dialogs
		'wput'			# upload
		'zip'			# .zip wrapper

	)

	if (( $WIFI_REQUIRED )); then

		aPACKAGES_REQUIRED_INSTALL+=('crda')			# WiFi related
		aPACKAGES_REQUIRED_INSTALL+=('firmware-atheros')	# WiFi dongle firmware
		aPACKAGES_REQUIRED_INSTALL+=('firmware-brcm80211')	# WiFi dongle firmware
		aPACKAGES_REQUIRED_INSTALL+=('iw')			# WiFi related
		aPACKAGES_REQUIRED_INSTALL+=('rfkill')	 		# WiFi related: Used by some onboard WiFi chipsets
		aPACKAGES_REQUIRED_INSTALL+=('wireless-tools')		# WiFi related
		aPACKAGES_REQUIRED_INSTALL+=('wpasupplicant')		# WiFi related

		# Intel/Nvidia/WiFi (ralink) dongle firmware: https://github.com/Fourdee/DietPi/issues/1675#issuecomment-377806609
		# On Jessie, firmware-misc-nonfree is not available, firmware-ralink instead as dedicated package.
		if (( $G_DISTRO < 4 )); then

			aPACKAGES_REQUIRED_INSTALL+=('firmware-ralink')

		else

			aPACKAGES_REQUIRED_INSTALL+=('firmware-misc-nonfree')

		fi

	fi

	# - G_DISTRO specific required packages:
	if (( $G_DISTRO < 4 )); then

		aPACKAGES_REQUIRED_INSTALL+=('dropbear')		# DietPi default SSH-Client

	else

		aPACKAGES_REQUIRED_INSTALL+=('dropbear-run')		# DietPi default SSH-Client (excluding initramfs integration, available since Stretch)

	fi

	# - G_HW_MODEL specific required repo key packages
	#	Repo keys: https://github.com/Fourdee/DietPi/issues/1285#issuecomment-358301273
	if (( $G_HW_MODEL >= 10 )); then

		G_AGI debian-archive-keyring

	else

		G_AGI raspbian-archive-keyring

	fi

	# - G_HW_MODEL specific required packages:
	#	VM: No network firmware necessary and hard drive power management stays at host system.
	if (( $G_HW_MODEL != 20 )); then

		G_AGI firmware-realtek					# Eth/WiFi/BT dongle firmware
		aPACKAGES_REQUIRED_INSTALL+=('hdparm')			# Drive power management adjustment

	fi

	# - Kernel required packages
	# - G_HW_ARCH specific required Kernel packages
	#	As these are kernel, firmware or bootloader packages, we need to install them directly to allow autoremove of in case older kernel packages:
	#	https://github.com/Fourdee/DietPi/issues/1285#issuecomment-354602594
	#	x86_64
	if (( $G_HW_ARCH == 10 )); then

		G_AGI linux-image-amd64
		# Usually no firmware should be necessary for VMs. If user manually passes though some USB device, he might need to install the firmware then.
		(( $G_HW_MODEL != 20 )) && G_AGI firmware-linux-nonfree

		#	Grub EFI
		if dpkg --get-selections | grep -q '^grub-efi-amd64' ||
			[ -d /boot/efi ]; then

			G_AGI grub-efi-amd64

		#	Grub BIOS
		else

			G_AGI grub-pc

		fi

	# - G_HW_MODEL specific required Kernel packages
	#	RPi
	elif (( $G_HW_MODEL < 10 )); then

		apt-mark unhold libraspberrypi-bin libraspberrypi0 raspberrypi-bootloader raspberrypi-kernel raspberrypi-sys-mods raspi-copies-and-fills
		rm -R /lib/modules/*
		G_AGI libraspberrypi-bin libraspberrypi0 raspberrypi-bootloader raspberrypi-kernel raspberrypi-sys-mods
		G_AGI --reinstall libraspberrypi-bin libraspberrypi0 raspberrypi-bootloader raspberrypi-kernel
		# Buster systemd-udevd doesn't support the current raspi-copies-and-fills: https://github.com/Fourdee/DietPi/issues/1286
		(( $DISTRO_TARGET < 5 )) && G_AGI raspi-copies-and-fills

	#	Odroid N1
	elif (( $G_HW_MODEL == 14 )); then

		G_AGI linux-image-arm64-odroid-n1
		#G_AGI libdrm-rockchip1 #Not currently on meveric's repo

	#	Odroid C2
	elif (( $G_HW_MODEL == 12 )); then

		G_AGI linux-image-arm64-odroid-c2

	#	Odroid XU3/4/HC1
	elif (( $G_HW_MODEL == 11 )); then

		#G_AGI linux-image-4.9-armhf-odroid-xu3
		G_AGI $(dpkg --get-selections | grep '^linux-image' | awk '{print $1}')
		dpkg --get-selections | grep -qi '^linux-image' || G_AGI linux-image-4.14-armhf-odroid-xu4

	#	Odroid C1
	elif (( $G_HW_MODEL == 10 )); then

		G_AGI linux-image-armhf-odroid-c1

	#	Rock64
	elif (( $G_HW_MODEL == 43 )); then

		G_AGI linux-rock64-package gdisk

	#	BBB
	elif (( $G_HW_MODEL == 71 )); then

		G_AGI device-tree-compiler #Kern


	# - Auto detect kernel/firmware package
	else

		AUTO_DETECT_KERN_PKG=$(dpkg --get-selections | grep '^linux-image' | awk '{print $1}')
		if [[ -n $AUTO_DETECT_KERN_PKG ]]; then

			# - Install kern package if it exists in cache, else, mark manual #: https://github.com/Fourdee/DietPi/issues/1651#issuecomment-376974917
			if [[ -n $(apt-cache search ^$AUTO_DETECT_KERN_PKG) ]]; then

				G_AGI $AUTO_DETECT_KERN_PKG

			else

				apt-mark manual $AUTO_DETECT_KERN_PKG

			fi

		else

			G_DIETPI-NOTIFY 2 'Unable to find kernel packages for installation. Assuming non-APT/.deb kernel installation.'

		fi

		#ARMbian/others DTB
		AUTO_DETECT_DTB_PKG=$(dpkg --get-selections | grep '^linux-dtb-' | awk '{print $1}')
		if [[ -n $AUTO_DETECT_DTB_PKG ]]; then

			G_AGI $AUTO_DETECT_DTB_PKG

		fi

		#	Check for existing firmware
		#	- ARMbian
		# AUTO_DETECT_FIRMWARE_PKG=$(dpkg --get-selections | grep '^armbian-firmware' | awk '{print $1}')
		# if [[ -n $AUTO_DETECT_FIRMWARE_PKG ]]; then

			# G_AGI $AUTO_DETECT_FIRMWARE_PKG

		# fi
			# Unpacking armbian-firmware (5.35) ...
			# dpkg: error processing archive /var/cache/apt/archives/armbian-firmware_5.35_all.deb (--unpack):
			# trying to overwrite '/lib/firmware/rt2870.bin', which is also in package firmware-misc-nonfree 20161130-3
			# dpkg-deb: error: subprocess paste was killed by signal (Broken pipe)


	fi

	G_DIETPI-NOTIFY 2 "Generating list of minimal packages, required for DietPi installation:"

	INSTALL_PACKAGES=''
	for ((i=0; i<${#aPACKAGES_REQUIRED_INSTALL[@]}; i++))
	do

		#	One line INSTALL_PACKAGES so we can use it later.
		INSTALL_PACKAGES+="${aPACKAGES_REQUIRED_INSTALL[$i]} "

	done

	# - delete[]
	unset aPACKAGES_REQUIRED_INSTALL

	G_DIETPI-NOTIFY 2 "Marking required packages as manually installed:"

	G_RUN_CMD apt-mark manual $INSTALL_PACKAGES

	G_DIETPI-NOTIFY 2 "Purging APT with autoremoval:"

	G_AGA

	# Purging additional packages, that in some cases do not get autoremoved:
	# - dhcpcd5: https://github.com/Fourdee/DietPi/issues/1560#issuecomment-370136642
	G_AGP dhcpcd5


	#------------------------------------------------------------------------------------------------
	echo ''
	G_DIETPI-NOTIFY 2 '-----------------------------------------------------------------------------------'
	G_DIETPI-NOTIFY 0 "Step $SETUP_STEP: APT installations:"
	((SETUP_STEP++))
	G_DIETPI-NOTIFY 2 '-----------------------------------------------------------------------------------'
	#------------------------------------------------------------------------------------------------

	G_DIETPI-NOTIFY 2 'Upgrading existing APT installed packages:'

	G_AGDUG

	# - Distro is now target (for APT purposes and G_AGX support due to installed binary, its here, instead of after G_AGUP)
	export G_DISTRO=$DISTRO_TARGET
	export G_DISTRO_NAME="$DISTRO_TARGET_NAME"

	G_DIETPI-NOTIFY 2 'Installing core DietPi pre-req APT packages'

	G_AGI $INSTALL_PACKAGES

	G_DIETPI-NOTIFY 2 'Applying default DietPi configuration for APT'

	export G_ERROR_HANDLER_COMMAND='/etc/apt/apt.conf.d/99-dietpi-norecommends'
	cat << _EOF_ > $G_ERROR_HANDLER_COMMAND
APT::Install-Recommends "false";
APT::Install-Suggests "false";
#APT::AutoRemove::RecommendsImportant "false";
#APT::AutoRemove::SuggestsImportant "false";
_EOF_
	export G_ERROR_HANDLER_EXITCODE=$?
	G_ERROR_HANDLER

	G_DIETPI-NOTIFY 2 'Purging APT with autoremoval (in case of DISTRO upgrade/downgrade):'

	G_AGA

	# Reenable HTTPS for deb.debian.org, if system was dist-upgraded to Stretch+
	if (( $G_DISTRO > 3 && $G_HW_MODEL > 9 )); then

		sed -i 's/http:/https:/g' /etc/apt/sources.list

	fi

	#------------------------------------------------------------------------------------------------
	echo ''
	G_DIETPI-NOTIFY 2 '-----------------------------------------------------------------------------------'
	G_DIETPI-NOTIFY 0 "Step $SETUP_STEP: Prep system for DietPi ENV:"
	((SETUP_STEP++))
	G_DIETPI-NOTIFY 2 '-----------------------------------------------------------------------------------'
	#------------------------------------------------------------------------------------------------

	G_DIETPI-NOTIFY 2 'Deleting list of known users, not required by DietPi'

	userdel -f pi &> /dev/null
	userdel -f test &> /dev/null #@fourdee
	userdel -f odroid &> /dev/null
	userdel -f rock64 &> /dev/null
	userdel -f linaro &> /dev/null #ASUS TB
	userdel -f dietpi &> /dev/null #recreated below
	userdel -f debian &> /dev/null #BBB

	G_DIETPI-NOTIFY 2 'Removing misc files/folders/services, not required by DietPi'

	rm -R /home &> /dev/null
	rm -R /media &> /dev/null
	rm -R /selinux &> /dev/null

	# - www
	rm -R /var/www/* &> /dev/null

	# - sourcecode (linux-headers etc)
	rm -R /usr/src/* &> /dev/null

	# - root
	rm -R /root/.cache/* &> /dev/null
	rm -R /root/.local/* &> /dev/null
	rm -R /root/.config/* &> /dev/null

	# - documentation folders
	rm -R /usr/share/man &> /dev/null
	rm -R /usr/share/doc &> /dev/null
	rm -R /usr/share/doc-base &> /dev/null
	rm -R /usr/share/calendar &> /dev/null

	# - Previous debconfs
	rm /var/cache/debconf/*-old &> /dev/null

	# - Fonts
	rm -R /usr/share/fonts/* &> /dev/null
	rm -R /usr/share/icons/* &> /dev/null

	rm /etc/init.d/resize2fs &> /dev/null
	rm /etc/update-motd.d/* &> /dev/null # ARMbian

	systemctl disable firstrun  &> /dev/null
	rm /etc/init.d/firstrun  &> /dev/null # ARMbian

	# - Disable ARMbian's log2ram: https://github.com/Fourdee/DietPi/issues/781
	systemctl disable log2ram.service &> /dev/null
	systemctl stop log2ram.service &> /dev/null
	rm /usr/local/sbin/log2ram &> /dev/null
	rm /etc/systemd/system/log2ram.service &> /dev/null
	systemctl daemon-reload &> /dev/null
	rm /etc/cron.hourly/log2ram &> /dev/null

	# - Meveric specific
	rm /etc/init.d/cpu_governor &> /dev/null
	rm /etc/systemd/system/cpu_governor.service &> /dev/null
	rm /usr/local/sbin/setup-odroid &> /dev/null

	# - Disable ARMbian's resize service (not automatically removed by ARMbian scripts...)
	systemctl disable resize2fs &> /dev/null
	rm /etc/systemd/system/resize2fs.service &> /dev/null

	# - ARMbian-config
	rm /etc/profile.d/check_first_login_reboot.sh &> /dev/null

	# - RPi specific https://github.com/Fourdee/DietPi/issues/1631#issuecomment-373965406
	rm /etc/profile.d/wifi-country.sh &> /dev/null

	# - make_nas_processes_faster cron job on Rock64 + NanoPi + Pine64(?) images
	rm /etc/cron.d/make_nas_processes_faster &> /dev/null

	G_DIETPI-NOTIFY 2 'Creating DietPi core environment'

	G_RUN_CMD /DietPi/dietpi/func/dietpi-set_core_environment

	echo -e 'Samba client can be installed and setup by DietPi-Config.\nSimply run: dietpi-config and select the Networking option: NAS/Misc menu' > /mnt/samba/readme.txt
	echo -e 'FTP client mount can be installed and setup by DietPi-Config.\nSimply run: dietpi-config and select the Networking option: NAS/Misc menu' > /mnt/ftp_client/readme.txt
	echo -e 'NFS client can be installed and setup by DietPi-Config.\nSimply run: dietpi-config and select the Networking option: NAS/Misc menu' > /mnt/nfs_client/readme.txt

	G_DIETPI-NOTIFY 2 'Generating DietPi /etc/fstab'

	cat << _EOF_ >> /etc/fstab
#Samba Client------------------------------------------------------
#/mnt/samba . Please use dietpi-config and the Networking Options: NAS menu to setup this mount

#FTP Client Mount--------------------------------------------------
#/mnt/ftp_client . Please use dietpi-config and the Networking Options: NAS menu to setup this mount

#NFS Client Mount--------------------------------------------------
#/mnt/nfs_client . Please use dietpi-config and the Networking Options: NAS menu to setup this mount

#TMPFS / MISC ------------------------------------------------------
tmpfs 			/tmp  			tmpfs 	defaults,noatime,nodev,nosuid,mode=1777				0 0
tmpfs 			/var/log 		tmpfs 	defaults,size=${VAR_LOG_SIZE}m,noatime,nodev,nosuid,mode=1777	0 0
tmpfs 			/DietPi 		tmpfs 	defaults,size=10m,noatime,nodev,nosuid,mode=1777	0 0

#Internal Drives---------------------------------------------------
_EOF_

	#G_RUN_CMD /DietPi/dietpi/dietpi-drive_manager 4
	# Restart DietPi-RAMdisk, as 'dietpi-drive_manager 4' remounts /DietPi.
	#G_RUN_CMD systemctl restart dietpi-ramdisk

	G_DIETPI-NOTIFY 2 'Deleting all log files /var/log'

	/DietPi/dietpi/dietpi-logclear 2 &> /dev/null # As this will report missing vars, however, its fine, does not break functionality.

	G_DIETPI-NOTIFY 2 'Starting DietPi-RAMlog service'

	G_RUN_CMD systemctl start dietpi-ramlog.service

	G_DIETPI-NOTIFY 2 'Updating DietPi HW_INFO'

	/DietPi/dietpi/func/dietpi-obtain_hw_model

	G_DIETPI-NOTIFY 2 'Configuring Network:'

	rm -R /etc/network/interfaces &> /dev/null # armbian symlink for bulky network-manager

	G_RUN_CMD cp /DietPi/dietpi/conf/network_interfaces /etc/network/interfaces

	# - Remove all predefined eth*/wlan* adapter rules
	rm /etc/udev/rules.d/70-persistent-net.rules &> /dev/null
	rm /etc/udev/rules.d/70-persistant-net.rules &> /dev/null

	# - Add pre-up lines for wifi on OrangePi Zero
	if (( $G_HW_MODEL == 32 )); then

		sed -i '/iface wlan0 inet dhcp/apre-up modprobe xradio_wlan\npre-up iwconfig wlan0 power on' /etc/network/interfaces

	fi

	G_DIETPI-NOTIFY 2 'Tweaking DHCP timeout:'

	# - Reduce DHCP request retry count and timeouts: https://github.com/Fourdee/DietPi/issues/711
	sed -i '/^#timeout /d' /etc/dhcp/dhclient.conf
	sed -i '/^#retry /d' /etc/dhcp/dhclient.conf
	sed -i '/^timeout /d' /etc/dhcp/dhclient.conf
	sed -i '/^retry /d' /etc/dhcp/dhclient.conf
	cat << _EOF_ >> /etc/dhcp/dhclient.conf
timeout 10;
retry 4;
_EOF_

	G_DIETPI-NOTIFY 2 'Configuring hosts:'

	export G_ERROR_HANDLER_COMMAND='/etc/hosts'
	cat << _EOF_ > $G_ERROR_HANDLER_COMMAND
127.0.0.1    localhost
127.0.1.1    DietPi
::1          localhost ip6-localhost ip6-loopback
ff02::1      ip6-allnodes
ff02::2      ip6-allrouters
_EOF_
	export G_ERROR_HANDLER_EXITCODE=$?
	G_ERROR_HANDLER

	export G_ERROR_HANDLER_COMMAND='/etc/hostname'
	cat << _EOF_ > $G_ERROR_HANDLER_COMMAND
DietPi
_EOF_
	export G_ERROR_HANDLER_EXITCODE=$?
	G_ERROR_HANDLER

	G_DIETPI-NOTIFY 2 'Configuring htop:'

	mkdir -p /root/.config/htop
	cp /DietPi/dietpi/conf/htoprc /root/.config/htop/htoprc

	G_DIETPI-NOTIFY 2 'Configuring fakehwclock:'

	# - allow times in the past
	sed -i '/FORCE=/c\FORCE=force' /etc/default/fake-hwclock

	G_DIETPI-NOTIFY 2 'Configuring serial console:'

	/DietPi/dietpi/func/dietpi-set_hardware serialconsole enable
	# - Disable for post-1st run setup:
	sed -i '/^CONFIG_SERIAL_CONSOLE_ENABLE=/c\CONFIG_SERIAL_CONSOLE_ENABLE=0' /DietPi/dietpi.txt

	G_DIETPI-NOTIFY 2 'Reducing getty count and resource usage:'

	systemctl mask getty-static

	G_DIETPI-NOTIFY 2 'Configuring ntpd:'

	systemctl disable systemd-timesyncd
	rm /etc/init.d/ntp &> /dev/null
	(( $G_DISTRO > 4 )) && systemctl mask ntp

	G_DIETPI-NOTIFY 2 'Configuring regional settings (TZdata):'

	rm /etc/timezone &> /dev/null
	rm /etc/localtime
	ln -fs /usr/share/zoneinfo/Europe/London /etc/localtime
	G_RUN_CMD dpkg-reconfigure -f noninteractive tzdata

	G_DIETPI-NOTIFY 2 'Configuring regional settings (Keyboard):'

	dpkg-reconfigure -f noninteractive keyboard-configuration #Keyboard must be plugged in for this to work!

	#G_DIETPI-NOTIFY 2 "Configuring regional settings (Locale):"

	#Runs at start of script

	#G_HW_ARCH specific
	G_DIETPI-NOTIFY 2 'Applying G_HW_ARCH specific tweaks:'

	if (( $G_HW_ARCH == 10 )); then

		# - i386 APT support
		dpkg --add-architecture i386
		G_AGUP

		# - Disable nouveau: https://github.com/Fourdee/DietPi/issues/1244 // http://dietpi.com/phpbb/viewtopic.php?f=11&t=2462&p=9688#p9688
		cat << _EOF_ > /etc/modprobe.d/blacklist-nouveau.conf
blacklist nouveau
blacklist lbm-nouveau
options nouveau modeset=0
alias nouveau off
alias lbm-nouveau off
_EOF_
		echo 'options nouveau modeset=0' > /etc/modprobe.d/nouveau-kms.conf
		update-initramfs -u

	fi

	#G_HW_MODEL specific
	G_DIETPI-NOTIFY 2 'Appling G_HW_MODEL specific tweaks:'

	if (( $G_HW_MODEL != 20 )); then

		G_DIETPI-NOTIFY 2 'Configuring hdparm:'

		sed -i '/#DietPi/,$d' /etc/hdparm.conf #Prevent dupes
		export G_ERROR_HANDLER_COMMAND='/etc/hdparm.conf'
		cat << _EOF_ >> $G_ERROR_HANDLER_COMMAND

#DietPi external USB drive. Power management settings.
/dev/sda {
        #10 mins
        spindown_time = 120

        #
        apm = 254
}
_EOF_
		export G_ERROR_HANDLER_EXITCODE=$?
		G_ERROR_HANDLER

	fi

	# - ARMbian OPi Zero 2: https://github.com/Fourdee/DietPi/issues/876#issuecomment-294350580
	if (( $G_HW_MODEL == 35 )); then

		echo 'blacklist bmp085' > /etc/modprobe.d/bmp085.conf

	# - Sparky SBC ONLY:
	elif (( $G_HW_MODEL == 70 )); then

		# 	Install latest kernel
		wget https://raw.githubusercontent.com/sparky-sbc/sparky-test/master/dragon_fly_check/uImage -O /boot/uImage
		wget https://raw.githubusercontent.com/sparky-sbc/sparky-test/master/dragon_fly_check/3.10.38.bz2 -O package.tar
		tar xvf package.tar -C /lib/modules/
		rm package.tar

		#	patches
		G_RUN_CMD wget https://raw.githubusercontent.com/sparky-sbc/sparky-test/master/dsd-marantz/snd-usb-audio.ko -O /lib/modules/3.10.38/kernel/sound/usb/snd-usb-audio.ko
		G_RUN_CMD wget https://raw.githubusercontent.com/sparky-sbc/sparky-test/master/dsd-marantz/snd-usbmidi-lib.ko -O /lib/modules/3.10.38/kernel/sound/usb/snd-usbmidi-lib.ko

		cat << _EOF_ > /DietPi/uEnv.txt
uenvcmd=setenv os_type linux;
bootargs=earlyprintk clk_ignore_unused selinux=0 scandelay console=tty0 loglevel=1 real_rootflag=rw root=/dev/mmcblk0p2 rootwait init=/lib/systemd/systemd aotg.urb_fix=1 aotg.aotg1_speed=0
_EOF_

		cp /DietPi/uEnv.txt /boot/uenv.txt #temp solution

		#	Blacklist GPU and touch screen modules: https://github.com/Fourdee/DietPi/issues/699#issuecomment-271362441
		cat << _EOF_ > /etc/modprobe.d/disable_sparkysbc_touchscreen.conf
blacklist owl_camera
blacklist gsensor_stk8313
blacklist ctp_ft5x06
blacklist ctp_gsl3680
blacklist gsensor_bma222
blacklist gsensor_mir3da
_EOF_

		cat << _EOF_ > /etc/modprobe.d/disable_sparkysbc_gpu.conf
blacklist pvrsrvkm
blacklist drm
blacklist videobuf2_vmalloc
blacklist bc_example
_EOF_

		#	Use performance gov for stability.
		sed -i '/^[[:blank:]]*CONFIG_CPU_GOVERNOR=/c\CONFIG_CPU_GOVERNOR=performance' /DietPi/dietpi.txt

	# - RPI:
	elif (( $G_HW_MODEL < 10 )); then

		# - Scroll lock fix for RPi by Midwan: https://github.com/Fourdee/DietPi/issues/474#issuecomment-243215674
		cat << _EOF_ > /etc/udev/rules.d/50-leds.rules
ACTION=="add", SUBSYSTEM=="leds", ENV{DEVPATH}=="*/input*::scrolllock", ATTR{trigger}="kbd-scrollock"
_EOF_

	# - PINE64 (and possibily others): Cursor fix for FB
	elif (( $G_HW_MODEL == 40 )); then

		cat << _EOF_ >> "$HOME"/.bashrc
infocmp > terminfo.txt
sed -i -e 's/?0c/?112c/g' -e 's/?8c/?48;0;64c/g' terminfo.txt
tic terminfo.txt
tput cnorm
_EOF_

	# - Odroids FFMPEG fix. Prefer debian.org over Meveric for backports: https://github.com/Fourdee/DietPi/issues/1273 + https://github.com/Fourdee/DietPi/issues/1556#issuecomment-369463910
	elif (( $G_HW_MODEL > 9 && $G_HW_MODEL < 15 )); then

		rm /etc/apt/preferences.d/meveric*
		cat << _EOF_ > /etc/apt/preferences.d/backports
Package: *
Pin: release a=jessie-backports
Pin: origin "fuzon.co.uk"
Pin-Priority: 99

Package: *
Pin: release a=jessie-backports
Pin: origin "oph.mdrjr.net"
Pin-Priority: 99
_EOF_

	fi

	# - ARMbian increase console verbose
	sed -i '/verbosity=/c\verbosity=7' /boot/armbianEnv.txt &> /dev/null


	#------------------------------------------------------------------------------------------------
	echo ''
	G_DIETPI-NOTIFY 2 '-----------------------------------------------------------------------------------'
	G_DIETPI-NOTIFY 0 "Step $SETUP_STEP: Finalise system for first run of DietPi:"
	((SETUP_STEP++))
	G_DIETPI-NOTIFY 2 '-----------------------------------------------------------------------------------'
	#------------------------------------------------------------------------------------------------

	G_DIETPI-NOTIFY 2 'Configuring Dropbear:'

	#	set to start on next boot
	sed -i '/NO_START=1/c\NO_START=0' /etc/default/dropbear

	G_DIETPI-NOTIFY 2 'Configuring Services'

	/DietPi/dietpi/dietpi-services stop
	/DietPi/dietpi/dietpi-services dietpi_controlled

	G_DIETPI-NOTIFY 2 'Running general cleanup of misc files'

	# - Remove Bash History file
	rm ~/.bash_history &> /dev/null

	# - Nano histroy file
	rm ~/.nano_history &> /dev/null

	G_DIETPI-NOTIFY 2 'Removing swapfile from image'

	#/DietPi/dietpi/func/dietpi-set_dphys-swapfile 0 /var/swap
	rm /var/swap &> /dev/null # still exists on some images...

	# - re-enable for next run
	sed -i '/AUTO_SETUP_SWAPFILE_SIZE=/c\AUTO_SETUP_SWAPFILE_SIZE=1' /DietPi/dietpi.txt

	G_DIETPI-NOTIFY 2 'Resetting boot.ini, config.txt, cmdline.txt etc'

	# - PineA64 - delete ethaddr from uEnv.txt file
	if (( $G_HW_MODEL == 40 )); then

		sed -i '/^ethaddr/ d' /boot/uEnv.txt

	fi

	# - Set Pi cmdline.txt back to normal
	[[ -f /boot/cmdline.txt ]] && sed -i 's/ rootdelay=10//g' /boot/cmdline.txt

	G_DIETPI-NOTIFY 2 'Generating default wpa_supplicant.conf'

	/DietPi/dietpi/func/dietpi-set_hardware wificreds set

	G_DIETPI-NOTIFY 2 'Disabling generic WiFi/BT by default'

	/DietPi/dietpi/func/dietpi-set_hardware bluetooth disable
	/DietPi/dietpi/func/dietpi-set_hardware wifimodules disable

	G_DIETPI-NOTIFY 2 'Enabling onboard WiFi modules by default'

	/DietPi/dietpi/func/dietpi-set_hardware wifimodules onboard_enable

	#G_DIETPI-NOTIFY 2 'Configuring IP version preferences'

	#/DietPi/dietpi/func/dietpi-set_hardware preferipversion ipv4 #Already done at top of script, and now default in dietpi.txt

	G_DIETPI-NOTIFY 2 'Disabling soundcards by default'

	/DietPi/dietpi/func/dietpi-set_hardware soundcard none
	#	Alsa-utils is auto installed to reset soundcard settings on some ARM devices. uninstall it afterwards
	#	- The same for firmware-intel-sound (sound over HDMI?) on intel CPU devices
	G_AGP alsa-utils firmware-intel-sound
	G_AGA

	G_DIETPI-NOTIFY 2 'Setting default CPU gov'

	/DietPi/dietpi/func/dietpi-set_cpu

	G_DIETPI-NOTIFY 2 'Clearing log files'

	/DietPi/dietpi/dietpi-logclear 2

	G_DIETPI-NOTIFY 2 'Deleting DietPi-RAMlog storage'

	rm -R /var/lib/dietpi/dietpi-ramlog/storage/* &> /dev/null

	G_DIETPI-NOTIFY 2 'Deleting NTP drift file'

	rm /var/lib/ntp/ntp.drift &> /dev/null

	G_DIETPI-NOTIFY 2 'Resetting DietPi generated globals/files'

	rm /DietPi/dietpi/.??*

	G_DIETPI-NOTIFY 2 'Setting DietPi-Autostart to console'

	echo 0 > /DietPi/dietpi/.dietpi-autostart_index

	G_DIETPI-NOTIFY 2 'Creating our update file (used on 1st run to check for DietPi updates)'

	echo -1 > /DietPi/dietpi/.update_stage

	G_DIETPI-NOTIFY 2 'Set Init .install_stage to -1 (first boot)'

	echo -1 > /DietPi/dietpi/.install_stage

	G_DIETPI-NOTIFY 2 'Writing PREP information to file'

	cat << _EOF_ > /DietPi/dietpi/.prep_info
$IMAGE_CREATOR
$PREIMAGE_INFO
_EOF_

	G_DIETPI-NOTIFY 2 'Remove server_version / patch_file (downloads fresh from dietpi-update)'

	rm /DietPi/dietpi/patch_file &> /dev/null
	rm /DietPi/dietpi/server_version* &> /dev/null

	G_DIETPI-NOTIFY 2 'Clearing APT cache'

	G_RUN_CMD apt-get clean
	rm -R /var/lib/apt/lists/* -vf #lists cache: remove partial folder also, automatically gets regenerated on G_AGUP
	#rm /var/lib/dpkg/info/* #issue...
	#dpkg: warning: files list file for package 'libdbus-1-3:armhf' missing; assuming      package has no files currently installed

	# - HW Specific
	#	RPi remove saved G_HW_MODEL , allowing obtain-hw_model to auto detect RPi model
	if (( $G_HW_MODEL < 10 )); then

		rm /etc/.dietpi_hw_model_identifier

	fi

	G_DIETPI-NOTIFY 2 'Generating dietpi-fs_partition_resize for first boot'

	cat << _EOF_ > /etc/systemd/system/dietpi-fs_partition_resize.service
[Unit]
Description=dietpi-fs_partition_resize
Before=dietpi-ramdisk.service

[Service]
Type=oneshot
RemainAfterExit=no
ExecStart=/bin/bash -c '/var/lib/dietpi/fs_partition_resize.sh | tee /var/tmp/dietpi/logs/fs_partition_resize.log'
StandardOutput=tty

[Install]
WantedBy=local-fs.target
_EOF_
	systemctl daemon-reload
	G_RUN_CMD systemctl enable dietpi-fs_partition_resize.service

	cat << _EOF_ > /var/lib/dietpi/fs_partition_resize.sh
#!/bin/bash

systemctl disable dietpi-fs_partition_resize.service
systemctl daemon-reload

sync

TARGET_PARTITION=0
TARGET_DEV=\$(findmnt / -o source -n)

# - MMCBLK[0-9]p[0-9] scrape
if [[ "\$TARGET_DEV" = *"mmcblk"* ]]; then

    TARGET_DEV=\$(findmnt / -o source -n | sed 's/p[0-9]\$//')
	TARGET_PARTITION=\$(findmnt / -o source -n | sed 's/.*p//')

# - Everything else scrape (eg: /dev/sdX[0-9])
else

    TARGET_DEV=\$(findmnt / -o source -n | sed 's/[0-9]\$//')
	TARGET_PARTITION=\$(findmnt / -o source -n | sed 's|/dev/sd.||')

fi

#Rock64 GPT resize | modified version of ayufan-rock64 resize script. I take no credit for this.
if [[ -f /etc/.dietpi_hw_model_identifier ]] && (( \$(cat /etc/.dietpi_hw_model_identifier) == 43 )); then

    gdisk \$TARGET_DEV << _EOF_1
x
e
m
d
\$TARGET_PARTITION
n
\$TARGET_PARTITION


8300
c
\$TARGET_PARTITION
root
w
Y
_EOF_1

#Everything else
else

    cat << _EOF_1 | fdisk \$TARGET_DEV
p
d
\$TARGET_PARTITION
n
p
\$TARGET_PARTITION
\$(parted \$TARGET_DEV -ms unit s p | grep ':ext4::;' | sed 's/:/ /g' | sed 's/s//g' | awk '{ print \$2 }')

p
w

_EOF_1

fi

partprobe \$TARGET_DEV

resize2fs \${TARGET_DEV}p\$TARGET_PARTITION

_EOF_
	G_RUN_CMD chmod +x /var/lib/dietpi/fs_partition_resize.sh


	# - BBB remove fsexpansion: https://github.com/Fourdee/DietPi/issues/931#issuecomment-345451529
	if (( $G_HW_MODEL == 71 )); then

		rm /var/lib/dietpi/fs_partition_resize.sh
		rm /etc/systemd/system/dietpi-fs_partition_resize.service
		systemctl daemon-reload

	fi

	G_DIETPI-NOTIFY 2 'Storing DietPi version ID'

	G_RUN_CMD wget https://raw.githubusercontent.com/Fourdee/DietPi/$GIT_BRANCH/dietpi/.version -O /DietPi/dietpi/.version

	#	reduce sub_version by 1, allows us to create image, prior to release and patch if needed.
	CORE_VERSION=$(sed -n 1p /DietPi/dietpi/.version)
	SUB_VERSION=$(sed -n 2p /DietPi/dietpi/.version)
	((SUB_VERSION--))
	cat << _EOF_ > /DietPi/dietpi/.version
$CORE_VERSION
$SUB_VERSION
_EOF_

	G_RUN_CMD cp /DietPi/dietpi/.version /var/lib/dietpi/.dietpi_image_version

	# - Native PC/EFI (assume x86_64 only possible)
	if dpkg --get-selections | grep -qi '^grub-efi-amd64[[:space:]]' &&
		[[ -d /boot/efi ]]; then

		G_DIETPI-NOTIFY 2 'Recreating GRUB-EFI'

		G_RUN_CMD grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=arch_grub --recheck

	fi

	G_DIETPI-NOTIFY 2 'Sync changes to disk. Please wait, this may take some time...'

	G_RUN_CMD systemctl stop dietpi-ramlog
	#G_RUN_CMD systemctl stop dietpi-ramdisk
	/boot/dietpi/dietpi-ramdisk 1

	# - Clear tmp files
	rm -R /tmp/* &> /dev/null
	rm /var/tmp/dietpi/logs/* &> /dev/null

	sync

	G_DIETPI-NOTIFY 2 "The used kernel version is: $(uname -r)"
	kernel_apt_packages="$(dpkg --get-selections | grep '^linux-image-[0-9]')"
	if [[ -n $kernel_apt_packages ]]; then

		G_DIETPI-NOTIFY 2 'The following kernel APT packages have been found, please purge the outdated ones:'
		echo "$kernel_apt_packages"

	fi

	G_DIETPI-NOTIFY 2 'Please check and delete all non-required folders in /root/.xxxxxx'
	G_DIETPI-NOTIFY 2 'Please delete outdated non-APT kernel modules:'
	ls -lha /lib/modules

	G_DIETPI-NOTIFY 0 'Completed, disk can now be saved to .img for later use, or, reboot system to start first run of DietPi:'

	# - Remove PREP files
	rm dietpi-globals
	rm PREP_SYSTEM_FOR_DIETPI.sh

	#Power off system

	#Read image

	#Resize rootfs parition to mininum size +50MB

}
