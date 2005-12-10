# dyne:II startup scripts
# (C) 2005 Denis "jaromil" Rojo
# GNU GPL License

source /lib/dyne/utils.sh

add_volume() {
  # $1 = media type (hdisk|floppy|usb|cdrom)
  # $2 = device
  # $3 = mount point
  # $4 = filesystem

  MEDIA=${1}
  DEV=${2}
  MNT=${3}
  FS=${4}

  if [ ! -r /boot/volumes ]; then touch /boot/volumes; fi

  FLAGS=""
  DOCK=dyne

  PFX=/mnt
  mkdir -p ${PFX}/${MNT}

  PASS=2
  # check for a dock
  if [ -x ${PFX}/${MNT}/${DOCK} ]; then
      if [ -r ${PFX}/${MNT}/${DOCK}/dyne.sys ]; then FLAGS="$FLAGS sys"; fi
      if [ -r ${PFX}/${MNT}/${DOCK}/dyne.nst ]; then FLAGS="$FLAGS nst"; fi
      if [ -r ${PFX}/${MNT}/${DOCK}/dyne.cfg ]; then FLAGS="$FLAGS cfg"; fi
      if [ -x ${PFX}/${MNT}/${DOCK}/SDK ];      then FLAGS="$FLAGS sdk"; fi
  fi
  if [ $FLAGS ]; then PASS=1; fi # check filesystem if sys|nst|cfg|sdk

  case ${MEDIA} in

      "hdisk")

          # here check if FS ~= NTFS then use umask=0222
	  if [ "`echo '${FS}' | grep -i 'NTFS'`" ]; then
	    OPTIONS="defaults,umask=0222"
	    FILESYS="ntfs"

          # and here check if FS ~= bsd44
	  elif [ "`echo '${FS}'|grep -iE 'BSD|ufs'`" ]; then
	    OPTIONS="ufstype=44bsd"
	    FILESYS="ufs"

	  else
	    OPTIONS="defaults"
	    FILESYS="auto"
	  fi
            
	  append_line /boot/volumes "${MEDIA} /dev/${DEV} ${PFX}/${MNT} ${FILESYS} ${FLAGS}"
	  append_line /etc/fstab "/dev/${DEV}\t${PFX}/${MNT}\t${FILESYS}\t${OPTIONS}\t0\t${PASS}"
	  ;;


# floppy, usb and cdrom are mounted in /rem
      
      "floppy")
	  append_line /boot/volumes "${MEDIA} /dev/${DEV} ${PFX}/${MNT} ${FS}"
	  append_line /etc/fstab "/dev/${DEV}\t${PFX}/${MNT}\tauto\tdefaults,user\t0\t0"
	  ;;
     
 
      "usb")
	  append_line /boot/volumes "${MEDIA} /dev/${DEV} ${PFX}/${MNT} ${FS} ${FLAGS}"
	  append_line /etc/fstab "/dev/${DEV}\t${PFX}/${MNT}\t${FS}\tdefaults,user\t0\t${PASS}"
	  ;;

      
      "cdrom"|"dvd")
	  append_line /boot/volumes "${MEDIA} /dev/${DEV} ${PFX}/${MNT} ${FS} ${FLAGS}"
	  append_line /etc/fstab \
          "/dev/${DEV}\t${PFX}/${MNT}\tauto\tdefaults,user,ro\t0\t0"
	  ;;
      

      *)
	  error "unknown media type ${MEDIA} for add_volume"
	  return 1
	  ;;
  esac
  
  act "${MEDIA} volume on ${PFX}/${MNT}"
  
  return 0
}


###### CDROM

CD_NUM=0
DVD_NUM=0

