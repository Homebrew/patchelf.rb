# frozen_string_literal: true

require 'stringio'
require 'tempfile'

require 'patchelf'
require 'elftools'

describe PatchELF::Builder do
  def build(**options)
    builder = described_class.new(**options)
    yield builder
    builder
  end

  def build_id_note
    [4, 20, 3].pack('VVV') + "GNU\0".b + ("\xab".b * 20)
  end

  def sym_bytes(*shndxs)
    klass = ELFTools::Structs::ELF_sym[64]
    shndxs.map do |shndx|
      s = klass.new(endian: :little)
      s.st_name = 0
      s.st_info = 0
      s.st_other = 0
      s.st_shndx = shndx
      s.st_value = 0
      s.st_size = 0
      s.to_binary_s
    end.join
  end

  def pie_copy
    described_class.new(StringIO.new(File.binread(bin_path('pie.elf'))))
  end

  def pie_elf
    ELFTools::ELFFile.new(StringIO.new(File.binread(bin_path('pie.elf'))))
  end

  def parse(bytes)
    ELFTools::ELFFile.new(StringIO.new(bytes))
  end

  def build_elf
    build(machine: :x86_64, type: :dyn, entry: 0x400000) do |b|
      b.add_section('.text', data: "\x90\xc3".b, addr: 0x400000, flags: %i[alloc execinstr], align: 16)
      b.add_section('.rodata', data: 'ro'.b, addr: 0x401000, flags: %i[alloc], align: 8)
      b.add_section('.note.gnu.build-id', data: build_id_note, type: :note, flags: %i[alloc], addr: 0x401020)
      b.add_section('.data', data: 'hi'.b, addr: 0x402000, flags: %i[alloc write], align: 8)
      b.add_section('.bss', type: :nobits, size: 64, flags: %i[alloc write], addr: 0x402068, align: 8)
      b.add_section('.dynamic', data: "\x00".b * 32, type: :dynamic, flags: %i[alloc write], addr: 0x402048,
                                align: 8)
      b.add_symbol('pie.c', type: :file, bind: :local, section: :abs)
      b.add_symbol('helper', type: :func, bind: :local, value: 0x400000, size: 2, section: '.text')
      b.add_symbol('main', type: :func, value: 0x400000, size: 2, section: '.text')
      b.add_symbol('_heap', value: 0x403000, section: :abs)
      b.add_symbol('puts')
      b.add_segment(type: :note, covers: %w[.note.gnu.build-id], flags: %i[r])
      b.add_segment(type: :dynamic, covers: %w[.dynamic], flags: %i[r w])
      b.add_segment(type: :gnu_stack, flags: %i[r w], offset: 0, vaddr: 0, filesz: 0, align: 0x10)
      b.add_segment(type: :phdr, flags: %i[r], offset: 64, vaddr: 0x40, filesz: 56 * 7, align: 8)
    end
  end

  it 'builds a small ELF that reopens byte-identically' do
    elf = build_elf
    expect(elf).not_to be_a(ELFTools::ELFFile)
    expect(elf.elf_class).to be 64
    expect(elf.endian).to be :little
    view = elf.to_elf
    expect(view.header.e_machine.to_i).to eq ELFTools::Constants::EM_X86_64
    expect(view.elf_type).to eq 'DYN'
    expect(view.header.e_entry.to_i).to eq 0x400000
    expect(view.num_sections).to eq 10
    expect(view.num_segments).to eq 7
    expect(view.section_by_name('.text').data).to eq "\x90\xc3".b
    expect(view.section_by_name('.rodata').data).to eq 'ro'.b
    expect(view.section_by_name('.data').data).to eq 'hi'.b
    expect(view.section_by_name('.bss').header.sh_size.to_i).to eq 64
    expect(view.build_id).to eq 'ab' * 20
    expect(view.dynamic).not_to be_nil

    symtab = view.section_by_name('.symtab')
    expect(symtab.header.sh_info.to_i).to eq 3 # null + 2 locals before the globals
    main = symtab.symbol_by_name('main')
    expect(main.value).to eq 0x400000
    expect(main.type_name).to eq 'STT_FUNC'
    expect(main.bind_name).to eq 'STB_GLOBAL'
    expect(main.section_index).to eq 1 # .text, after NULL
    expect(symtab.symbol_by_name('pie.c').type_name).to eq 'STT_FILE'
    expect(symtab.symbol_by_name('_heap').value).to eq 0x403000
    expect(symtab.symbol_by_name('puts').section_index).to be 0

    loads = view.segments_by_type(:load)
    expect(loads.size).to eq 3
    text_seg = loads.find { |s| s.header.p_vaddr.to_i == 0x400000 }
    expect(text_seg.header.p_filesz.to_i).to eq 2
    data_seg = loads.find { |s| s.header.p_vaddr.to_i == 0x402000 }
    expect(data_seg.header.p_memsz.to_i - data_seg.header.p_filesz.to_i).to eq 64 # the .bss tail
    expect(view.segment_by_type(:note)).not_to be_nil

    reopened = parse(elf.to_s)
    expect(reopened.section_by_name('.text').data).to eq "\x90\xc3".b
    expect(reopened.header.e_entry.to_i).to eq 0x400000
  end

  it 'copies from stream, path, ELFFile and Builder' do
    source_elf = build_elf
    elf = described_class.new(StringIO.new(source_elf.to_s))
    expect(elf.to_s).to eq source_elf.to_s
    view = elf.to_elf
    source_view = source_elf.to_elf
    expect(view.sections.map(&:name)).to eq source_view.sections.map(&:name)
    expect(view.section_by_name('.bss').header.sh_size.to_i).to eq 64
    expect(view.build_id).to eq source_view.build_id
    expect(view.header.e_entry.to_i).to eq source_view.header.e_entry.to_i

    io = StringIO.new
    io.binmode
    elf.write(io)
    io.rewind
    expect(io.read).to eq elf.to_s

    Tempfile.create(['elf', '.bin']) do |f|
      source_elf.write(f.path)
      from_path = described_class.new(f.path)
      path_view = from_path.to_elf
      expect(path_view.section_by_name('.text').data).to eq "\x90\xc3".b
      expect(path_view.num_segments).to eq 7
    end
    from_elf = described_class.new(parse(source_elf.to_s))
    expect(from_elf.to_elf.header.e_entry.to_i).to eq 0x400000
    from_builder = described_class.new(source_elf)
    expect(from_builder.to_s).to eq source_elf.to_s
    overridden = described_class.new(StringIO.new(source_elf.to_s), entry: 0x1234, type: :exec)
    overridden_view = overridden.to_elf
    expect(overridden_view.header.e_entry.to_i).to eq 0x1234
    expect(overridden_view.elf_type).to eq 'EXEC'

    elf.add_section('.extra', data: 'e'.b)
    view = elf.to_elf
    expect(view.section_by_name('.extra').data).to eq 'e'.b
    expect(view.section_by_name('.text').data).to eq "\x90\xc3".b
    expect(view.num_sections).to eq source_view.num_sections + 1
    expect(view.segments_by_type(:load).size).to eq source_view.segments_by_type(:load).size
  end

  it 'rejects bad header options' do
    expect { described_class.new }.to raise_error(ArgumentError, /machine is required/)
    expect { described_class.new(machine: :nope) }.to raise_error(ArgumentError, /EM/)
    expect { described_class.new(machine: :x86_64, elf_class: 48) }.to raise_error(ArgumentError, /elf_class/)
    expect { described_class.new(machine: :x86_64, endian: :middle) }.to raise_error(ArgumentError, /endian/)
    expect { described_class.new(machine: :x86_64, type: :nope) }.to raise_error(ArgumentError, /ET/)
    expect do
      described_class.new(machine: :x86_64, bogus: 1)
    end.to raise_error(ArgumentError, /unknown option/)
  end

  it 'rejects bad section input' do
    expect do
      build(machine: :x86_64) do |b|
        b.add_section('.text', data: 'x'.b)
        b.add_section('.text', data: 'y'.b)
      end
    end.to raise_error(ArgumentError, /already added/)
    expect do
      build(machine: :x86_64) { |b| b.add_section('.bss', data: "\x00".b, size: 1) }
    end.to raise_error(ArgumentError, /data: or size:/)
    expect do
      build(machine: :x86_64) { |b| b.add_section('', data: 'a'.b) }
    end.to raise_error(ArgumentError, /non-empty String/)
    expect do
      build(machine: :x86_64) { |b| b.add_section("a\x00b", data: 'a'.b) }
    end.to raise_error(ArgumentError, /without null bytes/)
    expect do
      build(machine: :x86_64) { |b| b.add_section('.a', data: 'a'.b, link: :bogus) }
    end.to raise_error(ArgumentError, /link must be/)
    expect do
      build(machine: :x86_64) { |b| b.add_section('.a', data: 'a'.b, addr: 'x') }
    end.to raise_error(ArgumentError, /addr must be/)
    expect do
      build(machine: :x86_64) { |b| b.add_section('.a', type: :nobits, data: 'a'.b, size: 1) }
    end.to raise_error(ArgumentError, /not both/)
    expect do
      build(machine: :x86_64) { |b| b.add_section('.a', type: :nobits, size: -1) }
    end.to raise_error(ArgumentError, /non-negative Integer/)
    expect do
      build(machine: :x86_64) { |b| b.add_section('.a', data: 'a'.b, bogus: 1) }
    end.to raise_error(ArgumentError, /unknown option/)
    expect do
      build(machine: :x86_64) { |b| b.add_section('.a', data: 'a'.b, foo: 1, bar: 2) }
    end.to raise_error(ArgumentError, /unknown options.*:foo.*:bar/)
    expect do
      build(machine: :x86_64) { |b| b.add_section('.a', data: 'a'.b, link: '.missing') }.to_s
    end.to raise_error(ArgumentError, /unknown section/)
  end

  it 'rejects bad symbol input' do
    expect do
      build(machine: :x86_64) { |b| b.add_symbol('orphan', section: '.nope') }.to_s
    end.to raise_error(ArgumentError, /unadded section/)
    expect do
      build(machine: :x86_64) { |b| b.add_symbol("a\x00b") }
    end.to raise_error(ArgumentError, /without null bytes/)
    expect do
      build(machine: :x86_64) { |b| b.add_symbol('a', value: -1) }
    end.to raise_error(ArgumentError, /Symbol value must be/)
    expect do
      build(machine: :x86_64) { |b| b.add_symbol('a', section: :bogus) }
    end.to raise_error(ArgumentError, /SHN/)
    expect do
      build(machine: :x86_64) { |b| b.add_symbol('a', bogus: 1) }
    end.to raise_error(ArgumentError, /unknown option/)
  end

  it 'rejects bad segment input' do
    expect do
      build(machine: :x86_64) do |b|
        b.add_segment(type: :load, covers: %w[.nope], flags: %i[r x])
      end.to_s
    end.to raise_error(ArgumentError, /unknown section/)
    expect do
      build(machine: :x86_64) do |b|
        b.add_section('.text', data: "\x90".b)
        b.add_segment(type: :load, flags: %i[r x])
      end.to_s
    end.to raise_error(ArgumentError, /needs offset, vaddr, filesz/)
    expect do
      build(machine: :x86_64) { |b| b.add_segment(type: :load, covers: [], flags: %i[r x]) }.to_s
    end.to raise_error(ArgumentError, /covers no sections/)
    expect do
      build(machine: :x86_64) { |b| b.skip_segment(:bogus) }
    end.to raise_error(ArgumentError, /PT/)
    expect do
      build(machine: :x86_64) { |b| b.add_segment(type: :load, covers: 123, flags: %i[r]) }
    end.to raise_error(ArgumentError, /covers must be/)
    expect do
      build(machine: :x86_64) { |b| b.add_segment(type: :note, covers: :all, bogus: 1) }
    end.to raise_error(ArgumentError, /unknown option/)
  end

  it 'rejects bad removal' do
    expect do
      build(machine: :x86_64) { |b| b.remove_section('.nope') }
    end.to raise_error(ArgumentError, /no such section/)
    expect do
      build(machine: :x86_64) { |b| b.remove_segment(:note) }
    end.to raise_error(ArgumentError, /no such .* segment/)
  end

  it 'rejects bad layout' do
    expect do
      build(machine: :x86_64) do |b|
        b.add_section('.a', data: 'aa'.b, offset: 0x100)
        b.add_section('.b', data: 'b'.b, offset: 0x101)
      end.to_s
    end.to raise_error(ArgumentError, /overlaps/)
    expect do
      build(machine: :x86_64) { |b| b.add_section('.a', data: 'aa'.b, align: 2, offset: 0x101) }.to_s
    end.to raise_error(ArgumentError, /multiple of its alignment/)
    expect do
      build(machine: :x86_64, type: :exec, entry: 0x401000) do |b|
        b.add_section('.text', data: "\x90".b, addr: 0x401000, flags: %i[alloc execinstr], offset: 0x100)
      end.to_s
    end.to raise_error(ArgumentError, /mismatches vaddr/)
  end

  it 'derives segment bounds from covers' do
    elf = build(machine: :x86_64) do |b|
      b.add_section('.a', data: 'aa'.b, align: 2048)
      b.add_section('.b', data: 'bbbbb'.b, align: 1024)
      b.add_segment(type: :load, flags: %i[r], covers: :all)
    end
    view = elf.to_elf
    expect(view.segments_by_type(:load).length).to eq 2
    seg = view.segments_by_type(:load).find { |s| s.header.p_offset.to_i == 2048 }
    expect(seg.header.p_offset.to_i).to eq 2048
    expect(seg.header.p_memsz.to_i).to eq 1024 + 5
    expect(seg.header.p_filesz.to_i).to eq 1024 + 5

    explicit = build(machine: :x86_64) do |b|
      b.add_section('.text', data: "\x90".b, addr: 0x400000, flags: %i[alloc execinstr])
      b.add_segment(type: :load, covers: %w[.text], offset: 0x200, vaddr: 0x400000, filesz: 1, memsz: 0x1234,
                    paddr: 0x400100, flags: %i[r x])
    end
    header = explicit.to_elf.segments_by_type(:load).find { |s| s.header.p_vaddr.to_i == 0x400000 }.header
    expect([header.p_offset.to_i, header.p_vaddr.to_i, header.p_filesz.to_i,
            header.p_memsz.to_i, header.p_paddr.to_i]).to eq [0x200, 0x400000, 1, 0x1234, 0x400100]

    lone = build(machine: :x86_64) do |b|
      b.add_section('.text', data: "\x90".b)
      b.add_segment(type: :load, flags: %i[r], covers: '.text')
    end
    lone_view = lone.to_elf
    expect(lone_view.segments_by_type(:load).find { |s| !s.header.p_offset.to_i.zero? }.header.p_filesz.to_i).to eq 1

    sparse = build(machine: :x86_64) do |b|
      b.add_section('.a', data: 'aa', addr: 0x1000, flags: %i[alloc], offset: 0x1000)
      b.add_section('.b', data: 'b', addr: 0x1001, flags: %i[alloc], offset: 0x2000)
      b.add_segment(type: :load, flags: %i[r], covers: %w[.a .b])
    end
    sparse_view = sparse.to_elf
    load = sparse_view.segments_by_type(:load).find { |s| !s.header.p_offset.to_i.zero? }
    expect(load.header.p_filesz.to_i).to eq 0x1001
    expect(load.header.p_memsz.to_i).to eq 0x1001
  end

  it 'copies preserve explicit segment bounds' do
    source = build(machine: :x86_64) do |b|
      b.add_section('.text', data: "\x90" * 16, addr: 0x400000)
      b.add_section('.bss', type: :nobits, size: 64, addr: 0x401000, flags: %i[alloc write])
      b.add_segment(type: :load, flags: %i[r w], offset: 0x100, vaddr: 0x400000, filesz: 0x10, memsz: 0x2000)
    end
    nobits = described_class.new(StringIO.new(source.to_s))
    nobits_view = nobits.to_elf
    seg = nobits_view.segments_by_type(:load).find { |s| s.header.p_vaddr.to_i == 0x400000 }
    expect(seg.header.p_offset.to_i).to eq 0x100
    expect(seg.header.p_filesz.to_i).to eq 0x10
    expect(seg.header.p_memsz.to_i).to eq 0x2000
    expect(nobits_view.section_by_name('.bss').header.sh_size.to_i).to eq 64
  end

  it 'defaults missing addresses to file offsets, entry to the lowest one' do
    elf = build(machine: :x86_64) do |b|
      b.add_section('.text', data: "\x90" * 3, flags: %i[alloc execinstr], align: 16)
      b.add_section('.rodata', data: 'ro', flags: %i[alloc], align: 8)
      b.add_section('.comment', data: 'c')
      b.add_section('.data', data: 'd', addr: 0x1000, flags: %i[alloc write])
      b.add_section('.bss', type: :nobits, size: 16, flags: %i[alloc write], align: 16)
    end
    view = elf.to_elf
    offsets = view.sections.to_h { |s| [s.name, s.header.sh_offset.to_i] }
    addrs = view.sections.to_h { |s| [s.name, s.header.sh_addr.to_i] }
    expect(addrs.values_at('.text', '.rodata', '.bss')).to eq(
      [offsets['.text'], offsets['.rodata'], offsets['.bss']]
    )
    expect(addrs['.comment']).to be 0
    expect(addrs['.data']).to eq 0x1000
    expect(view.header.e_entry.to_i).to eq offsets['.text']

    rw = view.segments_by_type(:load).find { |s| !s.header.p_offset.to_i.zero? && s.header.p_flags.to_i == 6 }
    expect(rw.header.p_offset.to_i).to eq 0x1000
    expect(rw.header.p_vaddr.to_i).to eq 0x1000
    expect(rw.header.p_memsz.to_i).to eq offsets['.bss'] + 16 - 0x1000
  end

  it 'derives loads' do
    elf = build(machine: :x86_64, type: :exec, entry: 0x401000) do |b|
      b.add_section('.text', data: "\x90".b, addr: 0x401000, flags: %i[alloc execinstr])
      b.add_section('.rodata', data: 'r'.b, addr: 0x402000, flags: %i[alloc])
      b.add_section('.interp', data: "/lib/ld.so\x00".b, addr: 0x402100, flags: %i[alloc])
      b.add_section('.data', data: 'd'.b, addr: 0x403000, flags: %i[alloc write])
      b.add_section('.bss', type: :nobits, size: 64, addr: 0x403008, flags: %i[alloc write])
      b.add_section('.dynamic', data: "\x00".b * 16, type: :dynamic, flags: %i[alloc write], addr: 0x403100,
                                link: '.dynstr')
      b.add_section('.comment', data: 'c'.b)
      b.add_section('.note.one', data: 'n1'.b, type: :note)
      b.add_section('.note.two', data: 'n2'.b, type: :note)
      b.add_section('.dynstr', data: "\x00".b, type: :strtab)
    end
    view = elf.to_elf
    off = ->(name) { view.section_by_name(name).header.sh_offset.to_i }

    loads = view.segments_by_type(:load)
    expect(loads.size).to eq 4
    expect(loads.map { |s| s.header.p_flags.to_i }.sort).to eq [4, 4, 5, 6]
    loads.each do |load|
      offset = load.header.p_offset.to_i
      vaddr = load.header.p_vaddr.to_i
      align = load.header.p_align.to_i
      expect((offset - vaddr) % align).to be 0
    end
    by_flags = loads.reject { |s| s.header.p_offset.to_i.zero? }
                    .to_h { |s| [s.header.p_flags.to_i, s.header.p_vaddr.to_i] }
    expect(by_flags).to eq(5 => 0x401000, 4 => 0x402000, 6 => 0x403000)
    expect(view.header.e_phnum.to_i).to eq 9
    expect(view.segments.first.header.p_type.to_i).to eq ELFTools::Constants::PT_PHDR

    text_offset = off.call('.text')
    phdr = view.segment_by_type(:phdr)
    expect(phdr.header.p_flags.to_i).to eq ELFTools::Constants::PF_R
    expect(phdr.header.p_offset.to_i).to eq 64
    expect(phdr.header.p_filesz.to_i).to eq 9 * 56
    header = view.segments[1]
    expect(header.header.p_type.to_i).to eq ELFTools::Constants::PT_LOAD
    expect(header.header.p_flags.to_i).to eq ELFTools::Constants::PF_R
    expect(header.header.p_offset.to_i).to eq 0
    expect(header.header.p_vaddr.to_i).to eq 0x401000 - text_offset
    expect(header.header.p_filesz.to_i).to eq 64 + (view.header.e_phnum.to_i * 56)
    expect(header.header.p_memsz.to_i).to eq header.header.p_filesz.to_i
    expect(phdr.header.p_vaddr.to_i).to eq header.header.p_vaddr.to_i + 64
    expect(phdr.header.p_offset.to_i).to be >= header.header.p_offset.to_i
    expect(phdr.header.p_offset.to_i + phdr.header.p_filesz.to_i).to be <= header.header.p_filesz.to_i
    header_end = header.header.p_offset.to_i + header.header.p_filesz.to_i
    loads.each do |load|
      next if load.header.p_offset.to_i.zero?

      expect(load.header.p_offset.to_i).to be >= header_end
    end

    interp = view.segment_by_type(:interp)
    expect(interp.header.p_flags.to_i).to eq ELFTools::Constants::PF_R
    expect(interp.header.p_offset.to_i).to eq off.call('.interp')
    expect(interp.header.p_filesz.to_i).to eq 11

    dynamic = view.segment_by_type(:dynamic)
    expect(dynamic.header.p_flags.to_i).to eq ELFTools::Constants::PF_R | ELFTools::Constants::PF_W
    expect(dynamic.header.p_offset.to_i).to eq off.call('.dynamic')
    expect(dynamic.header.p_filesz.to_i).to eq 16
    expect(view.section_by_name('.dynamic').header.sh_link.to_i).to eq view.sections.map(&:name).index('.dynstr')

    notes = view.segments_by_type(:note)
    expect(notes.size).to eq 2
    expect(notes.map { |s| s.header.p_offset.to_i }.sort).to eq [off.call('.note.one'), off.call('.note.two')].sort

    r_load = loads.find { |s| !s.header.p_offset.to_i.zero? && s.header.p_flags.to_i == ELFTools::Constants::PF_R }
    interp_offset = off.call('.interp')
    expect(interp_offset).to be >= r_load.header.p_offset.to_i
    expect(interp_offset).to be < r_load.header.p_offset.to_i + r_load.header.p_filesz.to_i

    copied = described_class.new(StringIO.new(elf.to_s))
    expect(copied.to_s).to eq elf.to_s
  end

  it 'emits no segments for rel files' do
    rel = build(machine: :x86_64, type: :rel) do |b|
      b.add_section('.text', data: "\x90".b, flags: %i[alloc execinstr])
      b.add_section('.dynamic', data: "\x00".b * 16, type: :dynamic)
    end
    rel_view = rel.to_elf
    expect(rel_view.section_by_name('.text').header.sh_addr.to_i).to be 0
    expect(rel_view.header.e_entry.to_i).to be 0
    expect(rel_view.dynamic).to be rel_view.section_by_name('.dynamic')
    expect(rel_view.num_segments).to be 0
    bare = build(machine: :x86_64, type: :exec) { |b| b.add_section('.text', data: "\x90".b) }
    expect(bare.to_elf.dynamic).to be_nil
  end

  it 'splits derived loads at permission changes' do
    elf = build(machine: :x86_64, type: :exec, entry: 0x401000) do |b|
      b.add_section('.text', data: "\x90".b, addr: 0x401000, flags: %i[alloc execinstr])
      b.add_section('.rodata', data: 'r'.b, addr: 0x402000, flags: %i[alloc])
      b.add_section('.text2', data: "\x90".b, addr: 0x403000, flags: %i[alloc execinstr])
    end
    view = elf.to_elf
    rx = view.segments_by_type(:load).select { |s| s.header.p_flags.to_i == 5 }
    expect(rx.size).to eq 2
    expect(rx.map { |s| s.header.p_vaddr.to_i }).to contain_exactly(0x401000, 0x403000)
    rx.each { |load| expect(load.header.p_memsz.to_i).to eq 1 }

    rodata = view.section_by_name('.rodata').header.sh_addr.to_i
    rx.each do |load|
      range = load.header.p_vaddr.to_i...(load.header.p_vaddr.to_i + load.header.p_memsz.to_i)
      expect(range).not_to cover(rodata)
    end
  end

  it 'maps headers below alloc sections when none is non-alloc' do
    elf = build(machine: :x86_64, type: :exec, entry: 0x401000) do |b|
      b.add_section('.text', data: "\x90".b, addr: 0x401000, flags: %i[alloc execinstr])
      b.add_section('.shstrtab', data: "\x00.shstrtab\x00.text\x00".b, type: :strtab, flags: %i[alloc],
                                 addr: 0x402000)
    end
    view = elf.to_elf
    header = view.segments_by_type(:load).find { |s| s.header.p_offset.to_i.zero? }
    expect(header.header.p_vaddr.to_i).to eq 0x401000 - view.section_by_name('.text').header.sh_offset.to_i
    table = view.segments_by_type(:load).find { |s| s.header.p_vaddr.to_i == 0x402000 }
    expect(table.header.p_offset.to_i).to eq view.section_by_name('.shstrtab').header.sh_offset.to_i
    expect(view.section_by_name('.shstrtab').header.sh_addr.to_i).to eq 0x402000
  end

  it 'records NOBITS sizes without allocating their bytes' do
    elf = build(machine: :x86_64, type: :exec, entry: 0x401000) do |b|
      b.add_section('.text', data: "\x90".b, addr: 0x401000, flags: %i[alloc execinstr])
      s = b.add_section('.bss', type: :nobits, size: 0x4000_0000, addr: 0x402000, flags: %i[alloc write])
      expect(s.data.bytesize).to be 0
    end
    view = elf.to_elf
    expect(view.section_by_name('.bss').header.sh_size.to_i).to eq 0x4000_0000
    expect(elf.to_s.bytesize).to be < 0x10000

    recopied = described_class.new(StringIO.new(elf.to_s))
    recopied_view = recopied.to_elf
    expect(recopied_view.section_by_name('.bss').header.sh_size.to_i).to eq 0x4000_0000
    expect(recopied.to_s.bytesize).to be < 0x10000
    expect(recopied.to_s).to eq elf.to_s

    from_data = build(machine: :x86_64, type: :exec, entry: 0x401000) do |b|
      b.add_section('.text', data: "\x90".b, addr: 0x401000, flags: %i[alloc execinstr])
      b.add_section('.bss', type: :nobits, data: 'abcd'.b, flags: %i[alloc write])
    end
    from_data_view = from_data.to_elf
    expect(from_data_view.section_by_name('.bss').header.sh_size.to_i).to eq 4
    expect(from_data.to_s.bytesize).to be < 0x10000
  end

  it 'lays out non-loaded nobits without reserving memory' do
    elf = build(machine: :x86_64, type: :rel) do |b|
      b.add_section('.text', data: "\x90".b, flags: %i[alloc execinstr])
      b.add_section('.bss', type: :nobits, size: 64)
      b.add_section('.comment', data: 'c'.b)
    end
    view = elf.to_elf
    bss = view.section_by_name('.bss').header
    expect(bss.sh_size.to_i).to eq 64
    expect(bss.sh_addr.to_i).to eq 0
    expect(view.section_by_name('.comment').data).to eq 'c'.b
  end

  it 'fills size: sections with zeros' do
    sized = build(machine: :x86_64) { |b| b.add_section('.z', size: 3) }
    expect(sized.to_elf.section_by_name('.z').data).to eq "\x00\x00\x00".b
  end

  it 'places auto-addressed sections after NOBITS memory' do
    elf = build(machine: :x86_64, type: :exec, entry: 0x401000) do |b|
      b.add_section('.text', data: "\x90".b, addr: 0x401000, flags: %i[alloc execinstr])
      b.add_section('.bss', type: :nobits, size: 64, flags: %i[alloc write])
      b.add_section('.data', data: 'd'.b, flags: %i[alloc write])
    end
    view = elf.to_elf
    bss = view.section_by_name('.bss').header
    data = view.section_by_name('.data').header
    expect(data.sh_addr.to_i).to eq bss.sh_addr.to_i + bss.sh_size.to_i
    expect(view.section_by_name('.data').data).to eq 'd'.b
    expect(elf.to_s.byteslice(bss.sh_offset.to_i, bss.sh_size.to_i)).to eq "\x00".b * 64

    load = view.segments_by_type(:load).find { |s| s.header.p_flags.to_i == 6 }
    expect(load.header.p_vaddr.to_i).to eq bss.sh_addr.to_i
    expect(load.header.p_memsz.to_i).to eq bss.sh_size.to_i + 1
    expect((load.header.p_offset.to_i - load.header.p_vaddr.to_i) % load.header.p_align.to_i).to be 0
  end

  it 'works with 32-bit big-endian file' do
    elf = build(machine: :arm, elf_class: 32, endian: :big, type: :exec, entry: 0x8000) do |b|
      b.add_section('.text', data: "\xe3\xa0\x00\x00".b, addr: 0x8000, flags: %i[alloc execinstr])
      b.add_section('.dynamic', data: "\x00".b * 16, type: :dynamic, flags: %i[alloc write])
      b.add_symbol('start', type: :func, value: 0x8000, size: 4, section: '.text')
    end
    bytes = elf.to_s
    expect(bytes[0, 4]).to eq ELFTools::Constants::ELFMAG
    expect(bytes[4].ord).to eq 1 # ELFCLASS32
    expect(bytes[5].ord).to eq 2 # ELFDATA2MSB
    view = elf.to_elf
    expect(view.header.e_machine.to_i).to eq ELFTools::Constants::EM_ARM
    expect(view.section_by_name('.symtab').symbol_by_name('start').value).to eq 0x8000
    expect(view.segment_by_type(:dynamic).header.p_align.to_i).to eq 4
    phdr = view.segment_by_type(:phdr)
    expect([phdr.header.p_offset.to_i, phdr.header.p_filesz.to_i, phdr.header.p_align.to_i]).to eq [52, 5 * 32, 4]
  end

  it 'uses the target page size for derived loads' do
    elf = build(machine: :aarch64, type: :exec, entry: 0x401000) do |b|
      b.add_section('.text', data: "\x90".b, addr: 0x401000, flags: %i[alloc execinstr])
    end
    view = elf.to_elf
    loads = view.segments_by_type(:load)
    expect(loads.map { |s| s.header.p_align.to_i }).to all(eq(0x10000))
    loads.each do |load|
      expect((load.header.p_offset.to_i - load.header.p_vaddr.to_i) % 0x10000).to be 0
    end
  end

  it 'skip_segment suppresses derived ones' do
    elf = build(machine: :x86_64) do |b|
      b.add_section('.interp', data: '/x'.b, flags: %i[alloc])
      b.add_section('.note.a', data: 'a'.b, type: :note)
      b.add_segment(type: :interp, covers: %w[.interp], flags: %i[r])
      b.add_segment(type: :note, covers: %w[.note.a], flags: %i[r])
      b.skip_segment(:interp)
    end
    view = elf.to_elf
    expect(view.segments_by_type(:interp).size).to eq 1
    expect(view.segments_by_type(:note).size).to eq 1
    expect(view.segments_by_type(:load).size).to eq 2
    expect(view.segments_by_type(:phdr).size).to eq 1
    expect(view.header.e_phnum.to_i).to eq 5
    header = view.segments_by_type(:load).find { |s| s.header.p_offset.to_i.zero? }
    expect(header.header.p_vaddr.to_i).to eq 0
    expect(header.header.p_filesz.to_i).to eq 64 + (view.header.e_phnum.to_i * 56)

    elf = build(machine: :x86_64, type: :dyn, entry: 0x1000) do |b|
      b.add_section('.text', data: "\x90".b, addr: 0x1000, flags: %i[alloc execinstr])
      b.add_section('.interp', data: "/lib/ld.so\x00".b, flags: %i[alloc])
      b.add_section('.dynamic', data: "\x00".b * 16, type: :dynamic, flags: %i[alloc write])
      b.add_section('.note.a', data: 'a'.b, type: :note)
      b.skip_segment(:interp, :dynamic, :note)
    end
    view = elf.to_elf
    expect(view.segment_by_type(:interp)).to be_nil
    expect(view.segment_by_type(:dynamic)).to be_nil
    expect(view.segments_by_type(:note)).to be_empty
    expect(view.header.e_phnum.to_i).to eq 5
    expect(view.segments_by_type(:load).size).to eq 4
    expect(view.segments_by_type(:phdr).size).to eq 1
  end

  it 'skip_segment drops whole derived tables' do
    phdrless = build(machine: :x86_64, type: :exec, entry: 0x401000) do |b|
      b.add_section('.text', data: "\x90".b, addr: 0x401000, flags: %i[alloc execinstr])
      b.skip_segment(:phdr)
    end
    phdrless_view = phdrless.to_elf
    expect(phdrless_view.segments_by_type(:phdr)).to be_empty
    expect(phdrless_view.segments_by_type(:load).size).to eq 1
    expect(phdrless_view.header.e_phnum.to_i).to eq 1

    loadless = build(machine: :x86_64, type: :exec, entry: 0x401000) do |b|
      b.add_section('.text', data: "\x90".b, addr: 0x401000, flags: %i[alloc execinstr])
      b.add_section('.note', data: 'n'.b, type: :note)
      b.skip_segment(:load)
    end
    loadless_view = loadless.to_elf
    expect(loadless_view.segments_by_type(:load).size).to eq 1
    expect(loadless_view.header.e_phoff.to_i).not_to be_zero
    expect(loadless_view.header.e_phnum.to_i).to eq 3
  end

  it 'supports dropping sections' do
    elf = build(machine: :x86_64, type: :exec, entry: 0x401000) do |b|
      b.add_section('.text', data: "\x90".b, addr: 0x401000, flags: %i[alloc execinstr])
      b.add_section('.comment', data: 'c'.b)
      b.add_segment(type: :load, covers: %w[.text .comment], flags: %i[r])
    end
    expect(elf.to_elf.num_sections).to eq 4
    elf.remove_section('.comment')
    view = elf.to_elf
    expect(view.section_by_name('.comment')).to be_nil
    expect(view.num_sections).to eq 3
    load = view.segments_by_type(:load).find { |s| !s.header.p_offset.to_i.zero? }
    expect(load.header.p_filesz.to_i).to eq 1
  end

  it 'supports dropping segments' do
    elf = build(machine: :x86_64, type: :exec, entry: 0x401000) do |b|
      b.add_section('.text', data: "\x90".b, addr: 0x401000, flags: %i[alloc execinstr])
      b.add_section('.comment', data: 'c'.b)
      b.add_segment(type: :load, covers: %w[.text .comment], flags: %i[r])
    end
    elf.add_segment(type: :load, covers: %w[.text], flags: %i[r x])
    elf.remove_segment(:load)
    view = elf.to_elf
    expect(view.segments_by_type(:load).size).to eq 1
    expect(view.header.e_phnum.to_i).to eq 2

    noted = build(machine: :x86_64, type: :exec, entry: 0x401000) do |b|
      b.add_section('.text', data: "\x90".b, addr: 0x401000, flags: %i[alloc execinstr])
      b.add_section('.note.a', data: 'a'.b, type: :note)
      b.add_segment(type: :note, covers: %w[.note.a], flags: %i[r])
      b.remove_segment(:note)
    end
    noted_view = noted.to_elf
    expect(noted_view.segments_by_type(:note)).to be_empty
    expect(noted_view.header.e_phnum.to_i).to eq 3
  end

  it 'assembles on demand and round-trips entry' do
    elf = build(machine: :x86_64, type: :exec) do |b|
      b.add_section('.text', data: "\x90".b, addr: 0x401000, flags: %i[alloc execinstr])
    end
    expect(elf.to_elf.num_sections).to eq 3
    elf.add_section('.extra', data: 'e'.b)
    view = elf.to_elf
    expect(view.num_sections).to eq 4
    expect(view.section_by_name('.extra').data).to eq 'e'.b

    expect(parse(elf.to_s).header.e_entry.to_i).to eq 0x401000

    io = StringIO.new(+''.b)
    elf.write(io)
    expect(parse(io.string).header.e_entry.to_i).to eq 0x401000

    Tempfile.create(['rebuilt', '.bin']) do |f|
      elf.save(f.path)
      expect(parse(File.binread(f.path)).header.e_entry.to_i).to eq 0x401000
    end
  end

  it 'reindexes references when dropping a section' do
    elf = pie_copy
    elf.remove_section('.shstrtab') # index 28: nothing links it, no symbol lives in it
    reopened = parse(elf.to_s)

    names = reopened.sections.map(&:name)
    expect(reopened.section_by_name('.symtab').header.sh_link.to_i).to eq names.index('.strtab')
    expect(reopened.section_by_name('.dynamic').header.sh_link.to_i).to eq names.index('.dynstr')
    expect(names[reopened.section_by_name('.rela.plt').header.sh_info.to_i]).to eq '.got'

    main = reopened.section_by_name('.symtab').symbol_by_name('main')
    expect(names[main.section_index]).to eq '.text'
    cout = reopened.section_by_name('.dynsym').symbol_by_name('_ZSt4cout')
    expect(names[cout.section_index]).to eq '.bss'
    abs = reopened.section_by_name('.symtab').symbol_by_name('crtstuff.c')
    expect(abs.section_index).to eq ELFTools::Constants::SHN_ABS
    expect(reopened.dynamic).not_to be_nil
  end

  it 'refreshes copied PT_PHDR bounds when the segment count changes' do
    copied = pie_copy.to_elf.segment_by_type(:phdr)
    orig = pie_elf.segment_by_type(:phdr)
    expect([copied.header.p_offset, copied.header.p_vaddr, copied.header.p_filesz,
            copied.header.p_memsz].map(&:to_i)).to eq(
              [orig.header.p_offset, orig.header.p_vaddr, orig.header.p_filesz, orig.header.p_memsz].map(&:to_i)
            )

    elf = pie_copy
    elf.remove_segment(:interp)
    view = elf.to_elf
    phdr = view.segment_by_type(:phdr)
    expect(view.header.e_phnum.to_i).to eq 8
    expect(phdr.header.p_offset.to_i).to eq 64
    expect(phdr.header.p_vaddr.to_i).to eq 0x40
    expect(phdr.header.p_filesz.to_i).to eq 8 * 56
    expect(phdr.header.p_memsz.to_i).to eq 8 * 56
  end

  it 'keeps a divergent PHDR memsz when refreshing its size' do
    elf = build(machine: :x86_64, type: :exec, entry: 0x401000) do |b|
      b.add_section('.text', data: "\x90".b, addr: 0x401000, flags: %i[alloc execinstr])
      b.add_section('.note.a', data: 'a'.b, type: :note)
      b.add_segment(type: :note, covers: %w[.note.a], flags: %i[r])
      b.add_segment(type: :phdr, flags: %i[r], offset: 64, vaddr: 0x40, filesz: 56 * 3, memsz: 9999, align: 8)
    end
    elf.remove_segment(:note)
    view = elf.to_elf
    phdr = view.segment_by_type(:phdr)
    expect(view.header.e_phnum.to_i).to eq 2
    expect(phdr.header.p_filesz.to_i).to eq 2 * 56
    expect(phdr.header.p_memsz.to_i).to eq 9999
  end

  it 'rejects dropping a section others still reference' do
    elf = pie_copy
    expect { elf.remove_section('.strtab') }.to raise_error(ArgumentError, /links to it/)
    expect { elf.remove_section('.dynsym') }.to raise_error(ArgumentError, /links to it/)
    expect { elf.remove_section('.got') }.to raise_error(ArgumentError, /apply to it/)
    expect { elf.remove_section('.text') }.to raise_error(ArgumentError, /defined in it/)
    expect { elf.remove_section('.bss') }.to raise_error(ArgumentError, /defined in it/)

    fresh = pie_copy
    expect(elf.to_s).to eq fresh.to_s
  end

  it 'rejects dropping a section a new symbol is defined in' do
    elf = build(machine: :x86_64) do |b|
      b.add_section('.text', data: "\x90".b, flags: %i[alloc execinstr])
      b.add_section('.data', data: 'd'.b, flags: %i[alloc write])
      b.add_symbol('main', type: :func, value: 0, size: 1, section: '.text')
      b.add_symbol('orphan')
    end
    expect { elf.remove_section('.text') }.to raise_error(ArgumentError, /symbol "main" is defined in it/)
    expect(elf.remove_section('.data')).not_to be_nil
    expect(elf.to_elf.section_by_name('.symtab').symbol_by_name('main')).not_to be_nil

    indexed = build(machine: :x86_64, type: :rel) do |b|
      b.add_section('.victim', data: 'v'.b)
      b.add_symbol('y', section: 1)
    end
    expect { indexed.remove_section('.victim') }.to raise_error(ArgumentError, /symbol "y" is defined in it/)
  end

  it 'removes added symbols by name' do
    elf = build(machine: :x86_64) do |b|
      b.add_section('.text', data: "\x90".b, flags: %i[alloc execinstr])
      b.add_symbol('main', type: :func, value: 0, size: 1, section: '.text')
      b.add_symbol('helper', type: :func, value: 0, size: 1, section: '.text')
      b.add_symbol('dup', value: 0, section: '.text')
      b.add_symbol('dup', value: 1, section: '.text')
    end
    expect(elf.remove_symbol('main').map(&:name)).to eq ['main']
    expect { elf.remove_symbol('main') }.to raise_error(ArgumentError, /no such symbol/)
    expect(elf.remove_symbol('dup').size).to eq 2
    view = elf.to_elf
    expect(view.section_by_name('.symtab').symbol_by_name('main')).to be_nil
    expect(view.section_by_name('.symtab').symbol_by_name('helper')).not_to be_nil

    elf.remove_symbol('helper')
    expect(elf.remove_section('.text')).not_to be_nil
    expect(elf.to_elf.section_by_name('.symtab')).to be_nil
  end

  it 'coerces integer-like options' do
    elf = build(machine: :x86_64, type: :rel) do |b|
      b.add_section('.a', data: 'a'.b, align: '16')
      b.add_section('.n', data: 'n'.b, type: :note)
      b.add_symbol('s', value: '0x10', size: '2', section: '.a')
      b.add_segment(type: :note, covers: %w[.n], flags: %i[r], align: '1')
    end
    view = elf.to_elf
    expect(view.section_by_name('.a').header.sh_addralign.to_i).to eq 16
    expect(view.section_by_name('.symtab').symbol_by_name('s').value).to eq 16
    expect(view.segments_by_type(:note).first.header.p_align.to_i).to eq 1
    expect { build(machine: :x86_64) { |b| b.add_section('.a', data: 'a'.b, align: 1.5) } }
      .to raise_error(ArgumentError, /must be an Integer/)
    expect { build(machine: :x86_64) { |b| b.add_symbol('s', value: 'xyz') } }
      .to raise_error(ArgumentError, /must be an Integer/)
    expect { build(machine: :x86_64) { |b| b.add_section('.a', data: 'a'.b, align: nil) } }
      .to raise_error(ArgumentError, /must be an Integer/)
  end

  it 'rejects dangling numeric references at build time' do
    expect do
      build(machine: :x86_64, type: :rel) { |b| b.add_section('.a', data: 'a'.b, link: 99) }.to_s
    end.to raise_error(ArgumentError, /unknown section index/)
    expect do
      build(machine: :x86_64, type: :rel) do |b|
        b.add_section('.a', data: 'a'.b)
        b.add_section('.rel', type: :rela, data: "\x00".b * 24, info: 99)
      end.to_s
    end.to raise_error(ArgumentError, /unknown section index/)
    expect do
      build(machine: :x86_64, type: :rel) do |b|
        b.add_section('.a', data: 'a'.b)
        b.add_symbol('x', section: 9)
      end.to_s
    end.to raise_error(ArgumentError, /unknown section index/)
  end

  it 'slides integer symbol references when dropping a section' do
    elf = build(machine: :x86_64, type: :rel) do |b|
      b.add_section('.a', data: 'a'.b)
      b.add_section('.victim', data: 'v'.b)
      b.add_section('.c', data: 'c'.b)
      b.add_symbol('early', section: 1)
      b.add_symbol('x', section: 3)
      b.add_symbol('abs', section: :abs)
    end
    elf.remove_section('.victim')
    view = elf.to_elf
    symtab = view.section_by_name('.symtab')
    expect(view.sections[symtab.symbol_by_name('early').section_index].name).to eq '.a'
    x = symtab.symbol_by_name('x')
    expect(view.sections[x.section_index].name).to eq '.c'
    abs = symtab.symbol_by_name('abs')
    expect(abs.section_index).to eq ELFTools::Constants::SHN_ABS
  end

  it 'refuses copies with duplicate or unnamed sections' do
    raw = File.binread(bin_path('pie.elf'))
    src = parse(raw)
    shoff = src.header.e_shoff.to_i
    shentsize = src.header.e_shentsize.to_i
    duped = raw.dup
    duped[(shoff + (2 * shentsize)), 4] = [src.sections[1].header.sh_name.to_i].pack('V')
    expect { described_class.new(StringIO.new(duped)) }.to raise_error(ArgumentError, /duplicate section name/)

    unnamed = raw.dup
    unnamed[(shoff + (2 * shentsize)), 4] = [0].pack('V')
    expect { described_class.new(StringIO.new(unnamed)) }.to raise_error(ArgumentError, /has no name/)
  end

  it 'rejects dropping a section a symbolic link still names' do
    elf = build(machine: :x86_64) do |b|
      b.add_section('.b', data: 'b'.b)
      b.add_section('.a', data: 'a'.b, link: '.b')
    end
    expect { elf.remove_section('.b') }.to raise_error(ArgumentError, /"\.a" links to it/)
    expect(elf.remove_section('.a')).not_to be_nil
    expect(elf.remove_section('.b')).not_to be_nil
    expect(elf.to_elf.section_by_name('.b')).to be_nil
  end

  it 'drops the static tables for a strip-like copy' do
    elf = pie_copy
    elf.remove_section('.symtab')
    elf.remove_section('.strtab')
    reopened = parse(elf.to_s)

    expect(reopened.section_by_name('.symtab')).to be_nil
    expect(reopened.section_by_name('.strtab')).to be_nil
    cout = reopened.section_by_name('.dynsym').symbol_by_name('_ZSt4cout')
    expect(reopened.sections[cout.section_index].name).to eq '.bss'
    fresh = pie_elf
    expect(reopened.section_by_name('.text').data).to eq fresh.section_by_name('.text').data
    expect(reopened.dynamic).not_to be_nil

    elf.add_symbol('extra')
    expect(elf.to_elf.section_by_name('.symtab').symbol_by_name('extra').value).to eq 0
  end

  it 'shifts recorded symbol indices, group members and extended indices' do
    elf = build(machine: :x86_64) do |b|
      b.add_section('.a', data: 'a'.b)
      b.add_section('.victim', data: 'v'.b)
      b.add_section('.b', data: 'b'.b)
      b.add_section('.strtab', data: "\x00".b, type: :strtab)
      b.add_section('.symtab', type: :symtab, data: sym_bytes(0, 1, 3, 0xfff1),
                               link: '.strtab', info: 1, entsize: 24)
      b.add_section('.g', type: :group, data: [1, 1, 3].pack('L<3'))
      b.add_section('.x', type: :symtab_shndx, data: [0, 1, 3].pack('L<3'))
    end
    elf.remove_section('.victim')
    reopened = parse(elf.to_s)

    expect(reopened.section_by_name('.symtab').data).to eq sym_bytes(0, 1, 2, 0xfff1)
    expect(reopened.section_by_name('.g').data.unpack('L<*')).to eq [1, 1, 2]
    expect(reopened.section_by_name('.x').data.unpack('L<*')).to eq [0, 1, 2]

    grouped = build(machine: :x86_64) do |b|
      b.add_section('.a', data: 'a'.b)
      b.add_section('.victim', data: 'v'.b)
      b.add_section('.g', type: :group, data: [1, 2].pack('L<2'))
    end
    expect { grouped.remove_section('.victim') }.to raise_error(ArgumentError, /contains it/)

    indexed = build(machine: :x86_64) do |b|
      b.add_section('.a', data: 'a'.b)
      b.add_section('.victim', data: 'v'.b)
      b.add_section('.x', type: :symtab_shndx, data: [0, 2].pack('L<2'))
    end
    expect { indexed.remove_section('.victim') }.to raise_error(ArgumentError, /defined in it/)
  end

  it 'slides pending link and reloc info on removal' do
    elf = build(machine: :x86_64, type: :rel) do |b|
      b.add_section('.a', data: 'a'.b, link: 3)
      b.add_section('.victim', data: 'v'.b)
      b.add_section('.target', data: 't'.b)
      b.add_section('.rel', type: :rela, data: "\x00".b * 24, link: '.target', info: 3)
    end
    elf.remove_section('.victim')
    view = elf.to_elf
    names = view.sections.map(&:name)
    expect(view.section_by_name('.a').header.sh_link.to_i).to eq names.index('.target')
    rel = view.section_by_name('.rel').header
    expect(rel.sh_link.to_i).to eq names.index('.target')
    expect(names[rel.sh_info.to_i]).to eq '.target'
  end

  it 'remaps group members on big-endian files' do
    elf = build(machine: :arm, elf_class: 32, endian: :big) do |b|
      b.add_section('.a', data: 'a'.b)
      b.add_section('.victim', data: 'v'.b)
      b.add_section('.b', data: 'b'.b)
      b.add_section('.g', type: :group, data: [1, 1, 3].pack('L>3'))
    end
    elf.remove_section('.victim')
    reopened = parse(elf.to_s)
    expect(reopened.section_by_name('.g').data.unpack('L>*')).to eq [1, 1, 2]
  end

  it 'keeps copied segment bounds instead of deriving them' do
    src = build(machine: :x86_64, type: :exec, entry: 0x401000) do |b|
      b.add_section('.text', data: "\x90".b, addr: 0x401000, flags: %i[alloc execinstr], offset: 0x1000)
      b.add_section('.data', data: 'd'.b, addr: 0x402000, flags: %i[alloc write], offset: 0x2000)
      b.add_segment(type: :load, flags: %i[r x], offset: 0x1000, vaddr: 0x401000, paddr: 0x401100,
                    filesz: 0x1010, memsz: 0x1010, align: 0x1000)
    end
    elf = described_class.new(StringIO.new(src.to_s))

    view = elf.to_elf
    load = view.segments_by_type(:load).find { |s| s.header.p_flags.to_i == 5 && !s.header.p_offset.to_i.zero? }
    expect([load.header.p_offset.to_i, load.header.p_filesz.to_i, load.header.p_vaddr.to_i,
            load.header.p_memsz.to_i, load.header.p_paddr.to_i]).to eq [0x1000, 0x1010, 0x401000, 0x1010, 0x401100]
    expect(elf.to_s).to eq src.to_s

    elf.remove_section('.data')
    view = elf.to_elf
    shrunk = view.segments_by_type(:load).find { |s| s.header.p_flags.to_i == 5 && !s.header.p_offset.to_i.zero? }
    expect([shrunk.header.p_offset.to_i, shrunk.header.p_filesz.to_i,
            shrunk.header.p_vaddr.to_i]).to eq [0x1000, 1, 0x401000]
  end

  it 'extends copied shstrtab when adding sections' do
    src = build(machine: :x86_64, type: :exec, entry: 0x401000) do |b|
      b.add_section('.note', data: 'n'.b, type: :note, offset: 0x2000)
      b.add_section('.text', data: "\x90".b, addr: 0x401000, flags: %i[alloc execinstr], offset: 0x1000)
    end
    elf = described_class.new(StringIO.new(src.to_s))
    elf_view = elf.to_elf
    src_view = src.to_elf
    expect(elf_view.section_by_name('.text').header.sh_offset.to_i).to eq 0x1000
    expect(elf_view.section_by_name('.note').header.sh_offset.to_i).to eq 0x2000
    expect(elf_view.section_by_name('.shstrtab').data).to eq src_view.section_by_name('.shstrtab').data
    expect(elf.to_s).to eq src.to_s

    elf.add_section('.extra', data: 'e'.b)
    shstrtab = src_view.section_by_name('.shstrtab').data
    elf_view = elf.to_elf
    expect(elf_view.section_by_name('.shstrtab').data).to eq shstrtab + '.extra'.b + "\x00".b
    expect(elf_view.section_by_name('.extra').header.sh_name.to_i).to eq shstrtab.bytesize
    elf_text = elf_view.section_by_name('.text').header
    src_text = src_view.section_by_name('.text').header
    expect(elf_text.sh_name.to_i).to eq src_text.sh_name.to_i
    expect(elf_text.sh_offset.to_i).to eq 0x1000
  end

  it 'reuses a fully-supplied shstrtab' do
    custom = build(machine: :x86_64) do |b|
      b.add_section('.text', data: "\x90".b, flags: %i[alloc])
      b.add_section('.rodata', data: 'r'.b, flags: %i[alloc])
      b.add_section('.shstrtab', data: "\x00.shstrtab\x00.rodata\x00.text\x00".b, type: :strtab)
    end
    custom_view = custom.to_elf
    expect(custom_view.section_by_name('.shstrtab').data).to eq "\x00.shstrtab\x00.rodata\x00.text\x00".b
    expect(custom_view.section_by_name('.shstrtab').header.sh_name.to_i).to eq 1
    expect(custom_view.section_by_name('.text').header.sh_name.to_i).to eq 19
    expect(custom_view.section_by_name('.rodata').header.sh_name.to_i).to eq 11
    expect(custom_view.header.e_shstrndx.to_i).to eq custom_view.num_sections - 1
    expect(custom_view.section_by_name('.text').data).to eq "\x90".b
  end

  it 'merges missing names into a supplied shstrtab' do
    merged = build(machine: :x86_64) do |b|
      b.add_section('.text', data: "\x90".b)
      b.add_section('.shstrtab', data: "\x00.shstrtab\x00".b, type: :strtab)
    end
    merged_view = merged.to_elf
    expect(merged_view.section_by_name('.shstrtab').data).to eq "\x00.shstrtab\x00.text\x00".b
    expect(merged_view.section_by_name('.text').header.sh_name.to_i).to eq 11

    unterminated = build(machine: :x86_64) do |b|
      b.add_section('.text', data: "\x90".b)
      b.add_section('.shstrtab', data: "\x00.shstrtab".b, type: :strtab)
    end
    unterminated_view = unterminated.to_elf
    expect(unterminated_view.section_by_name('.shstrtab').data).to eq "\x00.shstrtab\x00.text\x00".b
    expect(unterminated_view.section_by_name('.text').header.sh_name.to_i).to eq 11
  end

  it 'keeps symbol sections when .shstrtab is supplied first' do
    elf = build(machine: :x86_64) do |b|
      b.add_section('.shstrtab', data: "\x00.shstrtab\x00.text\x00".b, type: :strtab)
      b.add_section('.text', data: "\x90".b, flags: %i[alloc execinstr])
      b.add_symbol('func', type: :func, value: 0x401000, size: 1, section: '.text')
    end
    view = elf.to_elf
    names = view.sections.map(&:name)
    expect(names.index('.shstrtab')).to be < names.index('.text')
    func = view.section_by_name('.symtab').symbol_by_name('func')
    expect(view.sections[func.section_index].name).to eq '.text'
    expect(view.header.e_shstrndx.to_i).to eq names.index('.shstrtab')
  end

  it 're-resolves symbolic links on every build' do
    builder = build(machine: :x86_64) do |b|
      b.add_section('.dynstr', data: "\x00".b, type: :strtab)
      b.add_section('.mine', data: 'm'.b, link: '.strtab')
      b.add_symbol('x')
    end
    first = builder.to_elf
    expect(first.section_by_name('.mine').header.sh_link.to_i).to eq first.sections.map(&:name).index('.strtab')

    builder.add_section('.late', data: 'y'.b)
    view = builder.to_elf
    expect(view.section_by_name('.mine').header.sh_link.to_i).to eq view.sections.map(&:name).index('.strtab')
  end

  it 'rejects adding symbols when .strtab / .symtab already present' do
    recorded = build(machine: :x86_64, type: :exec, entry: 0x400000) do |b|
      b.add_section('.strtab', data: "\x00main\x00".b, type: :strtab)
      b.add_section('.symtab', type: :symtab, data: "\x00".b * 24, link: '.strtab', info: 1, entsize: 24)
      b.add_symbol('main')
    end
    expect { recorded.to_s }.to raise_error(ArgumentError, /already added/)

    reversed = build(machine: :x86_64) { |b| b.add_symbol('early') }
    reversed.add_section('.symtab', type: :symtab, data: "\x00".b * 24)
    expect { reversed.to_s }.to raise_error(ArgumentError, /already added/)

    copied = pie_copy
    copied.add_symbol('extra')
    expect { copied.to_s }.to raise_error(ArgumentError, /already added/)
  end
end
