FROM ubuntu:22.04

LABEL maintainer="builder"
LABEL description="PassWall Build Environment"

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Asia/Shanghai

RUN apt-get update && apt-get install -y \
    makeself \
    unzip \
    curl \
    jq \
    git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

COPY . /build/

CMD ["bash"]