SYS_CD_FOUND=false
scan_cdrom() {

# CD filesystem is iso9660 unless we have a DVD (on xbox, for example)
    if [ "`uname -a | grep xbox`" ]; then
	act "xbox dvd filesystem: udf"
	CDFS="udf"
    else
	act "ide cdrom filesystem: auto"
	CDFS="auto"
    fi
    

    # scan for ide devices
    for DEVPATH in `ls /proc/ide | awk '/^hd.*/ {print $1}'`; do

        DEV=`basename ${DEVPATH}`

	# if it's not a cdrom then skip it
	# TODO: verify if DVD has a "dvd" entry for media type
	if  [ `cat /proc/ide/$DEV/media` != cdrom ]; then continue; fi

	if [ "`dmesg|grep '$DEV.*DVD'`" ]; then 
	    MEDIA=dvd
	    DVD_NUM=`expr $DVD_NUM + 1`
	    MNT=dvd${DVD_NUM}
	else
	    MEDIA=cdrom
	    CD_NUM=`expr $CD_NUM + 1`
	    MNT=cd${CD_NUM}
	fi
	
	act "scanning ${DEV} -> ${MNT} (${CDFS})"
	
	mkdir -p /mnt/dynecd

	mount -t ${CDFS} -o ro /dev/${DEV} /mnt/dynecd 2>/dev/null 1>/dev/null

	if [ $? != 0 ]; then # device was not mounted

	# media is not found inside, delete dir
	# and add the CD as automount device
	    rm -r /mnt/dynecd
	    add_volume ${MEDIA} ${DEV} ${MNT} ${CDFS}

	elif [ -r /mnt/dynecd/dyne/dyne.sys ]; then # device contains dyne sys
	    
	    FLAGS=sys # check if it has also a config file
	    if [ -r /mnt/dynecd/dyne/dyne.cfg ]; then
		FLAGS="$FLAGS cfg"
	    fi
	    
            # leave it mounted and add it to the list of volumes
	    append_line /boot/volumes "${MEDIA} /dev/${DEV} /mnt/dynecd ${CDFS} ${FLAGS}"
	    
	else # device has a CD inside, not the dyne one

	    # unmount it and add it to automount devices
	    umount /mnt/dynecd
	    rm -r /mnt/dynecd
	    add_volume ${MEDIA} ${DEV} ${MNT} ${CDFS}

	fi
	    	
    done
}


###### HARDDISK

scan_partitions() { #arg : devicename
    # scans a list of fdisk format partitions
    PART_NUM=0
    DEV=`basename $1`

    # check which fdisk to use
    FDISK=fdisk
    if [ "`${FDISK} -l /dev/${DEV} 2>&1| \
           grep -i 'doesn.t contain a valid partition table'`" ]; then
      # try mac
      FDISK=fdisk-pmac
      if [ "`${FDISK} -l /dev/${DEV} 2>&1| \
             grep -i 'doesn.t contain a valid partition table'`" ]; then
        error "can't parse partition table of drive ${DEV}"
        return
      fi
    fi

    PARTITIONS=`${FDISK} -l /dev/${DEV}            \
              | sed -e 's/ \* / /'              \
              | awk '/^\/dev\/*/ { if(NF!=1) print $0 }' \
              | grep -Evi 'extended|swap|partition.map|free.space'`
    
        # cycle thru partitions
        # ${(f)..} splits the result of the expansion to lines. see: man zshexpn
    for PART in ${(f)PARTITIONS}; do
	
	
	PART_FS="`echo $PART|awk '{print $6}'`"
        PART_DEV="`echo $PART|cut -d' ' -f1`"
	
	PART_NUM=`expr $PART_NUM + 1`
	
	
        # skip it if already mounted as root (partition install)
        if [ "$ROOT_PART" = "$PART_DEV" ]; then
	    
	    act "$PART_FS partition $PART_DEV already mounted as root"
	    continue
	    
        fi 

	MNT="/mnt/hd${HD_NUM}/${PART_NUM}"
	mkdir -p ${MNT}

	# mount the partition only if not already mounted
	if [ `is_mounted ${PART_DEV}` = true ]; then

          act "skipping partition ${PART_DEV}: already mounted"

        else

          act "mounting ${PART_FS} partition ${PART_DEV}"

          # starts a check on linux ext* filesystems
          if [ "`echo $PART|grep -iE 'linux'`" ]; then
            notice "linux filesytem check"
            # man fsck says this should safely work
            fsck -TCp ${PART_DEV}
          fi  

	    
          mount ${MOUNT_FS} ${MOUNT_OPTS} ${PART_DEV} ${MNT}
	    
          if [ $? != 0 ]; then
	    error "can't mount ${PART_DEV} : not a valid filesystem"
	    PART_NUM=`expr $PART_NUM - 1`
	    continue
	  fi

	  PART_DEV=`basename $PART_DEV`
	
	  add_volume hdisk ${PART_DEV} hd${HD_NUM}/${PART_NUM} ${PART_FS}

        fi

    done
    
}

