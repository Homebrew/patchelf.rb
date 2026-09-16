# frozen_string_literal: true

module PatchELF
  # A string table being built, mapping each string to its byte offset.
  #
  # The leading null byte is reserved by the constructor and offsets the
  # table so that every string starts at a non-zero offset (the null byte
  # at offset 0 serves as the empty-string entry).
  class StringTable
    # The bytes of the table so far.
    # @return [String]
    attr_reader :bytes

    def initialize
      @bytes = +"\x00".b
      @offsets = { '' => 0 }
    end

    # The offset of +str+ in the table, adding it if it is not already present.
    # @param [String] str
    # @return [Integer]
    def add(str)
      @offsets[str] ||= @bytes.bytesize.tap { @bytes << str.b << "\x00".b }
    end
  end
end
