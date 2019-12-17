#!/usr/bin/env bash
#set -x

BUILD_SCRIPT_VERSION="1.8.46"
BUILD_SCRIPT_NAME=`basename ${0}`

BUILD_BRANCH="yoe/mut"
# These are used by in following functions, declare them here so that
# they are defined even when we're only sourcing this script
BUILD_TIME_STR="TIME: ${BUILD_SCRIPT_NAME}-${BUILD_SCRIPT_VERSION} %e %S %U %P %c %w %R %F %M %x %C"

BUILD_TIMESTAMP_START=`date -u +%s`
BUILD_TIMESTAMP_OLD=${BUILD_TIMESTAMP_START}

umask 0022

export PATH=/usr/local/bin:$PATH:/usr/sbin

# use Pre-Built buildtools Tarball ( currently 3.0 is latest, update it on trusty1 when next release happens)
BUILDTOOLS=/opt/poky/3.0/environment-setup-x86_64-pokysdk-linux

test -e ${BUILDTOOLS} && . ${BUILDTOOLS}

buildit() {
#       echo $1 $2 $3 $4
        local myret=$1
        start_time=`date +%s`
        MACHINE=$2 bitbake $3 $4
        eval $myret="'$?'"
        end_time=`date +%s`
        echo execution time was `expr $end_time - $start_time` s.
}