HD_NUM=0
scan_storage() {
# $1 = device, without partition number (es: hda)
#  DEV=$1

    ROOT_PART="`get_config root | grep -E 'dev.(hd|sd)'`"

	
    # load all kernel modules for supported filesystems
    # refer to SUPPORTED_FS defined in utils.sh
    # all unused modules will be removed at the end of this function
    act "load modules to scan supported filesystems"
    for m in `iterate $SUPPORTED_FS`; do
	loadmod ${m}
    done



    #######################
    #### scan IDE harddisks
    #######################
    for DEVPATH in `ls /proc/ide | awk '/^hd.*/ {print $1}'`; do

        DEV=`basename ${DEVPATH}`

        # skip if not an harddisk
	if  [ `cat /proc/ide/$DEV/media` != disk ]; then continue; fi

	HD_NUM=`expr $HD_NUM + 1`

	MOUNT_OPTS=""
	MOUNT_FS=""

	if [ "`uname -a | grep xbox`" ]; then
	    MOUNT_FS="-t fatx"
	    MOUNT_OPTS="-o umask=777"
	fi

        notice "scanning harddisk ${DEV}"
        act "activating DMA channel and 32bit IO"
        hdparm -d1 -c1 /dev/${DEV}        

	# IDE partitions
	scan_partitions ${DEV}

    done



    ########################
    #### scan SCSI harddisks
    ########################
    for DEV in `ls /dev | awk '/^sd./ {print $1}'`; do
       # TODO: be sure to detect it's an harddisk
       HD_NUM=`expr $HD_NUM + 1`
       scan_partitions ${DEV}
    done
	
    


    # now remove all unused filesystem kernel modules
    act "cleanup unused filesystem modules"
    USEDFS=`mount | awk '{print $5}'`
    for fs in `iterate_backwards $SUPPORTED_FS`; do
	if [ -z "`echo ${USEDFS} | grep ${fs}`" ]; then
		rmmod ${fs}
	fi
    done
}

scan_removable() {

  act "checking for a floppy driver"
  if [ "`dmesg |grep ' fd0 '`" ]; then
    add_volume floppy fd0 floppy auto
  fi

  act "checking for a usb plug"
  if [ "`dmesg | grep 'USB hub found'`" ]; then
    for DEV in `ls /dev | awk '/^sd./ {print $1}'`; do
      # now find out the last sd? device
    done
    if [ -z $DEV ]; then # no scsi/sata fixed disc, pick the first
      add_volume usb sda usb vfat
    else
      USB=`alphabet ${DEV[3]} next`
      add_volume usb "sd${USB}1" usb vfat
    fi
  fi

}

# this function is called by the cdrom detection when a system is found on CD
# it goes thru the harddisks detected and check if they have a system
# match versions and ask user what to do if they are different
# (use cd | hd | update hd)
# setup DYNE_SYS_* variables in order to have the system mounted at the end
# of this script
#
# flowchart attempt:
#
# - check all HD, find system and schedule usage in $DYNE_SYS*
# - check all CD, check system version against all HD, query update
#                 if $DYNE_SYS* is not present, set $DYNE_SYS* to CD
#                 if $DYNE_SYS* is present, ask CD or HD

