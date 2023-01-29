#!/bin/bash
set -e
trap 'echo "[ERROR] Error in line $LINENO when executing: $BASH_COMMAND"' ERR

if [[ "$(id -u)" != "0" ]]; then
    exec sudo bash "$BASH_SOURCE"
fi

# let's do all of this in a clean directory:
updir=/tmp/update-adsb

rm -rf $updir
mkdir -p $updir
cd $updir

# in case /var/log is full ... delete some logs
echo test > /var/log/.test 2>/dev/null || rm -f /var/log/*.log

restartIfEnabled() {
    # check if enabled
    if systemctl is-enabled "$1" &>/dev/null; then
            systemctl restart "$1"
    fi
}

function aptInstall() {
    if ! apt install -y --no-install-recommends --no-install-suggests "$@"; then
        apt update
        apt install -y --no-install-recommends --no-install-suggests "$@"
    fi
}

packages="git make gcc libusb-1.0-0 libusb-1.0-0-dev librtlsdr0 librtlsdr-dev ncurses-bin ncurses-dev zlib1g zlib1g-dev python3-dev python3-venv libzstd-dev libzstd1"
aptInstall $packages

git clone --quiet --depth 1 https://github.com/Zerotwistknife7/adsb-update.git
cd adsb-update

find skeleton -type d | cut -d / -f1 --complement | grep -v '^skeleton' | xargs -t -I '{}' -s 2048 mkdir -p /'{}' &>/dev/null
find skeleton -type f | cut -d / -f1 --complement | xargs -I '{}' -s 2048 cp -T --remove-destination -v skeleton/'{}' /'{}' >/dev/null

# make sure the config has all the options, if not add them with default value:
for line in $(grep -v -e '^#' -e '^$' boot-configs/adsb-config.txt); do
    if ! grep -qs "$(echo $line | cut -d= -f1)" /boot/adsb-config.txt; then
        echo $line >> /boot/adsb-config.txt
    fi
done

# remove strange dhcpcd wait.conf in case it's there
rm -f /etc/systemd/system/dhcpcd.service.d/wait.conf

if [[ -f /etc/systemd/system/adsb-978-convert.service ]]; then
    systemctl disable --now adsb-978-convert.service &>/dev/null || true
fi
rm -f /etc/systemd/system/adsb-978-convert.service
rm -f /usr/local/bin/adsb-978-convert.sh

systemctl daemon-reload

# enable services
systemctl enable \
    adsb-first-run.service \
    adsb-zt-enable.service \
    readsb.service \
    adsb-mlat.service \
    adsb-feed.service \
    pingfail.service

# mask services we don't need on this image
MASK="dump1090-fa dump1090 dump1090-mutability dump978-rb dump1090-rb"
for service in $MASK; do
    systemctl disable $service || true
    systemctl stop $service || true
    systemctl mask $service || true
done &>/dev/null

cd $updir
git clone --quiet --depth 1 https://github.com/Zerotwistknife7/readsb.git

echo 'compiling readsb (this can take a while) .......'

cd readsb

if dpkg --print-architecture | grep -qs armhf; then
    make -j3 AIRCRAFT_HASH_BITS=12 RTLSDR=yes OPTIMIZE="-O2 -mcpu=arm1176jzf-s -mfpu=vfp"
else
    make -j3 AIRCRAFT_HASH_BITS=12 RTLSDR=yes OPTIMIZE="-O3"
fi

echo 'copying new readsb binaries ......'
cp -f readsb /usr/bin/adsbfeeder
cp -f readsb /usr/bin/adsb-978
cp -f readsb /usr/bin/readsb
cp -f viewadsb /usr/bin/viewadsb


echo 'make sure unprivileged users exist (readsb / adsb) ......'
for USER in adsb readsb; do
    if ! id -u "${USER}" &>/dev/null
    then
        adduser --system --home "/usr/local/share/$USER" --no-create-home --quiet "$USER"
    fi
done

# plugdev required for bladeRF USB access
adduser readsb plugdev
# dialout required for Mode-S Beast and GNS5894 ttyAMA0 access
adduser readsb dialout

mkdir -p /var/globe_history
chown readsb /var/globe_history

echo 'restarting services .......'
restartIfEnabled readsb
restartIfEnabled adsb-feed
restartIfEnabled adsb-978

cd $updir
rm -rf $updir/readsb

echo 'updating adsb stats .......'
wget --quiet -O /tmp/axstats.sh https://raw.githubusercontent.com/Zerotwistknife7/adsb-stats/master/stats.sh
bash /tmp/axstats.sh

echo 'cleaming up stats /tmp .......'
rm -f /tmp/axstats.sh
rm -f -R /tmp/adsb-stats-git

VENV=/usr/local/share/adsb/venv/
if [[ -f /usr/local/share/adsb/venv/bin/python3.7 ]] && command -v python3.9 &>/dev/null;
then
    rm -rf "$VENV"
fi
rm "$VENV-backup" -rf
mv "$VENV" "$VENV-backup" -f &>/dev/null || true

cd $updir

echo 'building mlat-client in virtual-environment .......'
if git clone --quiet --depth 1 --single-branch https://github.com/Zerotwistknife7/mlat-client.git \
    && cd mlat-client \
    && /usr/bin/python3 -m venv $VENV  \
    && source $VENV/bin/activate  \
    && python3 setup.py build \
    && python3 setup.py install \
    && git rev-parse HEAD > $IPATH/mlat_version || rm -f $IPATH/mlat_version \
; then
    rm "$VENV-backup" -rf
else
    rm "$VENV" -rf
    mv "$VENV-backup" "$VENV" &>/dev/null || true
    echo "--------------------"
    echo "Installing mlat-client failed, if there was an old version it has been restored."
    echo "Will continue installation to try and get at least the feed client working."
    echo "Please repot this error to the adsb forums or discord."
    echo "--------------------"
fi

echo 'starting services .......'
restartIfEnabled adsb-mlat

cd $updir
rm -f -R $updir/mlat-client

cd $updir

echo 'update tar1090 ...........'
bash -c "$(wget -nv -O - https://raw.githubusercontent.com/wiedehopf/tar1090/master/install.sh)"

if [[ -f /boot/adsb-config.txt ]]; then
    if ! grep -qs -e 'GRAPHS1090' /boot/adsb-config.txt; then
        echo "GRAPHS1090=yes" >> /boot/adsb-config.txt
    fi
    if ! grep -qs -e "ZEROTIER_STANDALONE" /boot/adsb-config.txt; then
        echo "ZEROTIER_STANDALONE=no" >> /boot/adsb-config.txt
    fi
fi


# the following doesn't apply for chroot (image creation)
if ischroot; then
    exit 0
fi

echo "#####################################"
cat /boot/adsb-uuid
echo "#####################################"
sed -e 's$^$https://www.adsb.com/api/feeders/?feed=$' /boot/adsb-uuid
echo "#####################################"

echo "8.2.$(date '+%y%m%d')" > /boot/adsb-version-decoder

echo '--------------------------------------------'
echo '--------------------------------------------'
echo '             UPDATE COMPLETE'
echo '--------------------------------------------'
echo '--------------------------------------------'


cd /tmp
rm -rf $updir
