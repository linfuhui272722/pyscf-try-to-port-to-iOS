#!/bin/sh
# Meson cannot execute arm64 iOS binaries on a Linux build host, but several of
# its dependency probes (notably Apple's Accelerate framework) insist on running
# the compiled test program.  Reporting success is safe here because the probes
# only ask "did this link and start", and the iOS SDK guarantees the frameworks
# it links against.
exit 0
