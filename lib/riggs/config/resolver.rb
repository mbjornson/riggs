# frozen_string_literal: true

require "open3"
require "psych"
require_relative "../trust"

module Riggs
  module Config
    # Finds the two configuration tiers and decides whether the project one may
    # be read at all. It does not merge them -- Config::Merge does that -- so
    # that "which files exist and may we look at them" stays separable from
    # "what do they mean together".
    class Resolver
      PROJECT_CONFIG = File.join(".riggs", "config.yml")

      # Read as the project tier with a deprecation notice. 46 references
      # across nine non-doc files; removing it is not this phase.
      LEGACY_PROJECT_CONFIGS = [".agent_hubrc", File.join("config", ".agent_hubrc"),
                                File.join("config", "agent_hubrc")].freeze

      Result = Struct.new(:global, :project, :project_path, :project_config_path,
                          :trusted, :legacy, keyword_init: true)

      # Both resolved at call time, honouring RIGGS_HOME, so tests and CLI
      # runs can target a temporary global tier instead of the developer's
      # own. A load-time constant off Dir.home cannot be overridden and
      # makes every CLI-level test write to the real ~/.riggs.
      def self.riggs_home
        Trust.home
      end

      def self.global_config
        File.join(riggs_home, "config.yml")
      end

      # This public wrapper retains the specified Resolver interface while the
      # path search itself lives in ProjectPaths to keep the resolver focused.
      # Git toplevel, so that trust, cost and memory are repository-scoped:
      # ~/Projects/riggs and ~/Projects/agentcrm are different projects, and
      # ~/Projects/agentcrm/lib is part of agentcrm. Keying on the working
      # directory would make a run from <repo>/lib a different project than
      # one from <repo> -- separate trust prompt, separate memory, separate
      # cost bucket.
      #
      # Outside a repository the same rule has to hold, so a directory with
      # no git toplevel walks up looking for a .riggs/config.yml and adopts
      # that ancestor. The walk stops BEFORE $HOME: ~/.riggs/config.yml is
      # the global tier, and treating it as a project marker would make
      # every directory under $HOME resolve to $HOME -- one project for the
      # whole machine, which is the $HOME collision wearing a different hat.
      def self.project_path(cwd = Dir.pwd)
        ProjectPaths.path_for(cwd)
      end

      def self.reset_cache!
        ProjectPaths.reset_cache!
      end

      def initialize(cwd: Dir.pwd, trust: nil, global_config: nil, home: Dir.home)
        @cwd = cwd
        @trust = trust || Trust.default
        @global_config = global_config || self.class.global_config
        @home = home
      end

      def resolve
        project_path = self.class.project_path(@cwd)
        global = ConfigFile.load(@global_config)
        return home_result(global, project_path) if home?(project_path)

        ResultFactory.new(global: global, project_path: project_path, trust: @trust).result
      end

      # Project skill and workflow roots, empty unless the path is trusted. A
      # skill declares mcp_servers, which pins which servers a step may reach;
      # a workflow declares providers and relay_chain, which decides what gets
      # dispatched and what pays. Gating the config file while loading
      # executable declarations from the same untrusted directory would leave
      # the door open beside the lock.
      def project_roots
        project_path = self.class.project_path(@cwd)
        return empty_roots unless @trust.trusted?(project_path)

        trusted_roots(project_path)
      end

      # This seam preserves the private test hook while ProjectPaths owns the
      # reusable filesystem walk.
      def self.marked_ancestor(cwd, home: Dir.home)
        ProjectPaths.marked_ancestor(cwd, home)
      end

      private_class_method :marked_ancestor

      private

      # R11.1: <project>/.riggs/config.yml IS ~/.riggs/config.yml when the
      # project is $HOME. There is no project tier there.
      def home?(project_path)
        File.expand_path(project_path) == File.expand_path(@home)
      end

      def home_result(global, project_path)
        Result.new(global: global, project: {}, project_path: project_path,
                   project_config_path: nil, trusted: @trust.trusted?(project_path), legacy: false)
      end

      def empty_roots
        { skills: nil, workflows: nil }
      end

      def trusted_roots(project_path)
        { skills: File.join(project_path, "config", "riggs", "skills"),
          workflows: File.join(project_path, "config", "riggs", "workflows") }
      end
    end

    # The path calculation is composed separately so Resolver remains the
    # boundary for deciding whether a discovered project configuration is safe.
    class ProjectPaths
      def self.path_for(cwd)
        key = File.expand_path(cwd)
        cache.fetch(key) { cache[key] = discovered_path(key) }
      end

      def self.reset_cache!
        @cache = {}
      end

      def self.marked_ancestor(cwd, home)
        stop = File.expand_path(home)
        Pathname.new(cwd).ascend.take_while { |path| before_stop?(path, stop) }.detect { |path| marked?(path) }&.to_s
      end

      def self.before_stop?(path, stop)
        path.to_s != stop && path.parent != path
      end

      def self.marked?(path)
        File.exist?(File.join(path, Resolver::PROJECT_CONFIG))
      end

      def self.cache
        @cache ||= {}
      end

      def self.discovered_path(cwd)
        git_toplevel(cwd) || marked_ancestor(cwd, Dir.home) || cwd
      end

      def self.git_toplevel(cwd)
        output, _error, status = Open3.capture3("git", "-C", cwd, "rev-parse", "--show-toplevel")
        return nil unless status.success?

        expanded_output(output)
      rescue StandardError
        nil
      end

      def self.expanded_output(output)
        path = output.strip
        return nil if path.empty?

        File.expand_path(path)
      end
    end

    # This object isolates file selection from result construction, so every
    # chosen path passes through one place before any project file is read.
    class ProjectConfig
      def initialize(project_path)
        @modern_path = File.join(project_path, Resolver::PROJECT_CONFIG)
        @legacy_path = self.class.legacy_path_for(project_path)
      end

      def path
        return @modern_path if File.exist?(@modern_path)

        @legacy_path
      end

      def legacy?
        !File.exist?(@modern_path) && !@legacy_path.nil?
      end

      def self.legacy_path_for(project_path)
        Resolver::LEGACY_PROJECT_CONFIGS.map { |config| File.join(project_path, config) }.detect(&File.method(:exist?))
      end
    end

    # A single-file reader keeps YAML parsing separate from the choice of which
    # tier, if any, is authorized to supply that file.
    class ConfigFile
      def self.load(path)
        return {} unless path && File.exist?(path)

        raw = Psych.safe_load(File.read(path), permitted_classes: [Symbol], aliases: true) || {}
        Identity.deep_symbolize(raw)
      end
    end

    # Result construction is a seam between trusted path selection and the
    # Resolver result so the trust gate cannot be bypassed by a caller.
    class ResultFactory
      def initialize(global:, project_path:, trust:)
        @global = global
        @project_path = project_path
        @trust = trust
      end

      def result
        project_config = ProjectConfig.new(@project_path)
        trusted = @trust.trusted?(@project_path)
        Resolver::Result.new(global: @global, project: project_for(project_config, trusted),
                             project_path: @project_path, project_config_path: config_path(project_config, trusted),
                             trusted: trusted, legacy: legacy?(project_config, trusted))
      end

      private

      def project_for(project_config, trusted)
        return {} unless trusted
        return {} if project_config.path.nil?

        ConfigFile.load(project_config.path)
      end

      # nil unless trusted, deliberately. This value is what
      # Identity.config_path returns and what the web app hands to
      # ConfigStore (lib/riggs/web/app.rb:96-98), and ConfigStore reads it
      # with Identity.load_config(path) -- a raw single-file reader that
      # never consults trust. Exposing the path of a file the resolver just
      # declined to open would let /config read and write it over HTTP.
      def config_path(project_config, trusted)
        return nil unless trusted

        project_config.path
      end

      def legacy?(project_config, trusted)
        return false unless trusted

        project_config.legacy?
      end
    end
  end
end
