FROM hashicorp/terraform:latest

RUN apk add --no-cache bash curl jq
ENTRYPOINT [ "/bin/sh", "-lc" ]
# Keeps logs readable
ENV TF_IN_AUTOMATION=1
