# zonde ships as a single static musl binary, so the final image is FROM scratch
# (no base OS, no libc, ~0.5 MB). Build the binaries first, then the image:
#
#   zig build release
#   docker build -t zonde .                                             # host arch
#   docker buildx build --platform linux/amd64,linux/arm64 -t zonde .   # multi-arch
#   docker run -p 9100:9100 zonde
#
# A helper stage runs on the *build* platform (never emulated) and just copies
# the correct cross-compiled binary for the target arch; the scratch stage has
# no RUN, so no qemu is needed even for cross-arch images.
FROM --platform=$BUILDPLATFORM busybox AS picker
ARG TARGETARCH
COPY zig-out/release/ /release/
RUN case "$TARGETARCH" in \
    amd64) cp /release/zonde-x86_64-linux-musl /zonde ;; \
    arm64) cp /release/zonde-aarch64-linux-musl /zonde ;; \
    *) echo "unsupported TARGETARCH: $TARGETARCH" >&2; exit 1 ;; \
    esac

FROM scratch
COPY --from=picker /zonde /zonde
EXPOSE 9100
ENTRYPOINT ["/zonde"]
