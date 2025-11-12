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
