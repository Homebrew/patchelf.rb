# patchelf.rb

[![Gem Version](https://badge.fury.io/rb/patchelf.svg)](https://badge.fury.io/rb/patchelf)
[![CI](https://github.com/Homebrew/patchelf.rb/actions/workflows/tests.yml/badge.svg)](https://github.com/Homebrew/patchelf.rb/actions/workflows/tests.yml)
[![Coverage](https://codecov.io/gh/Homebrew/patchelf.rb/graph/badge.svg)](https://codecov.io/gh/Homebrew/patchelf.rb)
[![API documentation](https://img.shields.io/badge/API-RubyDoc-blue.svg)](https://www.rubydoc.info/gems/patchelf)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

`patchelf.rb` is a pure-Ruby library and command-line tool for inspecting and
modifying selected fields in ELF executables and shared libraries. It implements
the operations Homebrew needs, but it is not a complete drop-in replacement for
[NixOS/patchelf](https://github.com/NixOS/patchelf).

## Requirements

- Ruby 3.3 or newer.
- An ELF input file. The host running Ruby does not itself need to be Linux.

CI tests the gem on Linux and macOS with Ruby 3.3, 3.4, and 4.0. Tests that
execute patched ELF files run on Linux only. Windows is not currently tested.

## Installation

Install the released gem from RubyGems:

```console
gem install patchelf
```

Or add it to a Bundler-managed project:

```ruby
gem 'patchelf'
```

## Command-line usage

```console
patchelf.rb [OPTIONS] INPUT_FILE [OUTPUT_FILE]
```

If `OUTPUT_FILE` is omitted, the input file is modified in place. In-place
writes are not atomic, so use an explicit output path when the original cannot
be recreated safely.

Run `patchelf.rb --help` for the complete option list. Common operations are:

| Operation | Option |
| --- | --- |
| Print the interpreter | `--print-interpreter`, `--pi` |
| Print needed libraries | `--print-needed`, `--pn` |
| Print `DT_RUNPATH` | `--print-runpath`, `--pr` |
| Print the shared-library name | `--print-soname`, `--ps` |
| Set the interpreter | `--set-interpreter INTERP`, `--interp INTERP` |
| Set all needed libraries | `--set-needed LIB1,LIB2`, `--needed LIB1,LIB2` |
| Add, remove, or replace one needed library | `--add-needed`, `--remove-needed`, `--replace-needed` |
| Set `DT_RUNPATH` | `--set-runpath PATH`, `--runpath PATH` |
| Operate on `DT_RPATH` instead | `--force-rpath` |
| Set the shared-library name | `--set-soname SONAME`, `--so SONAME` |

These examples use Linux paths and tools:

```console
# Inspect an executable.
patchelf.rb --print-interpreter --print-needed /bin/ls

# Write a changed copy instead of modifying the input.
patchelf.rb --runpath '$ORIGIN/../lib' input.elf output.elf

# Replace one DT_NEEDED entry.
patchelf.rb --replace-needed libc.so.6,libcnew.so.6 input.elf output.elf
```

The executable exits non-zero for invalid options, missing arguments, more than
two positional arguments, unreadable inputs, invalid ELF files, and expected
patching failures.

## Library usage

```ruby
require 'patchelf'

patcher = PatchELF::Patcher.new('/path/to/input.elf', on_error: :exception)
puts patcher.interpreter
puts patcher.needed

patcher.interpreter = '/new/dynamic/loader'
patcher.runpath = '$ORIGIN/../lib'
patcher.save('/path/to/output.elf', patchelf_compatible: true)
```

`on_error` controls how missing ELF segments and tags are handled:

- `:log` logs a warning and returns `nil`.
- `:silent` returns `nil` without logging.
- `:exception` raises a `PatchELF` exception.

`Patcher#save` provides two rewriting strategies:

| Strategy | Intended use | Current mutation support |
| --- | --- | --- |
| Default | General-purpose rewriting | Interpreter, needed libraries, RPATH/RUNPATH, and SONAME |
| `patchelf_compatible: true` | Layout behavior closer to NixOS/patchelf | Interpreter and RPATH/RUNPATH |

The compatible saver does not yet implement needed-library or SONAME changes.
Some ELF layouts also require growth operations that are not implemented and
raise `NotImplementedError`. The CLI currently uses the default saver; use the
Ruby API when compatible layout behavior is required.

A patcher keeps its input file open for the lifetime of the object. Avoid
retaining patcher instances in long-running processes after their work is
complete.

`PatchELF::Builder` creates an ELF file from scratch or from an existing file:

```ruby
entry = 0x1000
code = [
  "\xb0\x3c", # mov al, 60
  "\x0f\x05"  # syscall
].join
elf = PatchELF::Builder.new(machine: :x86_64, type: :dyn, entry: entry)
elf.add_section('.dynstr', data: "\x00", type: :strtab, flags: [:alloc])
elf.add_section('.text', data: code, flags: %i[alloc execinstr], addr: entry, offset: entry, align: 64)
pie = [ELFTools::Constants::DT_FLAGS_1, ELFTools::Constants::DF_1_PIE, ELFTools::Constants::DT_NULL, 0].pack('Q<4')
elf.add_section('.dynamic', type: :dynamic, data: pie, flags: [:alloc], align: 8, link: '.dynstr')
abi = [0x00000004, 0x00000010, 0x00000001].pack('L<3') + "GNU\x00" + [0, 4, 4, 0].pack('L<4') # NT_GNU_ABI_TAG Linux 4.4.0
elf.add_section('.note.ABI-tag', type: :note, data: abi, flags: [:alloc], align: 4)
elf.add_section('.bss', type: :nobits, size: 64, addr: 0x2000, flags: %i[alloc write])
elf.save('example')
```

Fixture coverage is primarily x86-64, with a 32-bit x86 regression fixture and
unit coverage for architecture-specific page sizes. Validate rewritten binaries
on every target architecture before distributing them.

Full API documentation is available on
[RubyDoc](https://www.rubydoc.info/gems/patchelf).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for setup, test commands, fixture policy,
and the release-quality checks run in CI.

Bug reports and feature requests belong in
[GitHub Issues](https://github.com/Homebrew/patchelf.rb/issues).

## Security

Please report suspected vulnerabilities through
[GitHub private vulnerability reporting](https://github.com/Homebrew/patchelf.rb/security/advisories/new),
following [Homebrew's security policy](https://github.com/Homebrew/.github/security/policy).
Do not disclose a suspected vulnerability in a public issue before maintainers
have had a reasonable opportunity to investigate it.

## Authors and maintainers

The Git history is the definitive record of contributions.

- Original author and project founder: david942j (`@david942j`)
- Maintainers: Homebrew maintainers and david942j

## License

The gem is available under the [MIT License](LICENSE). Historical third-party
test fixtures retain their upstream terms, documented in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
