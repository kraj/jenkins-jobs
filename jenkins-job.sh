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

TIMEOUT="15h"
umask 0022

# Compare two versions e.g. 18.04 < 22.04
version_greater_equal() {
    printf '%s\n%s\n' "$2" "$1" | sort --check=quiet --version-sort
}

test -e /etc/os-release && os_release='/etc/os-release' || os_release='/usr/lib/os-release'
. "${os_release}"

# use Pre-Built buildtools Tarball ( currently 5.0.2 is latest, update it on ubuntu 18.04 hosts when next release happens)
# https://downloads.yoctoproject.org/releases/yocto/yocto-5.0.2/buildtools/?C=S&O=A
YPVER=5.0.2
SDKOS=$(uname -m)
if ! version_greater_equal $VERSION_ID 22.04; then
        BUILDTOOLS=/opt/poky/$YPVER/environment-setup-$SDKOS-pokysdk-linux
        echo "Using buildtools from $BUILDTOOLS"
        test -e ${BUILDTOOLS} && . ${BUILDTOOLS}
fi

buildit() {
#       echo $1 $2 $3 $4
        local myret=$1
        start_time=`date +%s`
        unset PROJECT
        . ./envsetup.sh $2
        # do not build QT6 layer
        sed -i -e '/meta-qt6/d' conf/projects/${PROJECT}/layers.conf
        # undo https://git.yoctoproject.org/poky/commit/?id=80396cc72ac7
        # New ubuntu VMs mount /tmp with NOEXEC
        sed -i -e '/os.ST_NOEXEC:$/{N;d;}' sources/poky/meta/classes-global/sanity.bbclass
        # Disable hash equivalence, its too slow
        #sed -i -e 's/^BB_SIGNATURE_HANDLER/#BB_SIGNATURE_HANDLER/' sources/meta-yoe/conf/distro/yoe.inc
        #sed -i -e 's/^BB_HASHSERVE /#BB_HASHSERVE /' sources/meta-yoe/conf/distro/yoe.inc
        #/usr/bin/timeout -s KILL ${TIMEOUT} bitbake $3 $4
        bitbake $3 $4
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
    if ps aux | grep "bitbake/bin/[b]itbake-server" ; then
        local BITBAKE_PIDS=`ps aux | grep "bitbake/bin/[b]itbake-server" | awk '{print $2}' | xargs`
        [ -n "${BITBAKE_PIDS}" ] && kill ${BITBAKE_PIDS}
        sleep 10
        ps aux | grep "bitbake/bin/[b]itbake-server"
        local BITBAKE_PIDS=`ps aux | grep "bitbake/bin/[b]itbake-server" | awk '{print $2}' | xargs`
        [ -n "${BITBAKE_PIDS}" ] && kill -9 ${BITBAKE_PIDS}
        ps aux | grep "bitbake/bin/[b]itbake-server" || true
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

rm -rf ${WORKSPACE}

git clone --depth 1 -b ${BRANCH} https://github.com/YoeDistro/yoe-distro ${WORKSPACE}
cd ${WORKSPACE}
git submodule init
git submodule update --depth 1

cat <<EOF > ${WORKSPACE}/local.sh
export PROJECT=${PROJECT-qemuarm}
export TOOLCHAIN=${TOOLCHAIN-gcc}
export DOCKER_REPO="none"
EOF

cd ${WORKSPACE}
. ./envsetup.sh

find .git -name "index.lock" -delete
find .git -name "shallow.lock" -delete

kill_stalled_bitbake_processes

#git fetch --all
#git gc --prune
#yoe_setup
#git checkout ${BRANCH}
#yoe_update_all

cat <<EOF > ${WORKSPACE}/conf/local.conf

TOOLCHAIN = "${TOOLCHAIN}"

YOE_PROFILE = "${YOE_PROFILE}"

IMAGE_CLASSES += "testimage"
INHERIT += "rm_work"
INHERIT += "report-error"
INHERIT += "buildstats buildstats-summary"

DL_DIR = "/opt/world/downloads/"
SSTATE_DIR = "/opt/sstate-cache/"

BB_GIT_SHALLOW = "1"
# Keep only the top commit
BB_GIT_SHALLOW_DEPTH = "1"
BB_GENERATE_SHALLOW_TARBALLS = "1"

DISTRO_FEATURES:append = " ptest"
#EXTRA_IMAGE_FEATURES:append = " ptest-pkgs"
#TEST_SUITES = "_ptest"

#TESTIMAGE_AUTO:qemuall = "1"
#TEST_TARGET:qemuall = "qemu"
# use kvm with x86 qemu
#QEMU_USE_KVM = "1"
# Set aside 2GB ram for Qemu
#QB_MEM = "-m 2048"
# Launch qemu without any need for graphics on host
#DISPLAY = "nographic"
# common
#TEST_SERVER_IP = "10.0.0.10"
#TEST_TARGET_IP:qemuall = "192.168.7.2"
# Allow 3 mins to let it boot
TEST_QEMUBOOT_TIMEOUT = "60"

BB_NUMBER_THREADS = "\${@int(os.sysconf(os.sysconf_names['SC_NPROCESSORS_ONLN']) * 100/300)}"
PARALLEL_MAKE = "-j \${@int(os.sysconf(os.sysconf_names['SC_NPROCESSORS_ONLN']) * 100/300)}"
PARALLEL_MAKE:append = " -l \${@int(os.sysconf(os.sysconf_names['SC_NPROCESSORS_ONLN']) * 100/50)}"

BB_PRESSURE_MAX_CPU = "100000"
#BB_PRESSURE_MAX_MEMORY = "20000"
#BB_NUMBER_PARSE_THREADS = "32"

#XZ_THREADS = "4"
#ZSTD_THREADS = "4"
#XZ_MEMLIMIT = "5%"
#OMP_NUM_THREADS = "8"

SKIP_RECIPE[build-appliance-image] = "tries to include whole downloads directory in /home/builder/poky :/"
# Enable all commercial packages for build
LICENSE_FLAGS_ACCEPTED:append = " commercial non-commercial"

# Do not build meta-qt6 in CI, takes too long with it
EXCLUDE_FROM_WORLD:qt6-layer = '1'

CONF_VERSION = "2"
TOOLCHAIN:pn-alsa-tools = "gcc"
EOF

projs="${PROJECTS}"
t="${TARGETS}"
opts="--continue"


for m in $projs
do
  echo "---------------------------------------------------------------------"
  echo "Building $t for $m ..."
#  tmpfile=`date +%S%N`
#  if [ -d build/tmp ]
#  then
#    mv build/tmp build/tmp-${tmpfile}
#    rm -rf build/tmp-${tmpfile}
#  fi
  for f in `find /opt/world/downloads/ -maxdepth 1 -name "*.lock"` \
           `find /opt/world/downloads/ -maxdepth 1 -name "*bad-checksum*"` \
           `find /opt/world/downloads/ -maxdepth 1 -name "*.tmp"`
  do
    rm $f
  done
  buildit ret "$m" "$opts" "$t"
  eval `grep -e "send-error-report " ${WORKSPACE}/build/tmp/log/cooker/$m/console-latest.log | \
        sed 's/^.*send-error-report/send-error-report -y/' | sed 's/\[.*$//g'`
#  tmpfile=`date +%S%N`
# if [ -d build/tmp ]
# then
#   mv build/tmp build/tmp-${tmpfile}
#   rm -rf build/tmp-${tmpfile}
# fi

# disable checking for return value for now
  if [ $ret != 0 ]
  then
     exit -1
  fi
done


if [ "${DONT_PRUNE_SSTATE}" != "true" ]
then
    echo "Pruning shared state ..."
    ./sources/poky/scripts/sstate-cache-management.py -d --remove-orphans -y > /dev/null 2>&1
fi

echo "All Done !!!"
#rm -rf ${WORKSPACE}
