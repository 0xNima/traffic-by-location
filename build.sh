#!/bin/bash

CWD=$PWD

[ ! -f "$CWD/.env" ] && echo ".env File not found!" && exit
    

echo """=========---------......---------=========
|                                          |
|         Installing Requirements          |
|                                          |
=========---------......---------========="""
echo "deb-src http://deb.debian.org/debian buster main" | tee -a /etc/apt/sources.list.d/buster.list && \
echo "deb http://apt.llvm.org/buster/ llvm-toolchain-buster main" >> /etc/apt/sources.list.d/buster.list && \
echo "deb-src http://apt.llvm.org/buster/ llvm-toolchain-buster main" >> /etc/apt/sources.list.d/buster.list && \
echo "deb http://apt.llvm.org/buster/ llvm-toolchain-buster-17 main" >> /etc/apt/sources.list.d/buster.list && \
echo "deb-src http://apt.llvm.org/buster/ llvm-toolchain-buster-17 main" >> /etc/apt/sources.list.d/buster.list && \
wget -O - https://apt.llvm.org/llvm-snapshot.gpg.key|sudo apt-key add - && \

apt-get update || echo "apt-get update failed" && exit

apt-get build-dep bpfcc -y && \
apt-get install git zip \
    libllvm-17-ocaml-dev libllvm17 llvm-17 llvm-17-dev llvm-17-doc llvm-17-examples llvm-17-runtime \
    clang-17 clang-tools-17 clang-17-doc libclang-common-17-dev libclang-17-dev libclang1-17 clang-format-17 python3-clang-17 clangd-17 clang-tidy-17 \
    libclang-rt-17-dev \
    libpolly-17-dev \
    libfuzzer-17-dev \
    lldb-17 \
    lld-17 \
    libc++-17-dev libc++abi-17-dev \
    libomp-17-dev \
    libclc-17-dev \
    libunwind-17-dev \
    libmlir-17-dev mlir-17-tools \
    libbolt-17-dev bolt-17 \
    flang-17 \
    libclang-rt-17-dev-wasm32 libclang-rt-17-dev-wasm64 libclang-rt-17-dev-wasm32 libclang-rt-17-dev-wasm64 -y || (echo "Installation failed" && exit)
apt-get install libc++abi-17-dev-wasm32 libc++-17-dev-wasm32 -y 


echo """=========---------......---------=========
|                                          |
|              Building libcc              |
|                                          |
=========---------......---------========="""

cd /usr/src/
git clone https://github.com/iovisor/bcc/
mkdir bcc/build
cd bcc/build

export LLVM_ROOT=/usr/lib/llvm-17

cmake -DPYTHON_CMD=python3 ..
make || echo "Building libcc failied" && exit
make install
pushd src/python/
make
make install
popd


echo """=========---------......---------=========
|                                          |
|            Downloading GeoDBs            |
|                                          |
=========---------......---------========="""


cd $CWD

mkdir GeoDB/

wget https://git.io/GeoLite2-Country.mmdb -O GeoDB/GeoLite2-Country.mmdb
wget https://git.io/GeoLite2-City.mmdb -O GeoDB/GeoLite2-City.mmdb
wget https://git.io/GeoLite2-ASN.mmdb -O GeoDB/GeoLite2-ASN.mmdb



echo """=========---------......---------=========
|                                          |
|            Downloading tcpdog            |
|                                          |
=========---------......---------========="""

mkdir tcpdog
cd tcpdog

wget https://github.com/mehrdadrad/tcpdog/releases/download/v1.0.0/tcpdog
wget https://github.com/mehrdadrad/tcpdog/releases/download/v1.0.0/tcpdog-server

chmod +x tcpdog
chmod +x tcpdog-server



echo """=========---------......---------=========
|                                          |
|           Creating client.yaml           |
|                                          |
=========---------......---------========="""


cat > client.yaml<<EOF
tracepoints:
  - name: sock:inet_sock_set_state
    fields: latency
    tcp_state: TCP_CLOSE
    inet: [4,6]
    egress: server

fields:
  latency:
     - name: PID
     - name: DAddr
     - name: Task
     - name: SAddr
     #- name: RTT
     #- name: TotalRetrans

egress:
  server:
    type: grpc-spb
    config:
      addr: ":8085"
EOF



echo """=========---------......---------=========
|                                          |
|           Creating server.yaml           |
|                                          |
=========---------......---------========="""

org=$(grep -E "DOCKER_INFLUXDB_INIT_ORG" $CWD/.env | cut -d= -f2)
token=$(grep -E "DOCKER_INFLUXDB_INIT_ADMIN_TOKEN" $CWD/.env | cut -d= -f2-)

[ -z "$org" ] && echo "can not extract organization from .env file" && exit
[ -z "$token" ] && echo "can not extract token from .env file" && exit

cat > server.yaml<< EOF
ingress:
  grpc01:
    type: grpc
    config:
      addr: ":8085"

ingestion:
  influx:
    type: "influxdb"
    config:
      url: http://localhost:8086
      org: $org 
      token: $token
geo:
  type: "maxmind"
  config:
    path-city: "GeoDB/GeoLite2-City.mmdb"
    level: city-loc

flow:
  - ingress: grpc01
    ingestion: influx
    serialization: spb
EOF



echo """=========---------......---------=========
|                                          |
|        Creating tcpdog-cli.service       |
|                                          |
=========---------......---------========="""

cat > /etc/systemd/system/tcpdog-cli.service<< EOF
[Unit]
Description=tcpdog client
After=network.target

[Service]
Type=simple
WorkingDirectory=$CWD
ExecStart=$CWD/tcpdog/tcpdog --config $CWD/tcpdog/client.yaml
Restart=on-failure
RestartSec=10
StandardOutput=append:$CWD/tcpdog/tcpdog-client.log
StandardError=append:$CWD/tcpdog/tcpdog-client.log

[Install]
WantedBy=multi-user.target
EOF



echo """=========---------......---------=========
|                                          |
|      Creating tcpdog-server.service      |
|                                          |
=========---------......---------========="""


cat > /etc/systemd/system/tcpdog-server.service<< EOF
[Unit]
Description=tcpdog server
After=network.target

[Service]
Type=simple
WorkingDirectory=$CWD
ExecStart=$CWD/tcpdog/tcpdog-server --config $CWD/tcpdog/server.yaml
Restart=on-failure
RestartSec=10
StandardOutput=append:$CWD/tcpdog/tcpdog-server.log
StandardError=append:$CWD/tcpdog/tcpdog-server.log

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload


echo """=========---------......---------=========
|                                          |
|             Installing Docker            |
|                                          |
=========---------......---------========="""

apt install apt-transport-https ca-certificates curl gnupg2 software-properties-common -y
curl -fsSL https://download.docker.com/linux/debian/gpg | sudo apt-key add -
add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/debian $(lsb_release -cs) stable"
apt update && \
apt-cache policy docker-ce && \
apt install docker-ce -y && \
service docker restart || echo "failed to start docker" && exit 

cd ..

ufw allow 8086

echo """=========---------......---------=========
|                                          |
|              Running services            |
|                                          |
=========---------......---------========="""


docker compose up -d && service tcpdog-server restart && service tcpdog-cli restart
