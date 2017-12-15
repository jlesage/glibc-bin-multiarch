#!/bin/sh

set -e # Exit immediately if a command exits with a non-zero status.
set -u # Treat unset variables as an error.

usage() {
    echo "usage: $(basename "$0") ARCH VERSION [OPTIONS...]

Arguments:
    ARCH                Architecture to build glibc on.
    VERSION             Version of glibc to build.

Options:
    -o, --output FILE   Redirect all compilation output to FILE.
    -h, --help          Display this help and exit.
"
}

running_in_docker() {
    cat /proc/1/cgroup | cut -d':' -f3 | grep -q "^/docker/"
}

SCRIPT="$(readlink -f "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT")"

STD_OUTPUT="/dev/stdout"
ERR_OUTPUT="/dev/stderr"

ARCH=UNSET
GLIBC_VERSION=UNSET
GLIBC_CONFIGURE_EXTRA_OPTS=

# Parse arguments.
while [ $# -gt 0 ]
do
    key="$1"

    case $key in
        -o|--output)
            value="${2:-UNSET}"
            if [ "$value" = "UNSET" ]; then
                echo "ERROR: Missing output file."
                usage
                exit 1
            fi
            STD_OUTPUT="$value"
            ERR_OUTPUT="/dev/stdout"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            echo "ERROR: Unknown argument: $key"
            usage
            exit 1
            ;;
        *)
            if [ "$ARCH" = "UNSET" ]; then
                ARCH="$key"
            elif [ "$GLIBC_VERSION" = "UNSET" ]; then
                GLIBC_VERSION="$key"
            else
                echo "ERROR: Unknown argument: .$key'."
                usage
                exit 1
            fi
            ;;
    esac
    shift
done

if [ "$ARCH" = "UNSET" ]; then
    echo "ERROR: architecture missing."
    usage
    exit 1
elif [ "$GLIBC_VERSION" = "UNSET" ]; then
    echo "ERROR: glibc version missing."
    usage
    exit 1
fi

# Handle the architecture.
case "$ARCH" in
    x86_64)
        ;;
    x86)
        GLIBC_CONFIGURE_EXTRA_OPTS=--host=i686-pc-linux-gnu
        ;;
    armhf)
        GLIBC_CONFIGURE_EXTRA_OPTS=--host=arm-linux-gnueabihf
        ;;
    aarch64)
        GLIBC_CONFIGURE_EXTRA_OPTS=--host=aarch64-linux-gnu
        ;;
    *)
        echo "ERROR: Invalid architecture '$ARCH'."
        exit 1;;
esac

if running_in_docker; then
    SOURCE_DIR=/glibc-src
    BUILD_DIR=/glibc-build
    INSTALL_DIR=/glibc-install

    mkdir -p "$SOURCE_DIR" "$BUILD_DIR" "$INSTALL_DIR"

    # Download glibc.
    echo "Downloading glibc..."
    GLIBC_URL="http://ftp.gnu.org/gnu/glibc/glibc-$GLIBC_VERSION.tar.gz"
    curl -# -L "$GLIBC_URL" | tar xz --strip 1 -C "$SOURCE_DIR"

    # Compile glibc.
    cd "$BUILD_DIR"
    echo "Configuring glibc..."
    "$SOURCE_DIR"/configure \
        --prefix="$INSTALL_DIR" \
        --libdir="$INSTALL_DIR/lib" \
        --libexecdir="$INSTALL_DIR/lib" \
        --enable-multi-arch \
        $GLIBC_CONFIGURE_EXTRA_OPTS
    echo "Compiling glibc..."
    make
    echo "Installing glibc..."
    make install

    echo "Creating glibc binary package..."
    (cd "$INSTALL_DIR" && tar --hard-dereference -zcf "/output/glibc-bin-${GLIBC_VERSION}-${ARCH}.tar.gz" *)
else
    # Create the Dockerfile.
    cat > "$SCRIPT_DIR"/Dockerfile <<EOF
FROM ubuntu:xenial
RUN \
    apt-get -q update && \
    apt-get -qy install build-essential wget openssl gawk curl \
         gcc-aarch64-linux-gnu \
         gcc-arm-linux-gnueabihf
ADD $(basename "$SCRIPT") /
VOLUME ["/output"]
ENTRYPOINT ["/build-glibc.sh"]
EOF

    # Build the docker image.
    (cd "$SCRIPT_DIR" && docker build -t glibc-builder .)
    rm "$SCRIPT_DIR"/Dockerfile

    # Run the glibc builder.
    mkdir -p "$SCRIPT_DIR"/build
    echo "Starting glibc build..."
    docker run --rm -v "$SCRIPT_DIR"/build:/output glibc-builder "$ARCH" "$GLIBC_VERSION" > $STD_OUTPUT 2>$ERR_OUTPUT
fi

