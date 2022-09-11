# Segmentation fault minimal example

After upgrading from GHC 8.6.5 to 8.8.x we consistently get a segfault from GHC when building certain targets.
This directory contains a minimal example to reproduce this; If you have `direnv` installed, `cd`ing into the `minirepo` and running `direnv allow` should pull in all necessary tools. To reproduce the segfault, run `bazel build //minimal-segfault:lib`. (You can verify that it didn't segfault previously by reverting the single commit that upgraded the GHC version).

It is recommended to read the [README](https://github.com/jonathanlking/minirepo/blob/ghc-8.8/README.md) first to get a picture of the tools involved and organisation of the repo.

## Current status
Looking at the logs/backtrace in the core dump, it looks like an issue with linking `openssl`. This is triggered when a package (`//minimal-segfault:lib`) runs template haskell, loading in another package (`//minimal-segfault:ffi`) that uses `openssl`.
It's hard to know if this is an issue with `rules_haskell`, `static-haskell-nix`, a bad package in `nixpkgs` or GHC (or some combination).

## How did we get to this example?
This example came from an existing codebase and parts were removed until (just before) compiling it no longer segfaulted.

* Template Haskell was required, but we could limit it to a top-level `pure []`, which is the empty Quasi-quotation. This ruled out it being an issue with any specific library.
* Initially we determined that depending on [`libssh2`](https://github.com/portnov/libssh2-hs/blob/master/libssh2/libssh2.cabal) triggered the issue, but from stripping that library back, we found that its FFI dependency on `openssl` was the source.
* It is necessary for the FFI function and the use of Template Haskell to live in separate Bazel targets. Having it in the same file, or even separate files under the same targets do not trigger the segfault.
* It is necessary to use the `haskell_cabal_library` Bazel macro rather than `haskell_library` [(see example)](#using-haskell_library) for the `:ffi` package.
* Not all functions imported from `openssl` work (i.e. trigger a segfault) — we picked [`OPENSSL_strlcpy`](https://github.com/openssl/openssl/blob/1c0eede9827b0962f1d752fa4ab5d436fa039da4/include/openssl/crypto.h.in#L124) but others do too. A heuristic spotted is that functions that take `void` as their only input e.g. [`OPENSSL_version_major`](https://github.com/openssl/openssl/blob/1c0eede9827b0962f1d752fa4ab5d436fa039da4/include/openssl/crypto.h.in#L143) don't work, but ones that take non-`void` input _do_.

### Picking versions of ghc, nixpkgs and static-haskell-nix
GHC 8.8.4 is the most recent version in the 8.8.x releases.

[Postgrest](https://github.com/PostgREST/postgrest), an open source tool written in Haskell, builds static binaries with `static-haskell-nix` and also depends on openssl.
It upgraded to `ghc884` in [`9cfc66a`](https://github.com/PostgREST/postgrest/commit/9cfc66a6a47fa01324371825dff4c71c88920d13), where `nixpkgs` is pinned to [`2a05848`](https://github.com/NixOS/nixpkgs/tree/2a058487cb7a50e7650f1657ee0151a19c59ec3b) and `static-haskell-nix` is pinned to [`749707f`](https://github.com/nh2/static-haskell-nix/tree/749707fc90b781c3e653e67917a7d571fe82ae7b), which is what we now use in the minirepo.
Helpfully this version of `nixpkgs` also supports both `ghc865` and `ghc884`, so we can switch between them while keeping other packages constant.

We separately pin our "tooling" in [`nix/tooling/default.nix`](https://github.com/jonathanlking/minirepo/blob/ghc-8.8/nix/tooling/default.nix), which has been set to a recent-ish version of unstable.

We upgraded `rules_haskell` to its most recent version [0.15](https://github.com/tweag/rules_haskell/releases/tag/v0.15), however the segfault issue exists on previous versions too.

## Trying to recreate the issue in postgrest
I created a branch off [`9cfc66a`](https://github.com/PostgREST/postgrest/commit/9cfc66a6a47fa01324371825dff4c71c88920d13) called [minimal-segfault](https://github.com/jonathanlking/postgrest/tree/minimal-segfault), trying to replicate the minirepo example.

You can build the static image with `nix-build -A postgrestStatic`, which will trigger building the example (as a dependency).

Frustratingly it doesn’t segfault, and as there are many differences between the two repos (e.g. no Bazel, GHC is built without `-fPIC -fexternal-dynamic-refs`, openssl is patched differently), it requires further investigation.

## Debugging GHC

### Taking a core dump

To make the dumps easier to find, I chose to update the name format

`sudo sysctl -w kernel.core_pattern=/tmp/core-%e.%p.%h.%t`

We can list them with `ls -l /tmp/core-ghc*`

I found my core dump file size limit was `0` (by running `ulimit -c`), which meant no core dumps were being saved. You can increase this `ulimit -c unlimited`, however I found that this wasn’t being propagated into the Bazel sandbox. The hacky solution I chose was to inject it into the (second line of the) GHC script which gets called by Bazel:

`sudo sed -i --follow-symlinks '2 i ulimit -c unlimited' $(which ghc)`

### Examining the core dump

If you run `gdb -c <your-core-dump` you will get some lines, including one like:

```
Core was generated by `/nix/store/hwz1jm0vaqy8ln9dwba4709nrlggvk92-ghc-8.8.4/lib/ghc-8.8.4/bin/ghc -B/'.
```
If you then call `gdb` again with the path the ghc as the first argument, it will load the symbols from the ghc binary (which gives function names to the memory addresses).
E.g. I ran `gdb /nix/store/hwz1jm0vaqy8ln9dwba4709nrlggvk92-ghc-8.8.4/lib/ghc-8.8.4/bin/ghc /tmp/core-ghc.3.thomas.1661904384` (but these names will obviously be different on your machine).

In `gdb` you can then run `bt` to get a backtrace with symbols:

```
#0  0x0000000041502b95 in ?? ()
#1  0x0000000003804316 in ocRunInit_ELF (oc=oc@entry=0x7faf4ea46970) at rts/linker/Elf.c:1886
#2  0x00000000037e98df in ocTryLoad (oc=<optimized out>) at rts/Linker.c:1620
#3  ocTryLoad (oc=0x7faf4eassh246970) at rts/Linker.c:1573
#4  0x00000000037e9963 in loadSymbol (pinfo=0x7faf4ea1e2a0, lbl=0x7faf4f312537 "OPENSSL_cleanse") at rts/Linker.c:892
#5  lookupSymbol_ (lbl=lbl@entry=0x7faf4f312537 "OPENSSL_cleanse") at rts/Linker.c:872
#6  0x00000000038040a9 in do_Elf_Rela_relocations (shnum=2, shdr=0x7faf4f3143a8, ehdrC=0x7faf4f311150 "\177ELF\002\001\001", oc=0x7faf4f38d650) at rts/linker/Elf.c:1476
#7  ocResolve_ELF (oc=oc@entry=0x7faf4f38d650) at rts/linker/Elf.c:1848
#8  0x00000000037e98b3 in ocTryLoad (oc=<optimized out>) at rts/Linker.c:1606
#9  ocTryLoad (oc=0x7faf4f38d650) at rts/Linker.c:1573
#10 0x00000000037e9963 in loadSymbol (pinfo=0x7faf4f390cb0, lbl=0x7faf4f4b9adb "CRYPTO_malloc") at rts/Linker.c:892
#11 lookupSymbol_ (lbl=lbl@entry=0x7faf4f4b9adb "CRYPTO_malloc") at rts/Linker.c:872
#12 0x00000000038040a9 in do_Elf_Rela_relocations (shnum=2, shdr=0x7faf4f4bc7b0, ehdrC=0x7faf4f4b81e0 "\177ELF\002\001\001", oc=0x7faf4f278330) at rts/linker/Elf.c:1476
#13 ocResolve_ELF (oc=oc@entry=0x7faf4f278330) at rts/linker/Elf.c:1848
#14 0x00000000037e98b3 in ocTryLoad (oc=<optimized out>) at rts/Linker.c:1606
#15 ocTryLoad (oc=0x7faf4f278330) at rts/Linker.c:1573
#16 0x00000000037e9963 in loadSymbol (pinfo=0x7faf4f393d90, lbl=0x7faf501f843a "OPENSSL_strlcpy") at rts/Linker.c:892
#17 lookupSymbol_ (lbl=lbl@entry=0x7faf501f843a "OPENSSL_strlcpy") at rts/Linker.c:872
#18 0x00000000038040a9 in do_Elf_Rela_relocations (shnum=2, shdr=0x7faf501f8740, ehdrC=0x7faf501f8000 "\177ELF\002\001\001", oc=0x7faf5480aa70) at rts/linker/Elf.c:1476
#19 ocResolve_ELF (oc=oc@entry=0x7faf5480aa70) at rts/linker/Elf.c:1848
#20 0x00000000037e98b3 in ocTryLoad (oc=<optimized out>) at rts/Linker.c:1606
#21 ocTryLoad (oc=0x7faf5480aa70) at rts/Linker.c:1573
#22 0x00000000037e9b81 in resolveObjs_ () at rts/Linker.c:1650
#23 resolveObjs () at rts/Linker.c:1669
#24 0x00000000034d51c0 in ghcizm8zi8zi4_GHCiziObjLink_resolveObjs1_info ()
#25 0x0000000000000000 in ?? ()
```

### Manually invoking GHC

To help rule out Bazel being the source of the issue and for finer grain control of how GHC is called, it’s helpful to be able to call it directly. We can intercept calls to find out the arguments/flags provided by editing the `$(which ghc)` script.
By adding `for word in ${1+"$@"}; do echo "$word" >> /tmp/ghc-args.txt; done`, running `bazel build //minimal-segfault:example` and then looking in the `/tmp/ghc-args.txt` file, you should get an argument per line. As GHC is called multiple times (i.e. for the other libraries), you will probably see lots of lines for other calls too. As results are cached, if you run the `bazel build` again, this time you should only see the arguments for the failing segfault call. 
We will then want to wrap each line in quotes, as they each represent a single argument.
You should then end up with something like:
``` bash
$(which ghc) \
'-pgma' \
'bazel-out/host/bin/external/rules_haskell/haskell/cc_wrapper-python' \
'-pgmc' \
'bazel-out/host/bin/external/rules_haskell/haskell/cc_wrapper-python' \
'-pgml' \
'bazel-out/host/bin/external/rules_haskell/haskell/cc_wrapper-python' \
'-pgmP' \
'bazel-out/host/bin/external/rules_haskell/haskell/cc_wrapper-python -E -undef -traditional' \
'-optc-fno-stack-protector' \
'-static' \
'-v0' \
'-no-link' \
'-fPIC' \
'-hide-all-packages' \
'-Wmissing-home-modules' \
'-fexternal-dynamic-refs' \
'-odir' \
'bazel-out/k8-fastbuild/bin/minimal-segfault/_obj/example' \
'-hidir' \
'bazel-out/k8-fastbuild/bin/minimal-segfault/minimal-segfaultZSexample/_iface' \
'-optc-U_FORTIFY_SOURCE' \
'-optc-fstack-protector' \
'-optc-Wall' \
'-optc-Wunused-but-set-parameter' \
'-optc-Wno-free-nonheap-object' \
'-optc-fno-omit-frame-pointer' \
'-optc-fno-canonical-system-headers' \
'-optc-Wno-builtin-macro-redefined' \
'-optc-D__DATE__="redacted"' \
'-optc-D__TIMESTAMP__="redacted"' \
'-optc-D__TIME__="redacted"' \
'-opta-U_FORTIFY_SOURCE' \
'-opta-fstack-protector' \
'-opta-Wall' \
'-opta-Wunused-but-set-parameter' \
'-opta-Wno-free-nonheap-object' \
'-opta-fno-omit-frame-pointer' \
'-opta-fno-canonical-system-headers' \
'-opta-Wno-builtin-macro-redefined' \
'-opta-D__DATE__="redacted"' \
'-opta-D__TIMESTAMP__="redacted"' \
'-opta-D__TIME__="redacted"' \
'-Wall' \
'-v4' \
'-hide-all-packages' \
'-fno-version-macros' \
'-package-env' \
'bazel-out/k8-fastbuild/bin/minimal-segfault/compile-package_env-example' \
'-hide-all-plugin-packages' \
'-optP@bazel-out/k8-fastbuild/bin/minimal-segfault/optp_args_example' \
'-this-unit-id' \
'minimal-segfaultZSexample' \
'-optP-DCURRENT_PACKAGE_KEY="minimal-segfaultZSexample"' \
'minimal-segfault/src/Example.hs'
```

Before we can run this though, we need a copy of the sandbox it was expected to run in (which will contain dependencies/build tools). We can use the same “interception” trick again, by temporarily add the following lines and running a `bazel build`:

```bash
mkdir /tmp/sandbox
cp -r . /tmp/sandbox
```

This will make a copy of the sandbox under `/tmp/sandbox`. If we `cd` into this directory, we can now run the earlier GHC command.

## Using haskell_library

```bazel
load("@rules_haskell//haskell:defs.bzl", "haskell_library")

haskell_library(
    name = "ffi",
    srcs = ["FFI.hs"],
    compiler_flags = [
        "-v4",  # Used to help with debugging
    ],
    visibility = ["//visibility:public"],
    deps = [
        "@haskell_nixpkgs_crypto//:c_lib",
        "@stackage//:base",
    ],
)
```

## Possibly related issues

- https://gitlab.haskell.org/ghc/ghc/-/issues/12527
- https://gitlab.haskell.org/ghc/ghc/-/issues/17508
- https://github.com/tweag/rules_haskell/issues/1696
