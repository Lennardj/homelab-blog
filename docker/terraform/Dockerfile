
FROM hashicorp/terraform:1.7

RUN apk add --no-cache bash curl jq

ENV TF_IN_AUTOMATION=1





# FROM ubuntu:latest

# RUN apt-get  -y update && apt-get -y  upgrade && apt-get  -y install wget sudo 

# RUN <<EOF 
#     wget -O - https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg \
#     echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(grep -oP '(?<=UBUNTU_CODENAME=).*' /etc/os-release || lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list \
#     sudo apt update && sudo apt install terraform
# EOF
# ENTRYPOINT [ "/bin/bash", "-lc" ]
# # Keeps logs readable
# ENV TF_IN_AUTOMATION=1
