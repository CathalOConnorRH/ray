# Build file for the @perl_s390x_system repository (see WORKSPACE).
#
# rules_perl only ships hermetic Perl distributions for linux x86_64/arm64,
# darwin and windows, so on s390x we expose the host's system Perl
# (/usr/bin/perl from RHEL) as a rules_perl toolchain. The layout matches
# what rules_perl's BUILD.dist.bazel.tpl generates for downloaded
# distributions: a single "runtime" filegroup containing the interpreter,
# the xsubpp helper, and the XS (CORE) headers.
package(default_visibility = ["//visibility:public"])

filegroup(
    name = "runtime",
    srcs = (
        glob(["bin/perl"]) +
        glob(["bin/perl5.*"], allow_empty = True) +
        glob(["bin/xsubpp"]) +
        glob(["lib64/perl5/CORE/*.h"], allow_empty = True)
    ),
)