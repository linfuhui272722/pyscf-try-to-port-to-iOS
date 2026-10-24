# PySCF on iOS

A port of PySCF to iOS: an embedded quantum-chemistry engine plus a native
SwiftUI front end. Built entirely from a Linux host — no Mac, no Xcode, no
Apple-proprietary toolchain.

**Status: beta.** The app builds, links and validates as a real iOS binary, and
the Python engine passes its test suite. It has **not** been run on a device or
simulator, because neither is available on the Linux build host. See
[Limitations](#limitations).

## What this adds

Everything below is additive. The upstream PySCF source tree is untouched.

| Path | What it is |
|---|---|
| `ios/PySCF/` | SwiftUI app: molecule builder, results, orbital and density views |
| `ios/PySCF/Engine/` | `PythonBridge` — boots embedded CPython, speaks JSON-RPC |
| `ios/native/` | C acceleration extension for the SCF hot paths |
| `src/pyscf_mobile/` | Mobile engine layer, plus vendored pure-Python shims |
| `scripts/` | Cross-compilation pipeline and validators |
| `tests/` | Engine and shim test suites |

## Architecture

```
SwiftUI views
     |  AppModel
     v
PySCFEngine (Swift)
     |  JSON-RPC over stdin/stdout
     v
PythonBridge (Swift) --boots--> embedded CPython 3.13
                                    |
                                    v
                              PySCF + NumPy + accel ext
```

The app never links Python statically into Swift. `PythonBridge` starts an
interpreter inside the app bundle and talks to it over a line-delimited
JSON-RPC channel, so the Swift side and the chemistry side stay decoupled.

Ten bridge methods are implemented and covered by contract fixtures:
`capabilities`, `status`, `presets`, `elements`, `geometry`, `scf`, `dft`,
`mp2`, `ccsd`, `bond_scan`.

## Building

Requirements: a Linux host (x86_64 or aarch64), `curl`, `tar`, `cmake`, a C/C++
toolchain, and about 8 GB of free disk.

```bash
scripts/setup-ios-toolchain.sh   # iPhoneOS 15.6 SDK + Darwin cross-toolchain
scripts/fetch-swift-ios.sh       # Swift 5.6 for Linux (provides ld64.lld)
scripts/build-numpy-ios.sh       # NumPy for arm64 iOS
scripts/build-pyscf-ios.sh       # PySCF + libcint + libxc + native ext
scripts/build-ios-app.sh         # assemble PySCF.app
```

Each step is incremental and skips work already done. Downloads are pinned to
specific releases and checksum-verified:

| Artefact | Source | Version |
|---|---|---|
| iPhoneOS15.6.sdk | `theos/sdks` | `master-146e41f` |
| Darwin toolchain | `L1ghtmann/llvm-project` | `test-210562a` |
| Swift 5.6 | `download.swift.org` | `swift-5.6-RELEASE` |

The result is `build/products/ios-arm64/PySCF.app` — arm64, iOS 15.6 minimum,
ad-hoc signed.

## Verifying

```bash
python3 tests/run_tests.py        # engine + shim suites  -> 51/51
scripts/check-bridge-contract.sh  # Swift <-> Python wire format -> 62/62
scripts/validate-ios-app.sh       # bundle structure + dependency closure -> 30/30
```

`validate-ios-app.sh` checks the Mach-O platform and minimum OS version, that
every `LC_LOAD_DYLIB` resolves inside the bundle, and that no build-host paths
leaked into the payload.

## How the cross-compilation works

Apple's toolchain cannot run on Linux, so this uses open-source replacements:

* **Compiler** — Clang 11 from the L1ghtmann Darwin cross-toolchain.
* **Linker** — `ld64.lld` from the Swift 5.6 toolchain. LLD 13 is required: it
  is the last version that accepts `-platform_version ios`. LLD 17 refuses to
  link for iOS at all.
* **SDK** — theos' mirror of the iPhoneOS 15.6 SDK, providing headers, `.tbd`
  stubs and Swift interfaces.

`install_name_tool` in that toolchain is a no-op — it exits zero without
modifying anything. Load commands must therefore be correct at link time; a
binary cannot be fixed up afterwards. This is why the build passes explicit
`-install_name` and rpath flags rather than post-processing.

`AGENTS.md` records the non-obvious constraints that cost real debugging time.

## Limitations

* **Never executed on iOS.** The build host is Linux; there is no simulator or
  device. Correctness here means "builds, links, and passes static and
  host-side checks" — not "runs correctly on a phone".
* **Not App Store installable.** Ad-hoc signed only. Needs a real signing
  identity, a provisioning profile, and a device test before that is possible.
* **The release `.ipa` is unsigned** and is published for inspection. It cannot
  be installed on a stock device without re-signing.
* **Reduced feature set.** The mobile engine targets single-molecule SCF/DFT/
  MP2/CCSD on modest basis sets. PySCF's periodic, relativistic and
  post-HF machinery is not wired up.
* **arm64 device only.** No simulator slice is built.

## Reporting issues

This fork is for the iOS port. Upstream PySCF bugs belong at
[pyscf/pyscf](https://github.com/pyscf/pyscf/issues). Issues with the iOS layer
are welcome here.

---

<div align="left">
  <img src="https://github.com/pyscf/pyscf-doc/blob/master/logo/pyscf-logo.png" height="80px"/>
</div>

Python-based Simulations of Chemistry Framework
-----------------------------------------------
[![Build Status](https://github.com/pyscf/pyscf/workflows/CI/badge.svg)](https://github.com/pyscf/pyscf/actions?query=workflow%3ACI)
[![codecov](https://codecov.io/gh/pyscf/pyscf/branch/master/graph/badge.svg)](https://codecov.io/gh/pyscf/pyscf)

2026-07-17

* [Stable release 2.14.0](https://github.com/pyscf/pyscf/releases/tag/v2.14.0)
* [Changelog](../master/CHANGELOG)
* [Documentation](http://www.pyscf.org)
* [Installation](#installation)
* [Features](../master/FEATURES)
* [News](https://pyscf.org/news.html): **3rd PySCF Developers Meeting!**


# Installation

* Install stable release:

        pip install pyscf

* New features developed in recent years are available in the pyscf-forge package:

        pip install pyscf-forge

* Certain modules are maintained as extensions of PySCF, such as dispersion,
  dmrgscf, fciqmc, icmpspt, properties, semiempirical, shciscf ... (more on
  https://github.com/pyscf) can be installed using pip:

        pip install pyscf[all]

  An individual extension can be installed:

        pip install pyscf[dispersion]

* More details of custom installation can be found in
  [installation manual](http://pyscf.org/user/install.html#build-from-source)


# Citing PySCF

## Base PySCF
The following paper should be cited in publications utilizing the PySCF program package:

[The Python simulations of chemistry framework: 10 years of an open-source quantum chemistry project](https://doi.org/10.1063/5.0337441),
Qiming Sun, Matthew R Hermes, Xiaojie Wu, Huanchen Zhai, Xing Zhang, Abdelrahman M. Ahmed, Juan José Aucar, Oliver J. Backhouse, Samragni Banerjee, Peng Bao, Nikolay A. Bogdanov, Kyle Bystrom, Frédéric Chapoton, Ning-Yuan Chen, Ivan Yu. Chernyshov, Helen S. Clifford, Sander Cohen-Janes, Zhi-Hao Cui, Yann D. Damour, Nike Dattani, Linus Bjarne Dittmer, Sebastian Ehlert, Janus Juul Eriksen, Francesco A. Evangelista, Simon A. Ewing, Ardavan Farahvash, Kevin Focke, Yang Gao, Kevin E. Gasperich, Nathan Gillispie, Jonas Greiner, Matthew R. Hennefarth, Jan Hermann, Christopher Hillenbrand, Joonatan Huhtasalo, Basil Ibrahim, Bhavnesh Jangid, Alireza Nejati Javaremi, Andrew J. Jenkins, Yu Jin, Daniel S. King, Derk Pieter Kooi, Jo S. Kurian, Henrik R. Larsson, Bryan Tak Gwong Lau, Seunghoon Lee, Susi Lehtola, Chenghan Li, Hao Li, Jiachen Li, Rui Li, Shuhang Li, Aleksandr O. Lykhin, Ankit Mahajan, Nastasia Mauger, Pablo del Mazo-Sevillano, Jonathan Moussa, Kousuke Nakano, Verena A. Neufeld, Linqing Peng, Hung Q. Pham, Peter Pinski, Pavel Pokhilko, Zhichen Pu, Yubing Qian, Stephen Jon Quiton, Wanja T. Schulze, Thais R. Scott, Aniruddha Seal, James D. Serna, James E. T. Smith, Kori E. Smyser, Terrence Stahl, Chong Sun, Kevin J. Sung, Egor Trushin, Shiv Upadhyay, Ethan A. Vo, Thijs Vogels, Shirong Wang, Tai Wang, Xiao Wang, Xubo Wang, Yuanheng Wang, Mark Williamson, Junjie Yang, Hong-Zhou Ye, Chia-Nan Yeh, Haiyang Yu, Jincheng Yu, Victor Wen-zhe Yu, Chaoqun Zhang, Dayou Zhang, Yichi Zhang, Zijun Zhao, Zehao Zhou, Andrew J. Zhu, Tianyu Zhu, Timothy C. Berkelbach, Laura Gagliardi , Sandeep Sharma, Alexander Sokolov, Garnet Kin-Lic Chan,
*J. Chem. Phys.*, **165**, 102502 (2026). doi:[10.1063/5.0337441](https://doi.org/10.1063/5.0337441)

## Density functional calculations

As PySCF does not implement density functionals, instead employing external libraries to handle their evaluation, these libraries should also be cited in publications employing PySCF for density functional calculations.

If your calculation employed Libxc, cite

[Recent developments in libxc — A comprehensive library of functionals for density functional theory](https://doi.org/10.1016/j.softx.2017.11.002),
Susi Lehtola, Conrad Steigemann, Micael J.T. Oliveira, and Miguel A.L. Marques,
*SoftwareX* **7**, 1 (2018). doi:[10.1016/j.softx.2017.11.002](https://doi.org/10.1016/j.softx.2017.11.002)

If your calculation employed XCFun, cite

[Arbitrary-order density functional response theory from automatic differentiation](https://doi.org/10.1021/ct100117s),
Ulf Ekström, Lucas Visscher, Radovan Bast, Andreas J. Thorvaldsen, and Kenneth Ruud,
*J. Chem. Theory Comput.* **6**, 1971 (2010). doi:[10.1021/ct100117s](https://doi.org/10.1021/ct100117s)

# Bug reports and feature requests

Please submit tickets on the [issues](https://github.com/pyscf/pyscf/issues) page.