cleanup_builddir() {
        rm -rf /opt/sstate-cache/*
}

kill_stalled_bitbake_processes() {
    if ps aux | grep "bitbake/bin/[b]itbake" ; then
        local BITBAKE_PIDS=`ps aux | grep "bitbake/bin/[b]itbake" | awk '{print $2}' | xargs`
        [ -n "${BITBAKE_PIDS}" ] && kill ${BITBAKE_PIDS}
        sleep 10
        ps aux | grep "bitbake/bin/[b]itbake"
        local BITBAKE_PIDS=`ps aux | grep "bitbake/bin/[b]itbake" | awk '{print $2}' | xargs`
        [ -n "${BITBAKE_PIDS}" ] && kill -9 ${BITBAKE_PIDS}
        ps aux | grep "bitbake/bin/[b]itbake" || true
    fi
}

git config --global user.email "ab@rdk"
git config --global user.name "Auto Builder"

if [ ! -e ${HOME}/.oe-send-error ]
then
        echo `git config --get user.name` > ${HOME}/.oe-send-error
        echo `git config --get user.email` >> ${HOME}/.oe-send-error
fi

if [ "${CLEANBUILD}" = "true" ]
then
	echo "Deleting shared state ..."
    cleanup_builddir
fi

cat <<EOF > ${WORKSPACE}/local.sh
export MACHINE=${MACHINE-qemumips}
export DOCKER_REPO="none"
EOF

. ${WORKSPACE}/${MACHINE-qemumips}-envsetup.sh

find .git -name "index.lock" -delete

kill_stalled_bitbake_processes

git fetch --all
yoe_setup
git checkout ${BRANCH}
yoe_update_all

cat <<EOF > ${WORKSPACE}/conf/local.conf

TOOLCHAIN = "clang"

INHERIT += "testimage"
INHERIT += "rm_work"
INHERIT += "reproducible_build_simple"
INHERIT += "report-error"
INHERIT += "buildstats buildstats-summary"

DL_DIR = "/opt/world/downloads/"
SSTATE_DIR = "/opt/sstate-cache/"


ACCEPT_FSL_EULA = "1"

# For kernel-selftest with linux 4.18+
HOSTTOOLS += "clang llc"

DISTRO_FEATURES_append = " ptest"
#EXTRA_IMAGE_FEATURES_append = " ptest-pkgs"
#TEST_SUITES = "_ptest"

#TESTIMAGE_AUTO_qemuall = "1"
#TEST_TARGET_qemuall = "qemu"
# use kvm with x86 qemu
#QEMU_USE_KVM = "1"
# Set aside 2GB ram for Qemu
#QB_MEM = "-m 2048"
# Launch qemu without any need for graphics on host
#DISPLAY = "nographic"
# common
#TEST_SERVER_IP = "10.0.0.10"
#TEST_TARGET_IP_qemuall = "192.168.7.2"
# Allow 3 mins to let it boot
TEST_QEMUBOOT_TIMEOUT = "60"
TEST_TARGET_raspberrypi3 ?= "simpleremote"
TEST_TARGET_IP_raspberrypi3 ?= "10.0.0.68"

PARALLEL_MAKE_append = " -l \${@int(os.sysconf(os.sysconf_names['SC_NPROCESSORS_ONLN'])) * 150/100}"

#XZ_DEFAULTS = "--threads=3"

INHERIT += "blacklist"
PNBLACKLIST[build-appliance-image] = "tries to include whole downloads directory in /home/builder/poky :/"

# required to build netperf
LICENSE_FLAGS_WHITELIST_append = " non-commercial_netperf "

# chromium
LICENSE_FLAGS_WHITELIST_append = " commercial_ffmpeg commercial_x264 "
# vlc
LICENSE_FLAGS_WHITELIST_append = " commercial_mpeg2dec "
# mpd
LICENSE_FLAGS_WHITELIST_append = " commercial_mpg123 "
# libmad
LICENSE_FLAGS_WHITELIST_append = " commercial_libmad "
# gstreamer1.0-libav
LICENSE_FLAGS_WHITELIST_append = " commercial_gstreamer1.0-libav "
# gstreamer1.0-omx
LICENSE_FLAGS_WHITELIST_append = " commercial_gstreamer1.0-omx "
# omapfbplay
LICENSE_FLAGS_WHITELIST_append = " commercial_lame "
# libomxil
LICENSE_FLAGS_WHITELIST_append = " commercial_libomxil "
# xfce
LICENSE_FLAGS_WHITELIST_append = " commercial_packagegroup-xfce-multimedia commercial_xfce4-mpc-plugin"
LICENSE_FLAGS_WHITELIST_append = " commercial_xfmpc commercial_mpd "
LICENSE_FLAGS_WHITELIST_append = " commercial_mpv "
# epiphany
LICENSE_FLAGS_WHITELIST_append = " commercial_faad2 "
# ugly
LICENSE_FLAGS_WHITELIST_append = " commercial_gstreamer1.0-plugins-ugly "
EOF

# delete ununsed layers
sed -i -e "/${TOPDIR}\/sources\/meta-browser/d" ${WORKSPACE}/conf/bblayers.conf
sed -i -e "/${TOPDIR}\/sources\/meta-rust/d" ${WORKSPACE}/conf/bblayers.conf
sed -i -e "/${TOPDIR}\/sources\/meta-qt5/d" ${WORKSPACE}/conf/bblayers.conf

machs="${MACHINES}"
t="${TARGETS}"
opts="--quiet --continue"


for m in $machs
do
  echo "---------------------------------------------------------------------"
  echo "Building $t for $m ..."
  tmpfile=`date +%S%N`
  if [ -d build/tmp ]
  then
    mv build/tmp build/tmp-${tmpfile}
    rm -rf build/tmp-${tmpfile}
  fi
  for f in `find /opt/world/downloads/ -maxdepth 1 -name "*.lock"` `find /opt/world/downloads/ -name "*bad-checksum*"`
  do
    rm $f
  done
  buildit ret "$m" "$opts" "$t"
  eval `grep -e "send-error-report " ${WORKSPACE}/build/tmp/log/cooker/$m/console-latest.log | \
        sed 's/^.*send-error-report/send-error-report -y/' | sed 's/\[.*$//g'`
  tmpfile=`date +%S%N`
  if [ -d build/tmp ]
  then
    mv build/tmp build/tmp-${tmpfile}
    rm -rf build/tmp-${tmpfile}
  fi
    
# disable checking for return value for now
  if [ $ret != 0 ]
  then
     exit -1
  fi
done


if [ "${DONT_PRUNE_SSTATE}" != "true" ]
then
    echo "Pruning shared state ..."
    ./sources/openembedded-core/scripts/sstate-cache-management.sh -d -y > /dev/null 2>&1
fi

echo "All Done !!!"
#rm -rf ${WORKSPACE}
