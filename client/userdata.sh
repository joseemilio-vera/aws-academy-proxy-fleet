#!/bin/bash
service-endpoint=<punto-enlace>
export http_proxy=http://<punto-enlace>:3128
export https_proxy=http://<punto-enlace>:3128
echo "http_proxy=http://<punto-enlace>:3128" >> /etc/environment
echo "https_proxy=http://<punto-enlace>:3128" >> /etc/environment
yum update -y
yum install lynx -y
reboot
