[![Downloads](https://img.shields.io/endpoint?url=https://gem-badge-h3lg.onrender.com/downloads/patchelf)](https://rubygems.org/gems/patchelf)

[![Gem Version](https://badge.fury.io/rb/patchelf.svg)](https://badge.fury.io/rb/patchelf)
[![Build Status](https://github.com/david942j/patchelf.rb/workflows/build/badge.svg)](https://github.com/david942j/patchelf.rb/actions)
[![Maintainability](https://qlty.sh/gh/david942j/projects/patchelf.rb/maintainability.svg)](https://qlty.sh/gh/david942j/projects/patchelf.rb)
[![Code Coverage](https://qlty.sh/gh/david942j/projects/patchelf.rb/coverage.svg)](https://qlty.sh/gh/david942j/projects/patchelf.rb)
[![Yard Docs](http://img.shields.io/badge/yard-docs-blue.svg)](https://www.rubydoc.info/github/david942j/patchelf.rb/master)
[![MIT License](https://img.shields.io/badge/license-MIT-blue.svg)](http://choosealicense.com/licenses/mit/)

# patchelf.rb

Implements features of NixOS/patchelf in pure Ruby.

## Installation

Available on RubyGems.org!
```
$ gem install patchelf
```

## Usage

```
$ patchelf.rb
# Usage: patchelf.rb <commands> FILENAME [OUTPUT_FILE]
#         --print-interpreter, --pi    Show interpreter's name.
#         --print-needed, --pn         Show needed libraries specified in DT_NEEDED.
#         --print-runpath, --pr        Show the path specified in DT_RUNPATH.
#         --print-soname, --ps         Show soname specified in DT_SONAME.
#         --set-interpreter, --interp INTERP
#                                      Set interpreter's name.
#         --set-needed, --needed LIB1,LIB2,LIB3
#                                      Set needed libraries, this will remove all existent needed libraries.
#         --add-needed LIB             Append a new needed library.
#         --remove-needed LIB          Remove a needed library.
#         --replace-needed LIB1,LIB2   Replace needed library LIB1 as LIB2.
#         --set-runpath, --runpath PATH
#                                      Set the path of runpath.
#         --force-rpath                According to the ld.so docs, DT_RPATH is obsolete,
#                                      patchelf.rb will always try to get/set DT_RUNPATH first.
#                                      Use this option to force every operations related to runpath (e.g. --runpath)
#                                      to consider 'DT_RPATH' instead of 'DT_RUNPATH'.
#         --set-soname, --so SONAME    Set name of a shared library.
#         --version                    Show current gem's version.

```

### Display information
```
$ patchelf.rb --print-interpreter --print-needed /bin/ls
# interpreter: /lib64/ld-linux-x86-64.so.2
# needed: libselinux.so.1 libc.so.6

```

### Change the dynamic loader (interpreter)
```
# $ patchelf.rb --interp NEW_INTERP input.elf output.elf
$ patchelf.rb --interp /lib/AAAA.so /bin/ls ls.patch

$ file ls.patch
# ls.patch: ELF 64-bit LSB shared object, x86-64, version 1 (SYSV), dynamically linked, interpreter /lib/AAAA.so, for GNU/Linux 3.2.0, BuildID[sha1]=9567f9a28e66f4d7ec4baf31cfbf68d0410f0ae6, stripped

```

### Modify dependency libraries

#### Add
```
$ patchelf.rb --add-needed libnew.so /bin/ls ls.patch
```

#### Remove
```
$ patchelf.rb --remove-needed libc.so.6 /bin/ls ls.patch
```

#### Replace
```
$ patchelf.rb --replace-needed libc.so.6,libcnew.so.6 /bin/ls ls.patch

$ readelf -d ls.patch | grep NEEDED
#  0x0000000000000001 (NEEDED)             Shared library: [libselinux.so.1]
#  0x0000000000000001 (NEEDED)             Shared library: [libcnew.so.6]

```

#### Set directly
```
$ patchelf.rb --needed a.so,b.so,c.so /bin/ls ls.patch

$ readelf -d ls.patch | grep NEEDED
#  0x0000000000000001 (NEEDED)             Shared library: [a.so]
#  0x0000000000000001 (NEEDED)             Shared library: [b.so]
#  0x0000000000000001 (NEEDED)             Shared library: [c.so]

```

### Set RUNPATH of an executable
```
$ patchelf.rb --runpath . /bin/ls ls.patch

$ readelf -d ls.patch | grep RUNPATH
#  0x000000000000001d (RUNPATH)            Library runpath: [.]

```

### Change SONAME of a shared library
```
$ patchelf.rb --so libc.so.217 /lib/x86_64-linux-gnu/libc.so.6 libc.patch

$ readelf -d libc.patch | grep SONAME
#  0x000000000000000e (SONAME)             Library soname: [libc.so.217]

```

### As Ruby library
```rb
require 'patchelf'

patcher = PatchELF::Patcher.new('/bin/ls')
patcher.interpreter
#=> "/lib64/ld-linux-x86-64.so.2"

patcher.interpreter = '/lib/AAAA.so.2'
patcher.interpreter
#=> "/lib/AAAA.so.2"

patcher.save('ls.patch')

# $ file ls.patch
# ls.patch: ELF 64-bit LSB shared object, x86-64, version 1 (SYSV), dynamically linked, interpreter /lib/AAAA.so.2, for GNU/Linux 3.2.0, BuildID[sha1]=9567f9a28e66f4d7ec4baf31cfbf68d0410f0ae6, stripped

```

## Environment

patchelf.rb is implemented in pure Ruby, so it should work in all environments include Linux, macOS, and Windows!

## Project Authors

The git history remains the definitive record of all contributions.

### Original Author and Project Founder

* david942j (@david942j)

### Maintainers

* david942j (@david942j)
