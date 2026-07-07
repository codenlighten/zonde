# zonde ships as a single static binary, so the image is FROM scratch — no base
# OS, no libc, ~0.5 MB. Build the binaries first, then the image:
#
#   zig build release
#   docker build --build-arg TARGET=x86_64-linux-musl -t zonde .
#   docker run -p 9100:9100 zonde
#
# Use a musl target: gnu binaries dynamically link glibc, which scratch lacks.
FROM scratch
ARG TARGET=x86_64-linux-musl
COPY zig-out/release/zonde-${TARGET} /zonde
EXPOSE 9100
ENTRYPOINT ["/zonde"]
