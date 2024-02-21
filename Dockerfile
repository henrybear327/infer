FROM ubuntu:22.04

RUN apt-get update && \
    mkdir -p /usr/share/man/man1 && \
    apt-get install --yes --no-install-recommends \
    git ca-certificates build-essential autoconf automake cmake python3 curl sqlite3 \
    opam zlib1g-dev libgmp-dev libsqlite3-dev pkg-config && \
    rm -rf /var/lib/apt/lists/*
RUN opam init --disable-sandboxing -y

RUN git clone https://github.com/facebook/infer.git && \
    cd infer && \
    # Compile Infer to support C and Python3
    ./build-infer.sh -y clang python && \
    # Install Infer system-wide
    make install && \
    make clean