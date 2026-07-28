#install sshd

sudo apt update && \
sudo apt install -y openssh-server && \
sudo systemctl enable ssh && \
sudo systemctl start ssh && \
sudo systemctl status ssh


# cat id_ed pubkey to root's $HOME/authorized_keys
C:\Users\clint\.ssh>cat C:\Users\clint\.ssh\id_ed25519.pub
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOLvx26SN1dIBbRY0/Dfp43gRCTNKZCUQoJEmMnahQRq clint@dovholuk.com


# install devtools for linux

sudo apt update && \
sudo apt install -y build-essential gcc g++ make cmake pkg-config \
    git curl wget unzip autoconf automake libtool gdb ninja-build libsystemd-dev


# clone vcpkg

git clone https://github.com/Microsoft/vcpkg.git
cd vcpkg
./bootstrap-vcpkg.sh


# ziti-edge-tunnel DNS on WSL

ziti-edge-tunnel (the openziti-edge-tunnel package) integrates with systemd-resolved. It registers
its own resolver on the ziti0 link, and resolved then SPLITS DNS: ziti service names go to ZET,
everything else to your normal upstreams. Do not point DNS at ZET by hand. It lives on ziti0 (for
example 100.64.0.2), never on 127.0.0.1. The only reason it fails on a default WSL is that WSL keeps
regenerating /etc/resolv.conf and points it at /mnt/wsl/resolv.conf ("foreign" mode), so resolved is
not the stub resolver and the split never applies. Put resolved in stub mode with real upstreams,
then let ZET do the rest.

# 1. wsl.conf: enable systemd, stop WSL rewriting resolv.conf
sudo tee /etc/wsl.conf <<'EOF'
[boot]
systemd=true

[network]
generateResolvConf = false
EOF

# 2. point resolv.conf at the resolved stub (a symlink that survives relaunch)
sudo ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

# 3. Global upstreams: your REAL resolvers, LAN first then a public one. NOT ZET and NOT
#    127.0.0.1, because ZET adds itself on ziti0 automatically. The empty 'DNS=' line resets
#    whatever /etc/systemd/resolved.conf already set, so these become the only Global servers.
#    Keep this a REAL file: if the drop-in is a symlink into /mnt/wsl, delete it first, because
#    that path is recreated each boot and does not survive wsl --shutdown.
sudo mkdir -p /etc/systemd/resolved.conf.d
sudo rm -f /etc/systemd/resolved.conf.d/ziti-intercept.conf
sudo tee /etc/systemd/resolved.conf.d/ziti-intercept.conf <<'EOF'
[Resolve]
DNS=
DNS=192.168.1.5 1.1.1.1
EOF

# 4. apply. For persistence across a relaunch, run 'wsl --shutdown' from Windows PowerShell
#    afterward, then reconnect.
sudo systemctl restart systemd-resolved
sudo systemctl enable --now ziti-edge-tunnel   # needs an identity in /opt/openziti/etc/identities

# verify the split: internet resolves via eth0, a ziti name via ziti0
resolvectl query google.com
resolvectl query mgmt.ziti

# .local GOTCHA: systemd-resolved reserves *.local for mDNS and refuses to hand it to ZET, so a
# service addressed like ziti.mgmt.local fails with "No appropriate name servers". Use a non-.local
# intercept address (mgmt.ziti, foo.mgmt.internal). If a .local address is unavoidable, add a
# per-link routing domain (runtime only, ZET resets ziti0 on restart):
#   sudo resolvectl domain ziti0 '~mgmt.local'
