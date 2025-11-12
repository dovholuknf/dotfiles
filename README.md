# WSL steps

#install sshd

sudo apt update && \
sudo apt install -y openssh-server && \
sudo systemctl enable ssh && \
sudo systemctl start ssh && \
sudo systemctl status ssh


# cat id_ed pubkey to root's $HOME/authorized_keys (for clion)
cat .ssh\id_ed25519.pub

# install devtools for linux

sudo apt update && \
sudo apt install -y build-essential gcc g++ make cmake pkg-config \
    git curl wget unzip autoconf automake libtool gdb


