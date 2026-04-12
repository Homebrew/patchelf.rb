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
SHELL_OUTPUT_OF(patchelf.rb)
```

### Display information
```
SHELL_OUTPUT_OF(patchelf.rb --print-interpreter --print-needed /bin/ls)
```

### Change the dynamic loader (interpreter)
```
# $ patchelf.rb --interp NEW_INTERP input.elf output.elf
SHELL_OUTPUT_OF(patchelf.rb --interp /lib/AAAA.so /bin/ls ls.patch)
SHELL_OUTPUT_OF(file ls.patch)
SHELL_EXEC(rm -f ls.patch)
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
SHELL_OUTPUT_OF(patchelf.rb --replace-needed libc.so.6,libcnew.so.6 /bin/ls ls.patch)
SHELL_OUTPUT_OF(readelf -d ls.patch | grep NEEDED)
SHELL_EXEC(rm -f ls.patch)
```

#### Set directly
```
SHELL_OUTPUT_OF(patchelf.rb --needed a.so,b.so,c.so /bin/ls ls.patch)
SHELL_OUTPUT_OF(readelf -d ls.patch | grep NEEDED)
SHELL_EXEC(rm -f ls.patch)
```

### Set RUNPATH of an executable
```
SHELL_OUTPUT_OF(patchelf.rb --runpath . /bin/ls ls.patch)
SHELL_OUTPUT_OF(readelf -d ls.patch | grep RUNPATH)
SHELL_EXEC(rm -f libc.patch)
```

### Change SONAME of a shared library
```
SHELL_OUTPUT_OF(patchelf.rb --so libc.so.217 /lib/x86_64-linux-gnu/libc.so.6 libc.patch)
SHELL_OUTPUT_OF(readelf -d libc.patch | grep SONAME)
SHELL_EXEC(rm -f libc.patch)
```

### As Ruby library
```rb
require 'patchelf'

DEFINE_PATCHER(/bin/ls)
RUBY_OUTPUT_OF(patcher.interpreter)
RUBY_EVAL(patcher.interpreter = '/lib/AAAA.so.2')
RUBY_OUTPUT_OF(patcher.interpreter)
RUBY_EVAL(patcher.save('ls.patch'))

# SHELL_OUTPUT_OF(file ls.patch)
SHELL_EXEC(rm ls.patch)
```

## Environment

patchelf.rb is implemented in pure Ruby, so it should work in all environments include Linux, macOS, and Windows!

## Project Authors

The git history remains the definitive record of all contributions.

### Original Author and Project Founder

* david942j (@david942j)

### Maintainers

* david942j (@david942j)
