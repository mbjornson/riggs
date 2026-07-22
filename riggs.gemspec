# frozen_string_literal: true

require_relative "lib/riggs/version"

Gem::Specification.new do |spec|
  spec.name = "riggs"
  spec.version = Riggs::VERSION
  spec.authors = ["mbjornson"]
  spec.email = ["mbjornson@icloud.com"]

  spec.summary = "Declarative YAML playbooks for multi-step AI automations with HITL, memory, and MCP."
  spec.description = <<~DESC
    Riggs is a CLI-first Ruby gem (and optional Rails engine) for defining and executing
    multi-step AI playbooks as DAGs. It provides RBAC, SQLite persistence, sqlite-memory
    semantic recall with FTS fallback, provider relay chains, skills, and MCP tools.
  DESC
  spec.homepage = "https://github.com/mbjornson/riggs"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"

  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ Gemfile .gitignore test/ .github/ .rubocop.yml])
    end
  end
  # Include untracked lib/config/db files during early development when git ls-files is empty
  if spec.files.empty?
    spec.files = Dir.chdir(__dir__) do
      Dir["{lib,exe,db,config,app}/**/*", "LICENSE.txt", "README.md", "CHANGELOG.md", "Rakefile"].select { |f| File.file?(f) }
    end
  end

  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "thor", "~> 1.3"
  spec.add_dependency "sqlite3", ">= 1.6"
  spec.add_dependency "psych", ">= 4.0"
  spec.add_dependency "concurrent-ruby", "~> 1.2"

  # Optional: host apps that mount the engine should add rails themselves
  spec.add_development_dependency "minitest", "~> 5.16"
  spec.add_development_dependency "rake", "~> 13.0"
end