choose_volumes() {

    # count the harddisk
    HDSYS=`cat /boot/volumes|grep -E 'hdisk.*(sys|sdk)'`
    HDSYS_NUM=0

    for v in ${(f)HDSYS}; do
	# volumes syntax: media device mount filesystem
	#        we want:       ^^^^^^ ^^^^^ ^^ TODO ^^ have fsys displayed at choice
	DEV="`echo $v|awk '{print $2}'`"
	MNT="`echo $v|awk '{print $3}'`"

	# if the /mntpoint/dyne/VERSION is there, source it
	if [ -r ${MNT}/dyne/VERSION ]; then
	    # get versions:
	    # DYNE_SYS_VER
	    # DYNE_INITRD_VER
	    source ${MNT}/dyne/VERSION
	fi

	if [ ! -r /boot/hdsyslist ]; then touch /boot/hdsyslist; fi
	# dev mnt sys_ver init_ver
	echo "$DEV $MNT $DYNE_SYS_VER $DYNE_INITRD_VER" >> /boot/hdsyslist
	HDSYS_NUM=`expr $HDSYS_NUM + 1`
    done
    
    # get the first cdrom
    CDSYS="`cat /boot/volumes|grep -E 'cdrom.*sys'`"
    C=0
    for v in ${(f)CDSYS}; do
	C=`expr $C + 1`

	if [ $C != 1 ]; then
	    warning "multiple system cdroms were detected"
	    warning "using: $v"
	else
	    CD=${v} # get only the first
	fi
    done
    

    if [ $HDSYS_NUM = 0 ]; then # no docks ...

	if [ -z $CD ]; then # no cd
	    
	    error "no device containing the dyne:bolic system was detected"
	    return
	    
	else # cd found
	    
	    DYNE_SYS_MEDIA=cdrom
	    DYNE_SYS_DEV="`echo $CD|awk '{print $2}'`"
	    DYNE_SYS_MNT="`echo $CD|awk '{print $3}'`/dyne"
	    return

	fi

    elif [ $HDSYS_NUM = 1 ]; then # ***** ... there is one dock
	
	if [ $CD ]; then # and there is a cdrom

	    MNT="`echo $CD|awk '{print $3}'`"
	    source ${MNT}/dyne/VERSION

	    # check if version differs between cd and hdisk
	    # hdsyslist format: dev mnt sys_ver init_ver
	    HD_SYS_VER="`cat /boot/hdsyslist|awk '{print $3}'`"
	    HD_INIT_VER="`cat /boot/hdsyslist| awk '{print $4}'`"
	    if [ "$DYNE_SYS_VER" != "$HD_SYS_VER" ]; then ask_update=true; fi
	    if [ "$DYNE_INITRD_VER" != "$HD_INIT_VER" ]; then ask_update=true; fi

	    echo; echo; echo; echo; echo;
	    # prompt if upgrading from cd is desired
	    if [ x$ask_update = xtrue ]; then
		notice "the dyne:bolic system on your harddisk is different from the CDROM"
		act "CDROM\t:: sys $DYNE_SYS_VER\t:: init $DYNE_INITRD_VER"
		act "HDISK\t:: sys $HD_SYS_VER\t:: init $HD_INITRD_VER"
		echo "[?] do you want to upgrade the system on your harddisk? (y/n)"
		echo; echo; echo; echo; echo;
		ask_yesno 10 y n
		if [ $? = 1 ]; then
		    notice "upgrading harddisk system version to $DYNE_SYS_VER"
		    act "please wait while transferring files..."
		    echo; echo; echo;	    
		    HD_MNT="`cat /boot/hdsyslist|awk '{print $2}'`"
		    cp -rf ${MNT}/dyne ${HD_MNT}
		    act "done!"
		    echo; echo; echo; echo; echo;
		else
		    act "Nothing to upgrade."
		fi
	    fi

	    echo; echo; echo; echo; echo;
            # prompt if boot from cdrom or harddisk
            echo "[?] do you want to boot from the system on your harddisk? (Y/n)"
	    echo; echo; echo; echo; echo;
            ask_yesno 10
            if [ $? != 0 ]; then

	      DYNE_SYS_MEDIA=hdisk
	      DYNE_SYS_DEV="`cat /boot/hdsyslist|awk '{print $1}'`"
	      DYNE_SYS_MNT="`cat /boot/hdsyslist|awk '{print $2}'`/dyne"
	      source ${DYNE_SYS_MNT}/VERSION
	      notice "mounting the harddisk docked system on $DYNE_SYS_MNT"
	      return

            else # boot from cd
	    
	      DYNE_SYS_MEDIA=cdrom
	      DYNE_SYS_DEV="`echo $CD|awk '{print $2}'`"
	      DYNE_SYS_MNT="`echo $CD|awk '{print $3}'`/dyne"
              source ${DYNE_SYS_MNT}/VERSION
              notice "mounting the cdrom system on $DYNE_SYS_MNT"
	      return

            fi

	else # and there is no cdrom

	    DYNE_SYS_MEDIA=hdisk
	    DYNE_SYS_DEV="`cat /boot/hdsyslist|awk '{print $1}'`"
	    DYNE_SYS_MNT="`cat /boot/hdsyslist|awk '{print $2}'`/dyne"
	    source ${DYNE_SYS_MNT}/VERSION
	    notice "mounting the harddisk docked system on $DYNE_SYS_MNT"
	    return
	    
	fi

    else # ... there is more than one dock

	if [ $CD ]; then # and there is a cdrom

	    
	    MNT="`echo $CD|awk '{print $3}'`"
	    source ${MNT}/dyne/VERSION

	    notice "booting from CDROM system version $DYNE_SYS_VER"
	    act "multiple systems have been detected, choose one to upgrade"
	    C=0
	    for i in `cat /boot/hdsyslist`; do
		C=`expr $C + 1`
		DEV=`echo $i| awk '{print $1}'`
		MNT=`echo $i| awk '{print $2}'`
		SYS_VER=`echo $i| awk '{print $3}'`
		echo "$C - $DEV mounted on $MNT\t:: sys $VER"
	    done
	    echo "[?] choose one or wait 10 seconds"
	    ask_choice 10 ${C}
	    if [ $? != -1 ]; then
		HD_MNT="`cat /boot/hdsyslist | awk -v line=$? 'NR==line {print $2}'`"
		act "TODO: here should cp -rfv ${MNT}/dyne ${HD_MNT}"
	    fi
	    
	# dev mnt sys_ver init_ver
	    if [ "$DYNE_SYS_VER" != "`cat /boot/hdsyslist|awk '{print $3}'`" ]; then
		ask_update=true; fi
	    if [ "$DYNE_INITRD_VER" != "`cat /boot/hdsyslist|awk '{print $4}'`" ]; then
		ask_update=true; fi
	    
	    # prompt if upgrading from cd is desired
	    if [ x$ask_update = xtrue ]; then
		# QUAAAA
		ask_yesno
	    fi
	

	else # there is not a cdrom

	    # offer a multiple choice of the boot from /boot/hdsyslist
	    notice "multiple dyne:bolic systems have been detected on your harddisks"
	    act "choose the one you want to run (first is default after 10 seconds):"
	    C=0
            HDSYSLIST=`cat /boot/hdsyslist`
	    for i in ${(f)HDSYSLIST}; do
		C=`expr $C + 1`
		DEV=`echo $i| awk '{print $1}'`
		MNT=`echo $i| awk '{print $2}'`
		SYS_VER=`echo $i| awk '{print $3}'`
		echo "$C - $DEV mounted on $MNT\t:: sys $VER"
	    done

	    echo "TODO"


	fi

    fi
}


# TODO: sys_list che lista tutti i sistemi e fa scegliere con ask_choice
