# frozen_string_literal: true

lib = File.expand_path('lib', __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)

require 'patchelf/version'

Gem::Specification.new do |s|
  s.name          = 'patchelf'
  s.version       = PatchELF::VERSION
  s.summary       = 'Inspect, modify and create ELF binaries in pure Ruby'
  s.description   = 'A Ruby library and command-line tool for inspecting, modifying ' \
                    'and creating ELF executables and libraries.'
  s.license       = 'MIT'
  s.authors       = ['david942j']
  s.email         = ['david942j@gmail.com']
  s.files         = Dir['lib/**/*.rb'] + Dir['bin/*'] +
                    %w[.yardopts CONTRIBUTING.md LICENSE README.md THIRD_PARTY_NOTICES.md]
  s.homepage      = 'https://github.com/Homebrew/patchelf.rb'
  s.executables   = ['patchelf.rb']

  s.required_ruby_version = '>= 3.3'

  s.add_dependency 'elftools', '>= 2.2'
  s.add_dependency 'logger', '~> 1'

  s.add_development_dependency 'rake', '~> 13.0'
  s.add_development_dependency 'rspec', '~> 3'
  s.add_development_dependency 'rubocop', '~> 1'
  s.add_development_dependency 'simplecov', '>= 1.1', '< 2'
  s.add_development_dependency 'simplecov-cobertura', '~> 4'
  s.add_development_dependency 'tty-platform', '~> 0.1'
  s.add_development_dependency 'yard', '~> 0.9'
  s.metadata['rubygems_mfa_required'] = 'true'
  s.metadata['source_code_uri'] = 'https://github.com/Homebrew/patchelf.rb'
  s.metadata['bug_tracker_uri'] = 'https://github.com/Homebrew/patchelf.rb/issues'
  s.metadata['documentation_uri'] = 'https://www.rubydoc.info/gems/patchelf'
  s.metadata['changelog_uri'] = 'https://github.com/Homebrew/patchelf.rb/releases'
  s.metadata['funding_uri'] = 'https://github.com/sponsors/Homebrew'
end
