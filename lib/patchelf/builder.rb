# frozen_string_literal: true

require 'stringio'

require 'elftools/constants'
require 'elftools/elf_file'
require 'elftools/structs'
require 'elftools/util'

require 'patchelf/helper'
require 'patchelf/string_table'

module PatchELF
  # Builds an ELF file.
  #
  # Add sections, segments and symbols with {#add_section}, {#add_segment}
  # and {#add_symbol}, or drop them with {#remove_section}, {#remove_segment}
  # and {#remove_symbol}. Automatic segments can be opted out of with
  # {#skip_segment}.
  # Inspect the result with {#to_elf}, write it out with {#to_s}, {#write} or {#save}.
  class Builder
    # Added with {#add_section}.
    Section = Struct.new(:name, :data, :type, :flags, :addr, :align,
                         :link, :info, :entsize, :pinned_offset,
                         :offset, :index, :name_offset, :sh_size,
                         keyword_init: true)

    # Added with {#add_segment}.
    Segment = Struct.new(:type, :flags, :covers, :offset, :vaddr, :paddr,
                         :filesz, :memsz, :align, keyword_init: true)

    # Added with {#add_symbol}.
    Symbol = Struct.new(:name, :value, :sym_size, :info, :other, :section,
                        keyword_init: true)

    # @return [Integer] 32 or 64.
    attr_reader :elf_class
    # @return [Symbol] +:little+ or +:big+.
    attr_reader :endian

    # Instantiate {Builder} empty or as a copy of +source+.
    # Anything passed explicitly overrides +source+ copy.
    # @param [#read, String, ELFTools::ELFFile, Builder, nil] source
    #   An ELF to copy: a stream, a path, an ELFTools::ELFFile, or a {Builder}.
    # @option opts [Integer, Symbol, String] :machine
    #   An ELFTools::Constants::EM name (+:x86_64+) or value.
    # @option opts [Integer] :elf_class 32 or 64.
    # @option opts [:little, :big] :endian
    # @option opts [Integer, Symbol, String] :type
    #   An ELFTools::Constants::ET name or value.
    # @option opts [Integer, nil] :entry
    #   Entry point address. Defaults to the lowest loaded address.
    # @option opts [Integer] :flags +e_flags+.
    # @option opts [Integer] :osabi +EI_OSABI+.
    # @option opts [Integer] :abiversion +EI_ABIVERSION+.
    # @raise [ArgumentError] If +machine+ is missing without +source+.
    # @raise [ArgumentError] If +elf_class+ is not 32 or 64, +endian+ is not
    #   +:little+ or +:big+, or +machine+ or +type+ names nothing.
    # @example Copy an ELF, then add .extra section.
    #   builder = PatchELF::Builder.new(File.open('/bin/cat', 'rb'))
    #   builder.add_section('.extra', data: 'extra'.b)
    #   builder.save('cat.extra')
    def initialize(source = nil, **opts)
      source = normalize_source(source)
      opts = source_defaults(source).merge(opts)
      machine = opts.delete(:machine)
      raise ArgumentError, 'machine is required when no source is given' if machine.nil?

      elf_class = opts.delete(:elf_class) || 64
      endian = opts.delete(:endian) || :little
      type = opts.delete(:type) || :exec
      check_header(elf_class, endian)

      @pending_machine = resolve_value(ELFTools::Constants::EM, machine)
      @pending_type = resolve_value(ELFTools::Constants::ET, type)
      check_unknown_opts!(opts, %i[entry flags osabi abiversion], 'Builder.new')
      @pending_entry = opts[:entry]
      @pending_flags = opts.fetch(:flags, 0)
      @pending_osabi = opts.fetch(:osabi, 0)
      @pending_abiversion = opts.fetch(:abiversion, 0)
      @pending_sections = []
      @pending_segments = []
      @pending_symbols = []
      @skipped_segment_types = []

      @elf_class = elf_class
      @endian = endian
      copy_from(source) if source
    end

    # Add section. Names must be unique; sections lay out in insertion
    # order, ahead of the generated +.symtab+, +.strtab+ and (unless
    # supplied) +.shstrtab+, except that a pinned +offset+ lands wherever stated.
    # @param [String] name Section name.
    # @param [String, nil] data Section bytes.
    # @param [Array<Integer, Symbol, String>, Integer] flags
    #   ELFTools::Constants::SHF names OR'ed together, or a bitmask.
    # @option rest [Integer, Symbol, String] :type
    #   An {ELFTools::Constants::SHT} name or value (+:progbits+ by default,
    #   +:nobits+ for a +.bss+-style section).
    # @option rest [Integer] :size Zero bytes to add instead of +data+.
    # @option rest [Integer, nil] :addr
    #   Load address. When omitted, an alloc section of an executable or
    #   shared object takes its file offset; any other section takes 0.
    # @option rest [Integer] :align Alignment. Defaults to 1.
    # @option rest [Integer, nil] :offset
    #   File offset, pinning where the section lands. When omitted, the
    #   section follows the previous one, aligned up.
    # @option rest [Integer, String] :link +sh_link+: an index, or a section
    #   name.
    # @option rest [Integer] :info +sh_info+.
    # @option rest [Integer] :entsize +sh_entsize+.
    #
    # @return [Builder::Section] Added section. The returned handle stays live
    #   for +addr+, +link+ and +pinned_offset+; offsets, indices and name
    #   offsets are recomputed at build time.
    # @raise [ArgumentError] If the name is taken or invalid, both +data+ and
    #   +size+ are passed, +size:+ is not a non-negative +Integer+, an option
    #   is unknown, or a numeric option is not an +Integer+.
    def add_section(name, data: nil, flags: [], **opts)
      check_section_name!(name)
      raise ArgumentError, "section #{name.inspect} already added" if @pending_sections.any? { |s| s.name == name }

      type = resolve_value(ELFTools::Constants::SHT, opts.fetch(:type, :progbits))
      data, sh_size = section_payload(type, data, opts)
      check_unknown_opts!(opts, %i[type addr align offset link info entsize], 'add_section')
      section = Section.new(
        name: name,
        data: data,
        type: type,
        flags: flag_value(ELFTools::Constants::SHF, flags),
        addr: integer_opt!(opts[:addr], :addr),
        align: integer_opt!(opts.fetch(:align, 1), :align, allow_nil: false),
        pinned_offset: integer_opt!(opts[:offset], :offset),
        link: check_link_opt!(opts.fetch(:link, 0)),
        info: integer_opt!(opts.fetch(:info, 0), :info, allow_nil: false),
        entsize: integer_opt!(opts.fetch(:entsize, 0), :entsize, allow_nil: false),
        sh_size: sh_size
      )
      @pending_sections << section
      section
    end

    # Add symbol.
    #
    # +.symtab+ and +.strtab+ sections are created automatically.
    # @param [String] name Symbol name.
    # @param [Integer] value +st_value+.
    # @param [Integer] size +st_size+.
    # @param [Integer, Symbol, String] bind An ELFTools::Constants::STB name or value.
    # @option rest [Integer, Symbol, String] :type
    #   An {ELFTools::Constants::STT} name or value (+:notype+ by default).
    # @option rest [Integer, Symbol, String] :visibility
    #   An {ELFTools::Constants::STV} name or value (+:default+ by default).
    # @option rest [String, Integer, Symbol] :section
    #   An added section's name, or an {ELFTools::Constants::SHN} name or
    #   value (+:abs+ for absolute, +:undef+ by default).
    # @return [Builder::Symbol] Added symbol.
    # @raise [ArgumentError] If an option is unknown, the name is invalid, or
    #   +value+ or +size+ do not fit. At build time, raises if +section+ names
    #   a section that was not added, or if +.symtab+ or +.strtab+ sections
    #   are already present.
    #
    def add_symbol(name, value: 0, size: 0, bind: :global, **opts)
      check_symbol_name!(name)
      check_unknown_opts!(opts, %i[type visibility section], 'add_symbol')
      value = ELFTools::Util.fits!(integer_opt!(value, 'Symbol value', allow_nil: false), @elf_class, 'Symbol value')
      size = ELFTools::Util.fits!(integer_opt!(size, 'Symbol size', allow_nil: false), @elf_class, 'Symbol size')
      bind = ELFTools::Util.fits!(resolve_value(ELFTools::Constants::STB, bind), 4, 'Symbol binding')
      type = ELFTools::Util.fits!(resolve_value(ELFTools::Constants::STT, opts.fetch(:type, :notype)), 4, 'Symbol type')
      visibility = ELFTools::Util.fits!(resolve_value(ELFTools::Constants::STV, opts.fetch(:visibility, :default)), 2,
                                        'Symbol visibility')
      section = opts.fetch(:section, :undef)
      resolve_value(ELFTools::Constants::SHN, section) unless section.is_a?(String) || section.is_a?(Integer)

      sym = Symbol.new(
        name: name, value: value, sym_size: size,
        info: (bind << 4) | type, other: visibility,
        section: section
      )
      @pending_symbols << sym
      sym
    end

    # Add program header. With +covers+, offset, vaddr, filesz and
    # memsz derive from those sections.
    # @param [Integer, Symbol, String] type
    #   A ELFTools::Constants::PT name or value (+:load+ by default).
    # @param [Array<Integer, Symbol, String>, Integer] flags
    #   ELFTools::Constants::PF names OR'ed together, or a bitmask.
    # @param [Array<String>, String, :all, nil] covers
    #   Sections to derive the bounds from (+:all+ specifies every added
    #   section, excluding generated +.symtab+, +.strtab+ and +.shstrtab+).
    #   Without it, +offset+, +vaddr+ and +filesz+ are required. Explicitly
    #   passed bounds take precedence; only missing fields derive.
    # @option rest [Integer, nil] :offset File offset.
    # @option rest [Integer, nil] :vaddr Load address.
    # @option rest [Integer, nil] :paddr Physical address. Defaults to +vaddr+.
    # @option rest [Integer, nil] :filesz File size.
    # @option rest [Integer, nil] :memsz Memory size. Defaults to +filesz+.
    # @option rest [Integer] :align Defaults to 0 (no alignment).
    # @return [Builder::Segment] Added segment.
    # @raise [ArgumentError] If +type+ names nothing, +covers+ is neither
    #   nil, +:all+, a section name nor an array of names, an option is
    #   unknown, or a bound is not an +Integer+.
    #
    def add_segment(type: :load, flags: [], covers: nil, **opts)
      check_unknown_opts!(opts, %i[offset vaddr paddr filesz memsz align], 'add_segment')
      covers = Array(covers).map(&:to_s) if covers.is_a?(Array) || covers.is_a?(String)
      unless covers.nil? || covers == :all || covers.is_a?(Array)
        raise ArgumentError, "covers must be nil, :all, a section name or an array of names, got #{covers.inspect}"
      end

      seg = Segment.new(
        type: resolve_value(ELFTools::Constants::PT, type),
        flags: flag_value(ELFTools::Constants::PF, flags),
        covers: covers,
        offset: integer_opt!(opts[:offset], :offset),
        vaddr: integer_opt!(opts[:vaddr], :vaddr),
        paddr: integer_opt!(opts[:paddr], :paddr),
        filesz: integer_opt!(opts[:filesz], :filesz),
        memsz: integer_opt!(opts[:memsz], :memsz),
        align: integer_opt!(opts.fetch(:align, 0), :align, allow_nil: false)
      )
      @pending_segments << seg
      seg
    end

    # Opt out of automatic segments: +:phdr+ drops the header table and its
    # mapping load, +:interp+, +:dynamic+ and +:note+ drop those, +:load+ drops
    # loads from alloc sections.
    # @param [Array<Integer, Symbol, String>] types
    #   ELFTools::Constants::PT names or values to not create automatically.
    # @return [Array<Integer>] Every skipped type value so far.
    # @raise [ArgumentError] If a type names nothing.
    # @example Drop the header table from a fresh executable.
    #   elf = PatchELF::Builder.new(machine: :x86_64, type: :exec)
    #   elf.add_section('.text', data: "\x90".b, addr: 0x401000, flags: %i[alloc execinstr])
    #   elf.skip_segment(:phdr)
    #   elf.to_elf.segment_by_type(:phdr)
    #   #=> nil
    def skip_segment(*types)
      @skipped_segment_types |= types.map { |type| resolve_value(ELFTools::Constants::PT, type) }
      @skipped_segment_types.dup
    end

    # Drop section, pruning it from any segment's +covers+.
    #
    # @param [String] name Section name.
    # @return [Builder::Section] The removed section.
    # @raise [ArgumentError] If no such section, or one is still referenced.
    # @example Copy /bin/cat without its comment section.
    #   elf = PatchELF::Builder.new('/bin/cat')
    #   elf.remove_section('.comment')
    #   elf.to_elf.section_by_name('.comment')
    #   #=> nil
    def remove_section(name)
      section = @pending_sections.find { |s| s.name == name }
      raise ArgumentError, "no such section #{name.inspect}" if section.nil?

      removed = @pending_sections.index(section) + 1 # +1 for the leading NULL section.
      check_section_removal!(name, removed)
      shift_section_indices!(name, removed)
      @pending_sections.delete(section)
      @pending_segments.each do |seg|
        next unless seg.covers.is_a?(Array)
        next unless seg.covers.delete(name)

        seg.offset = seg.vaddr = seg.filesz = seg.memsz = nil
      end
      section
    end

    # Drop all segments with specified type.
    # @param [Integer, Symbol, String] type
    #   A ELFTools::Constants::PT name or value.
    # @return [Array<Builder::Segment>] The removed segments.
    # @raise [ArgumentError] If no such segment.
    # @example Drop a copied file's note segments.
    #   elf = PatchELF::Builder.new('/bin/cat')
    #   elf.remove_segment(:note)
    #   elf.to_elf.segments_by_type(:note)
    #   #=> []
    def remove_segment(type)
      value = resolve_value(ELFTools::Constants::PT, type)
      removed = @pending_segments.select { |seg| seg.type == value }
      raise ArgumentError, "no such #{type.inspect} segment" if removed.empty?

      @pending_segments -= removed
      @skipped_segment_types |= [value]
      removed
    end

    # Drop all symbols with the given name. Symbol names are not unique,
    # so every match is removed.
    # @param [String] name Symbol name.
    # @return [Array<Builder::Symbol>] The removed symbols.
    # @raise [ArgumentError] If no such symbol.
    # @example Drop a symbol, then its section.
    #   elf = PatchELF::Builder.new(machine: :x86_64)
    #   elf.add_section('.text', data: "\x90".b)
    #   elf.add_symbol('main', section: '.text')
    #   elf.remove_symbol('main')
    #   elf.remove_section('.text')
    def remove_symbol(name)
      removed = @pending_symbols.select { |sym| sym.name == name }
      raise ArgumentError, "no such symbol #{name.inspect}" if removed.empty?

      @pending_symbols -= removed
      removed
    end

    # Get built ELF data.
    # @return [String] The bytes of built ELF file.
    # @raise [ArgumentError] If layout is invalid.
    def to_s
      assemble
    end

    # Write built ELF to a path or anything answering to +#write+,
    # and return the builder itself.
    # @param [String, #write] output Where to write.
    # @return [Builder] Itself.
    # @example Write a copy of /bin/cat's .text out to a file.
    #   cat = ELFTools::ELFFile.new(File.open('/bin/cat', 'rb'))
    #   elf = PatchELF::Builder.new(machine: cat.header.e_machine.to_i)
    #   elf.add_section('.text', data: cat.section_by_name('.text').data)
    #   elf.write(File.open('text.elf', 'wb'))
    #   #=> PatchELF::Builder
    def write(output)
      bytes = to_s
      if output.respond_to?(:write)
        output.write(bytes)
      else
        File.binwrite(output, bytes)
      end
      self
    end

    # Convert built ELF to an ELFTools::ELFFile.
    # @return [ELFTools::ELFFile] View of the built ELF.
    # @example Inspect the built ELF.
    #   builder = PatchELF::Builder.new(machine: :x86_64)
    #   builder.add_section('.text', data: "\x90".b)
    #   builder.to_elf.section_by_name('.text').data
    #   #=> "\x90"
    def to_elf
      ELFTools::ELFFile.new(StringIO.new(assemble))
    end

    # Write built ELF to +filename+.
    # @param [String] filename Where to write.
    # @return [Integer] Bytes written.
    def save(filename)
      File.binwrite(filename, to_s)
    end

    private

    def section_payload(type, data, opts)
      raise ArgumentError, 'pass data: or size:, not both' if !data.nil? && opts.key?(:size)
      return nobits_payload(data, opts) if type == ELFTools::Constants::SHT_NOBITS
      return ["\x00".b * opts.delete(:size), nil] if opts.key?(:size)

      [data.to_s.b, nil]
    end

    def nobits_payload(data, opts)
      size = data.nil? ? opts.delete(:size) || 0 : data.to_s.bytesize
      raise ArgumentError, 'size must be a non-negative Integer' unless size.is_a?(Integer) && !size.negative?

      [''.b, size]
    end

    def normalize_source(source)
      return nil if source.nil?
      return ELFTools::ELFFile.new(StringIO.new(source.to_s)) if source.is_a?(Builder)
      return source if source.is_a?(ELFTools::ELFFile)

      source = StringIO.new(File.binread(source)) if source.is_a?(String)
      ELFTools::ELFFile.new(source)
    end

    def check_header(elf_class, endian)
      raise ArgumentError, "elf_class must be 32 or 64, got #{elf_class}" unless [32, 64].include?(elf_class)

      return if %i[little big].include?(endian)

      raise ArgumentError, "endian must be :little or :big, got #{endian.inspect}"
    end

    def check_unknown_opts!(opts, known, context)
      unknown = opts.keys - known
      return if unknown.empty?

      names = unknown.map(&:inspect).join(', ')
      plural = unknown.size > 1 ? 's' : ''
      raise ArgumentError, "unknown option#{plural} for #{context}: #{names}"
    end

    def check_section_name!(name)
      return if name.is_a?(String) && !name.empty? && !name.include?("\x00")

      raise ArgumentError, "section name must be a non-empty String without null bytes, got #{name.inspect}"
    end

    def check_symbol_name!(name)
      return if name.is_a?(String) && !name.include?("\x00")

      raise ArgumentError, "symbol name must be a String without null bytes, got #{name.inspect}"
    end

    def integer_opt!(value, field, allow_nil: true)
      return nil if value.nil? && allow_nil
      if value.is_a?(Numeric) && !value.is_a?(Integer)
        raise ArgumentError, "#{field} must be an Integer, got #{value.inspect}"
      end

      begin
        Integer(value)
      rescue ArgumentError, TypeError
        raise ArgumentError, "#{field} must be an Integer, got #{value.inspect}"
      end
    end

    def check_link_opt!(link)
      return link if link.is_a?(Integer) || link.is_a?(String)

      raise ArgumentError, "link must be a section index or name, got #{link.inspect}"
    end

    def source_defaults(source)
      return {} if source.nil?

      {
        machine: source.header.e_machine.to_i,
        elf_class: source.elf_class,
        endian: source.endian,
        type: source.header.e_type.to_i,
        entry: source.header.e_entry.to_i,
        flags: source.header.e_flags.to_i,
        osabi: source.header.e_ident.ei_osabi.to_i,
        abiversion: source.header.e_ident.ei_abiversion.to_i
      }
    end

    def copy_from(source)
      copy_sections_from(source)
      copy_segments_from(source)
    end

    def copy_sections_from(source)
      check_copyable_sections!(source)
      source.sections.each do |section|
        next if section.name.empty?

        header = section.header
        opts = { type: header.sh_type.to_i, flags: header.sh_flags.to_i,
                 addr: header.sh_addr.to_i, align: header.sh_addralign.to_i,
                 offset: header.sh_offset.to_i,
                 link: header.sh_link.to_i, info: header.sh_info.to_i,
                 entsize: header.sh_entsize.to_i }
        if header.sh_type.to_i == ELFTools::Constants::SHT_NOBITS
          add_section(section.name, **opts, size: header.sh_size.to_i)
        else
          add_section(section.name, data: section.data, **opts)
        end
      end
    end

    def copy_segments_from(source)
      source.segments.each do |segment|
        header = segment.header
        covered = source.sections.select { |s| covers_section?(s, header) }.map(&:name)
        covers = header.p_type.to_i == pt(:load) && !covered.empty? && !header.p_offset.to_i.zero? ? covered : nil
        add_segment(type: header.p_type.to_i, flags: header.p_flags.to_i, covers: covers,
                    offset: header.p_offset.to_i, vaddr: header.p_vaddr.to_i, paddr: header.p_paddr.to_i,
                    filesz: header.p_filesz.to_i, memsz: header.p_memsz.to_i, align: header.p_align.to_i)
      end
    end

    def check_copyable_sections!(source)
      seen = {}
      source.sections.each_with_index do |section, index|
        next if index.zero?
        raise ArgumentError, "cannot copy: section #{index} has no name" if section.name.empty?
        raise ArgumentError, "cannot copy: duplicate section name #{section.name.inspect}" if seen.key?(section.name)

        seen[section.name] = true
      end
    end

    def covers_section?(section, header)
      return false if section.name.empty? || section.name == '.shstrtab'

      sh = section.header
      if sh.sh_type.to_i == ELFTools::Constants::SHT_NOBITS
        sh.sh_addr.to_i >= header.p_vaddr.to_i &&
          sh.sh_addr.to_i + sh.sh_size.to_i <= header.p_vaddr.to_i + header.p_memsz.to_i
      else
        !header.p_filesz.to_i.zero? && sh.sh_offset.to_i >= header.p_offset.to_i &&
          sh.sh_offset.to_i + sh.sh_size.to_i <= header.p_offset.to_i + header.p_filesz.to_i
      end
    end

    def assemble
      all = ordered_sections
      segments = effective_segments
      table_end = headers_size(segments.size)
      data_end = place_sections(all, table_end)
      shoff = Helper.alignup(data_end, word_align)
      resolved = resolve_segments(all, segments, table_end)

      out = +''.b
      out << build_ehdr(all, shoff, segments).to_binary_s
      build_phdrs(resolved).each { |phdr| out << phdr.to_binary_s }

      all.select { |sec| !sec.index.zero? && sec.type != ELFTools::Constants::SHT_NOBITS }
         .sort_by { |sec| [sec.offset, sec.index] }
         .each do |sec|
        pad_to(out, sec.offset)
        out << sec.data
      end

      pad_to(out, shoff)
      all.each { |sec| out << build_shdr(sec) }
      out
    end

    def pad_to(out, offset)
      pad = offset - out.bytesize
      out << ("\x00".b * pad) if pad.positive?
    end

    def ordered_sections
      null = Section.new(name: '', data: +''.b, type: ELFTools::Constants::SHT_NULL,
                         flags: 0, addr: 0, align: 0)

      symtab, strtab = build_symbol_tables(section_limit)
      sections = [null] + @pending_sections.map(&:dup) + [symtab, strtab].compact
      ensure_shstrtab!(sections)

      sections.each_with_index { |sec, i| sec.index = i }
      symtab.link = sections.index(strtab) if symtab
      resolve_section_links(sections)
      sections
    end

    def section_limit
      limit = 1 + @pending_sections.size + 2
      limit += 1 unless @pending_sections.any? { |s| s.name == '.shstrtab' }
      limit
    end

    def ensure_shstrtab!(sections)
      provided = sections.find { |sec| sec.name == '.shstrtab' }
      if provided.nil?
        table = +"\x00".b
        sections.each { |sec| sec.name_offset = shstrtab_offset(table, sec.name) }
        section = Section.new(name: '.shstrtab', data: table, type: ELFTools::Constants::SHT_STRTAB,
                              flags: 0, addr: 0, align: 1)
        section.name_offset = shstrtab_offset(table, section.name)
        sections << section
        return
      end

      table = provided.data.dup
      sections.each { |sec| sec.name_offset = shstrtab_offset(table, sec.name) }
      section = shstrtab_shell(provided, table)
      section.name_offset = shstrtab_offset(table, section.name)
      sections[sections.index(provided)] = section
    end

    def shstrtab_shell(provided, table)
      return provided if table.bytesize == provided.data.bytesize

      shell = provided.dup
      shell.data = table
      shell.pinned_offset = nil
      shell
    end

    def shstrtab_offset(table, name)
      return 0 if name.empty?

      offset = table.index("\x00#{name}\x00")
      if offset.nil?
        table << "\x00".b unless table.end_with?("\x00")
        offset = table.bytesize - 1
        table << name.b << "\x00".b
      end
      offset + 1
    end

    def resolve_section_links(sections)
      by_name = sections.to_h { |sec| [sec.name, sec.index] }
      sections.each do |sec|
        resolve_section_link!(sec, by_name)
        resolve_reloc_info!(sec, sections.length)
      end
    end

    def resolve_section_link!(sec, by_name)
      if sec.link.is_a?(String)
        index = by_name[sec.link]
        raise ArgumentError, "section #{sec.name.inspect} links unknown section #{sec.link.inspect}" if index.nil?

        sec.link = index
      elsif sec.link.is_a?(Integer) && (sec.link.negative? || sec.link >= by_name.length)
        raise ArgumentError, "section #{sec.name.inspect} links unknown section index #{sec.link.inspect}"
      end
    end

    def resolve_reloc_info!(sec, count)
      return unless reloc_section?(sec) && sec.info.is_a?(Integer)
      return unless sec.info.negative? || sec.info >= count

      raise ArgumentError, "section #{sec.name.inspect} relocates unknown section index #{sec.info.inspect}"
    end

    def build_symbol_tables(limit)
      return [nil, nil] if @pending_symbols.empty?

      sections = @pending_sections.map(&:name) & %w[.symtab .strtab]
      unless sections.empty?
        raise ArgumentError,
              "cannot add symbols with #{sections.map(&:inspect).join(' and ')} already added"
      end

      strtab = StringTable.new

      locals, globals = @pending_symbols.partition { |s| (s.info >> 4) == ELFTools::Constants::STB_LOCAL }

      null_info = (ELFTools::Constants::STB_LOCAL << 4) | ELFTools::Constants::STT_NOTYPE
      null_sym = Symbol.new(name: '', value: 0, sym_size: 0, info: null_info, other: 0, section: :undef)
      ordered_syms = [null_sym] + locals + globals

      sym_klass = ELFTools::Structs::ELF_sym[@elf_class]
      sym_bytes = ordered_syms.map do |sym|
        s = sym_klass.new(endian: @endian)
        s.st_name = strtab.add(sym.name)
        s.st_value = sym.value
        s.st_size = sym.sym_size
        s.st_info = sym.info
        s.st_other = sym.other
        s.st_shndx = resolve_shndx(sym.section, limit)
        s.to_binary_s
      end.join

      strtab_section = Section.new(
        name: '.strtab', data: strtab.bytes,
        type: ELFTools::Constants::SHT_STRTAB, flags: 0, addr: 0, align: 1
      )
      symtab_section = Section.new(
        name: '.symtab', data: sym_bytes,
        type: ELFTools::Constants::SHT_SYMTAB, flags: 0, addr: 0,
        align: word_align,
        info: 1 + locals.length,
        entsize: sym_klass.num_bytes(elf_class: @elf_class, endian: @endian)
      )
      [symtab_section, strtab_section]
    end

    def resolve_shndx(section, limit)
      return resolve_index_shndx(section, limit) unless section.is_a?(String)

      index = @pending_sections.find_index { |s| s.name == section }
      raise ArgumentError, "symbol references unadded section #{section.inspect}" if index.nil?

      index + 1 # +1 for the leading NULL section.
    end

    def resolve_index_shndx(section, limit)
      index = resolve_value(ELFTools::Constants::SHN, section)
      if index.is_a?(Integer) && index < ELFTools::Constants::SHN_LORESERVE &&
         (index.negative? || index >= limit)
        raise ArgumentError, "symbol references unknown section index #{section.inspect}"
      end

      index
    end

    def check_section_removal!(name, removed)
      check_section_links!(name, removed)
      check_pending_symbols!(name, removed)
      @pending_sections.each do |sec|
        next if sec.name == name

        remap_indexed_data!(sec, name, removed, check_only: true)
      end
    end

    def check_pending_symbols!(name, removed)
      sym = @pending_symbols.find { |s| [name, removed].include?(s.section) }
      return if sym.nil?

      raise ArgumentError,
            "cannot remove #{name.inspect}: symbol #{sym.name.inspect} is defined in it; " \
            "remove symbol #{sym.name.inspect} first"
    end

    def check_section_links!(name, removed)
      @pending_sections.each do |sec|
        next if sec.name == name

        if [name, removed].include?(sec.link)
          raise ArgumentError,
                "cannot remove #{name.inspect}: #{sec.name.inspect} links to it; remove #{sec.name.inspect} first"
        end
        next unless reloc_section?(sec) && sec.info == removed

        raise ArgumentError,
              "cannot remove #{name.inspect}: relocations in #{sec.name.inspect} apply to it; " \
              "remove #{sec.name.inspect} first"
      end
    end

    def reloc_section?(sec)
      [ELFTools::Constants::SHT_REL, ELFTools::Constants::SHT_RELA].include?(sec.type)
    end

    def remap_indexed_data!(sec, name, removed, check_only:)
      case sec.type
      when ELFTools::Constants::SHT_SYMTAB, ELFTools::Constants::SHT_DYNSYM
        remap_symbols!(sec, name, removed, check_only: check_only)
      when ELFTools::Constants::SHT_GROUP
        remap_members!(sec, name, removed, skip_first: true, check_only: check_only)
      when ELFTools::Constants::SHT_SYMTAB_SHNDX
        remap_members!(sec, name, removed, skip_first: false, check_only: check_only)
      end
    end

    def remap_symbols!(sec, name, removed, check_only:)
      entries, rest = symbol_entries(sec)
      entries.each_with_index do |entry, i|
        slid = slid_index(entry.st_shndx.to_i, removed)
        if slid.nil?
          raise ArgumentError,
                "cannot remove #{name.inspect}: symbol #{i} in #{sec.name.inspect} is defined in it; " \
                "remove #{sec.name.inspect} first"
        end
        entry.st_shndx = slid unless check_only
      end
      return if check_only

      sec.data = entries.map(&:to_binary_s).join + rest
    end

    def slid_index(index, removed)
      return index if index.zero? || index >= ELFTools::Constants::SHN_LORESERVE
      return nil if index == removed

      index > removed ? index - 1 : index
    end

    def remap_members!(sec, name, removed, skip_first:, check_only:)
      words, rest = index_words(sec.data)
      head = skip_first ? words.first(1) : []
      tail = words.drop(skip_first ? 1 : 0).map do |index|
        slid = slid_index(index, removed)
        next slid unless slid.nil?

        reason = skip_first ? "group #{sec.name.inspect} contains it" : "symbol in #{sec.name.inspect} is defined in it"
        raise ArgumentError, "cannot remove #{name.inspect}: #{reason}; remove #{sec.name.inspect} first"
      end
      return if check_only

      sec.data = (head + tail).pack("#{word_format}*") + rest
    end

    def shift_section_indices!(name, removed)
      @pending_sections.each do |sec|
        next if sec.name == name

        sec.link -= 1 if sec.link.is_a?(Integer) && sec.link > removed
        sec.info -= 1 if reloc_section?(sec) && sec.info.is_a?(Integer) && sec.info > removed
        remap_indexed_data!(sec, name, removed, check_only: false)
      end
      shift_symbol_indices!(removed)
    end

    def shift_symbol_indices!(removed)
      @pending_symbols.each do |sym|
        next unless sym.section.is_a?(Integer) && sym.section < ELFTools::Constants::SHN_LORESERVE
        next unless sym.section > removed

        sym.section -= 1
      end
    end

    def symbol_entries(sec)
      klass = ELFTools::Structs::ELF_sym[@elf_class]
      size = klass.num_bytes(elf_class: @elf_class, endian: @endian)
      count = sec.data.bytesize / size
      entries = Array.new(count) do |i|
        klass.new(endian: @endian).read(StringIO.new(sec.data.byteslice(i * size, size)))
      end
      [entries, sec.data.byteslice((count * size)..) || +''.b]
    end

    def index_words(data)
      words = data.unpack("#{word_format}*")
      [words, data.byteslice((words.length * 4)..) || +''.b]
    end

    def word_format
      @endian == :big ? 'L>' : 'L<'
    end

    def section_size(sec)
      sec.type == ELFTools::Constants::SHT_NOBITS && !sec.sh_size.nil? ? sec.sh_size : sec.data.bytesize
    end

    def place_sections(sections, start)
      offset = start
      vaddr = start
      ranges = [[0, start]]
      sections.each do |sec|
        next if sec.index.zero?

        offset, vaddr = place_section(sec, offset, vaddr, ranges)
      end
      offset
    end

    def place_section(sec, offset, vaddr, ranges)
      sec.addr = auto_addr(sec, vaddr) if sec.addr.nil?
      sec.offset = sec.pinned_offset.nil? ? auto_offset(sec, offset) : checked_pinned_offset(sec, ranges)
      if sec.type == ELFTools::Constants::SHT_NOBITS
        vaddr = [vaddr, sec.addr + section_size(sec)].max if loaded?(sec)
      else
        ranges << [sec.offset, sec.offset + sec.data.bytesize]
        offset = [offset, sec.offset + sec.data.bytesize].max
        vaddr = [vaddr, sec.addr + sec.data.bytesize].max if loaded?(sec)
      end
      [offset, vaddr]
    end

    def auto_offset(sec, offset)
      offset = Helper.alignup(offset, sec.align) if sec.align > 1
      align_to_segment(sec, offset)
    end

    def align_to_segment(sec, offset)
      return offset unless sec.addr && loaded?(sec)

      offset + ((sec.addr - offset) % page_align)
    end

    def loadable_type?
      [ELFTools::Constants::ET_EXEC, ELFTools::Constants::ET_DYN].include?(@pending_type)
    end

    def auto_addr(sec, vaddr)
      return 0 unless loaded?(sec)

      vaddr = Helper.alignup(vaddr, sec.align) if sec.align > 1
      vaddr
    end

    def loaded?(sec)
      sec.flags.anybits?(ELFTools::Constants::SHF_ALLOC) && loadable_type?
    end

    def checked_pinned_offset(sec, ranges)
      unless sec.type == ELFTools::Constants::SHT_NOBITS
        if sec.align > 1 && (sec.pinned_offset % sec.align) != 0
          raise ArgumentError,
                "offset #{sec.pinned_offset} for section #{sec.name.inspect} is not a multiple of its alignment"
        end
        if ranges.any? { |from, to| sec.pinned_offset < to && from < sec.pinned_offset + sec.data.bytesize }
          raise ArgumentError,
                "offset #{sec.pinned_offset} for section #{sec.name.inspect} overlaps an earlier section or a header"
        end
      end
      sec.pinned_offset
    end

    def default_entry(sections)
      loaded = sections.select { |s| !s.index.zero? && s.flags.anybits?(ELFTools::Constants::SHF_ALLOC) }
      loaded.map(&:addr).min || 0
    end

    def build_ehdr(sections, shoff, segments)
      ehdr = ELFTools::Structs::ELF_Ehdr.new(endian: @endian)
      ehdr.elf_class = @elf_class
      ehdr.e_ident.magic = ELFTools::Constants::ELFMAG
      ehdr.e_ident.ei_class = (@elf_class == 64 ? 2 : 1)
      ehdr.e_ident.ei_data = (@endian == :little ? 1 : 2)
      ehdr.e_ident.ei_version = 1 # EV_CURRENT.
      ehdr.e_ident.ei_osabi = @pending_osabi
      ehdr.e_ident.ei_abiversion = @pending_abiversion
      ehdr.e_ident.ei_padding = "\x00".b * 7

      ehdr.e_type = @pending_type
      ehdr.e_machine = @pending_machine
      ehdr.e_version = 1
      ehdr.e_entry = @pending_entry.nil? ? default_entry(sections) : @pending_entry
      ehdr.e_phoff = segments.empty? ? 0 : ELFTools::Structs::ELF_Ehdr.num_bytes(elf_class: @elf_class, endian: @endian)
      ehdr.e_shoff = shoff
      ehdr.e_flags = @pending_flags
      ehdr.e_ehsize = ehdr.num_bytes
      ehdr.e_phentsize = ELFTools::Structs::ELF_Phdr[@elf_class].num_bytes(elf_class: @elf_class, endian: @endian)
      ehdr.e_phnum = segments.length
      ehdr.e_shentsize = ELFTools::Structs::ELF_Shdr.num_bytes(elf_class: @elf_class, endian: @endian)
      ehdr.e_shnum = sections.length
      ehdr.e_shstrndx = sections.index { |sec| sec.name == '.shstrtab' }
      ehdr
    end

    def build_shdr(sec)
      shdr = ELFTools::Structs::ELF_Shdr.new(endian: @endian)
      shdr.elf_class = @elf_class
      shdr.sh_name = sec.name_offset || 0
      shdr.sh_type = sec.type
      shdr.sh_flags = sec.flags
      shdr.sh_addr = sec.addr
      shdr.sh_offset = sec.index.zero? ? 0 : (sec.offset || 0)
      shdr.sh_size = sec.index.zero? ? 0 : section_size(sec)
      shdr.sh_link = sec.link || 0
      shdr.sh_info = sec.info || 0
      shdr.sh_addralign = sec.align
      shdr.sh_entsize = sec.entsize || 0
      shdr.to_binary_s
    end

    def build_phdrs(segments)
      segments.map do |seg|
        phdr = ELFTools::Structs::ELF_Phdr[@elf_class].new(endian: @endian)
        phdr.elf_class = @elf_class
        phdr.p_type = seg.type
        phdr.p_flags = seg.flags || 0
        phdr.p_offset = seg.offset
        phdr.p_vaddr = seg.vaddr
        phdr.p_paddr = seg.paddr || seg.vaddr
        phdr.p_filesz = seg.filesz
        phdr.p_memsz = seg.memsz || seg.filesz
        phdr.p_align = seg.align || 0
        phdr
      end
    end

    def effective_segments
      return @pending_segments unless loadable_type?

      derived_segments(@pending_sections) + @pending_segments
    end

    def derived_segments(sections)
      suppressed = @pending_segments.map(&:type) | @skipped_segment_types
      segs = derived_interp(sections, suppressed)
      segs.concat(derived_loads(sections, suppressed))
      segs.concat(derived_dynamic(sections, suppressed))
      segs.concat(derived_notes(sections, suppressed))
      unless suppressed.include?(pt(:phdr))
        segs.unshift(derived_header_load)
        segs.unshift(derived_phdr(segs.size + @pending_segments.size + 1))
      end
      segs
    end

    def derived_header_load
      Segment.new(type: pt(:load), flags: ELFTools::Constants::PF_R, covers: :headers, align: page_align)
    end

    def derived_phdr(count)
      ehsize = ELFTools::Structs::ELF_Ehdr.num_bytes(elf_class: @elf_class, endian: @endian)
      filesz = count * ELFTools::Structs::ELF_Phdr[@elf_class].num_bytes(elf_class: @elf_class, endian: @endian)
      Segment.new(type: pt(:phdr), flags: ELFTools::Constants::PF_R, covers: :headers, offset: ehsize,
                  filesz: filesz, align: word_align)
    end

    def derived_interp(sections, suppressed)
      return [] if suppressed.include?(pt(:interp))

      interp = sections.find { |s| s.name == '.interp' }
      return [] if interp.nil?

      [Segment.new(type: pt(:interp), flags: ELFTools::Constants::PF_R, covers: [interp.name], align: 1)]
    end

    def derived_dynamic(sections, suppressed)
      return [] if suppressed.include?(pt(:dynamic))

      dynamic = sections.find { |s| s.type == ELFTools::Constants::SHT_DYNAMIC }
      return [] if dynamic.nil?

      [Segment.new(type: pt(:dynamic), flags: ELFTools::Constants::PF_R | ELFTools::Constants::PF_W,
                   covers: [dynamic.name], align: word_align)]
    end

    def derived_notes(sections, suppressed)
      return [] if suppressed.include?(pt(:note))

      sections.select { |s| s.type == ELFTools::Constants::SHT_NOTE }.map do |note|
        Segment.new(type: pt(:note), flags: ELFTools::Constants::PF_R, covers: [note.name], align: 4)
      end
    end

    def pt(name)
      resolve_value(ELFTools::Constants::PT, name)
    end

    def derived_loads(sections, suppressed)
      return [] if suppressed.include?(pt(:load))

      alloc = sections.select { |s| s.flags.anybits?(ELFTools::Constants::SHF_ALLOC) }
      alloc.chunk(&:flags).map do |flags, group|
        pf = ELFTools::Constants::PF_R
        pf |= ELFTools::Constants::PF_W if flags.anybits?(ELFTools::Constants::SHF_WRITE)
        pf |= ELFTools::Constants::PF_X if flags.anybits?(ELFTools::Constants::SHF_EXECINSTR)
        Segment.new(type: pt(:load), flags: pf, covers: group.map(&:name), align: page_align)
      end
    end

    def resolve_segments(sections, segments, table_end)
      phdr_size = ELFTools::Structs::ELF_Phdr[@elf_class].num_bytes(elf_class: @elf_class, endian: @endian)
      ehsize = ELFTools::Structs::ELF_Ehdr.num_bytes(elf_class: @elf_class, endian: @endian)
      table_size = segments.size * phdr_size
      segments.map do |seg|
        dup = seg.dup
        refresh_header_phdr!(dup, table_size, ehsize)
        resolve_segment(dup, sections, table_end)
      end
    end

    def refresh_header_phdr!(seg, table_size, ehsize)
      return unless seg.type == pt(:phdr) && seg.covers.nil? && seg.offset == ehsize
      return if seg.filesz.nil? || seg.filesz == table_size

      seg.memsz = table_size if seg.memsz.nil? || seg.memsz == seg.filesz
      seg.filesz = table_size
    end

    def resolve_segment(seg, sections, table_end)
      if seg.covers.nil?
        check_explicit_segment(seg)
      elsif seg.covers == :headers
        apply_header_bounds(seg, sections, table_end)
      else
        covered = resolve_covered_sections(seg.covers, sections)
        raise ArgumentError, 'segment covers no sections' if covered.empty?

        apply_covered_bounds(seg, covered)
      end
      seg
    end

    def apply_header_bounds(seg, sections, table_end)
      stop = sections.find { |s| !s.index.zero? && s.flags.nobits?(ELFTools::Constants::SHF_ALLOC) }
      base = header_base_vaddr(sections, stop)
      if seg.type == pt(:phdr)
        seg.vaddr = base + seg.offset
      else
        seg.offset = 0
        seg.vaddr = base
        seg.filesz = table_end
        check_load_alignment!(seg)
      end
      seg
    end

    def header_base_vaddr(sections, stop)
      first = sections.find do |s|
        !s.index.zero? && s.flags.anybits?(ELFTools::Constants::SHF_ALLOC) && (stop.nil? || s.offset < stop.offset)
      end
      first.nil? ? 0 : [first.addr - first.offset, 0].max
    end

    def apply_covered_bounds(seg, covered)
      offset, filesz = segment_file_bounds(covered)
      seg.offset = offset if seg.offset.nil?
      seg.filesz = filesz if seg.filesz.nil?
      seg.vaddr = covered.map(&:addr).min if seg.vaddr.nil?
      seg.memsz = covered.map { |s| s.addr + section_size(s) }.max - seg.vaddr if seg.memsz.nil?
      seg.memsz = seg.filesz if seg.memsz < seg.filesz
      check_load_alignment!(seg)
      seg
    end

    def check_load_alignment!(seg)
      return unless seg.type == pt(:load) && (seg.align || 0) > 1
      return if ((seg.offset - seg.vaddr) % seg.align).zero?

      raise ArgumentError,
            "load segment offset #{seg.offset} mismatches vaddr #{seg.vaddr} for alignment #{seg.align}"
    end

    def check_explicit_segment(seg)
      missing = %i[offset vaddr filesz].select { |field| seg[field].nil? }
      raise ArgumentError, "segment without covers: needs #{missing.join(', ')}" unless missing.empty?
    end

    def segment_file_bounds(covered)
      non_nobits = covered.reject { |s| s.type == ELFTools::Constants::SHT_NOBITS }
      return [covered.first.offset, 0] if non_nobits.empty?

      offset = covered.map(&:offset).min
      filesz = non_nobits.map { |s| s.offset + s.data.bytesize }.max - offset
      [offset, filesz]
    end

    def resolve_covered_sections(names, sections)
      names = @pending_sections.map(&:name) if names == :all
      names.map do |name|
        sec = sections.find { |s| s.name == name }
        raise ArgumentError, "segment covers unknown section #{name.inspect}" if sec.nil?

        sec
      end
    end

    def headers_size(count)
      ELFTools::Structs::ELF_Ehdr.num_bytes(elf_class: @elf_class, endian: @endian) +
        (count * ELFTools::Structs::ELF_Phdr[@elf_class].num_bytes(elf_class: @elf_class, endian: @endian))
    end

    def word_align
      @elf_class == 64 ? 8 : 4
    end

    def page_align
      Helper.page_size(@pending_machine)
    end

    def resolve_value(mod, val)
      return val if val.is_a?(Integer)

      ELFTools::Util.to_constant(mod, val)
    end

    def flag_value(mod, flags)
      Array(flags).reduce(0) { |mask, flag| mask | resolve_value(mod, flag) }
    end
  end
end
